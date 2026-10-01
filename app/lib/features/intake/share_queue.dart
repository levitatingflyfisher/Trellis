/// Shares between the platform and a reader's shell (1.5.5). The
/// platform hands a share over the moment it arrives; it is written to the
/// database at once, bound to the reader who was open then (or to whoever
/// opens next, when the picker or PIN was showing), and stays there until
/// that reader's shell has saved it. A profile switch or a killed process
/// mid-queue loses nothing, and a parent's share never lands in a child's
/// Latest because the child's profile happened to open next.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../db/database.dart';
import 'share_intake.dart';
import 'share_source.dart';

/// One share waiting for its reader.
class PendingShare {
  final int id;

  /// The reader it belongs to; null for whichever reader opens next.
  final int? profileId;
  final SharedPayload payload;

  /// How many times a shell began saving it. Written before each try, so
  /// a share that kills the app is known on the next start.
  final int attempts;
  const PendingShare(
      {required this.id,
      required this.profileId,
      required this.payload,
      this.attempts = 0});

  PendingShare tried() => PendingShare(
      id: id, profileId: profileId, payload: payload, attempts: attempts + 1);

  Map<String, Object?> toJson() => {
        'id': id,
        'profileId': profileId,
        'attempts': attempts,
        'payload': payload.toJson(),
      };

  static PendingShare? fromJson(Object? m) {
    try {
      if (m is! Map || m['id'] is! int || m['payload'] is! Map) return null;
      return PendingShare(
          id: m['id'] as int,
          profileId: m['profileId'] as int?,
          attempts: (m['attempts'] as int?) ?? 0,
          payload: SharedPayload.fromJson(m['payload'] as Map));
    } catch (_) {
      return null;
    }
  }
}

/// A share that failed this many times is dropped, not retried at every
/// launch: one that crashes the app would otherwise crash it for ever.
const maxShareAttempts = 2;

void _deleteFile(String path) {
  try {
    File(path).deleteSync();
  } on FileSystemException {
    // Already gone.
  }
}

class ShareQueue extends ChangeNotifier {
  ShareQueue(
      {required this.db,
      required this.source,
      required this.activeProfileId,
      this.writesReady,
      void Function(String path)? discard})
      : _discard = discard ?? _deleteFile;

  final AppDatabase db;
  final ShareSource source;

  /// The reader open right now, or null behind the picker or the PIN.
  final int? Function() activeProfileId;

  /// A background check's connection closing; the queue writes after it.
  final Future<void>? writesReady;

  final void Function(String path) _discard;

  static const _key = 'share_pending';

  /// Where a stored list that can't be read at all is set aside, rather
  /// than thrown away or left to block every share after it.
  static const _unreadableKey = 'share_pending_unreadable';

  /// Shares taken from the platform whose write failed: held here and
  /// written with the next pull, so a failed write never loses them.
  final List<SharedPayload> _unwritten = [];

  /// Every read-modify-write of the list runs here, one at a time.
  Future<void> _chain = Future.value();
  bool _disposed = false;

  /// Completes once every pull and write asked for so far has run.
  Future<void> get idle => _chain;

  Future<T> _serial<T>(Future<T> Function() step) {
    final next = _chain.then((_) => step());
    _chain = next.then((_) {}, onError: (_) {});
    return next;
  }

  /// The waiting list, keeping every entry that still reads. A value of
  /// the wrong shape altogether is set aside and the list starts empty.
  Future<List<PendingShare>> _read() async {
    final raw = await db.deviceSettingsDao.read(_key);
    if (raw == null) return [];
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      decoded = null;
    }
    if (decoded is! List) {
      await db.deviceSettingsDao.write(_unreadableKey, raw);
      await db.deviceSettingsDao.clear(_key);
      return [];
    }
    return [for (final m in decoded) ?PendingShare.fromJson(m)];
  }

  Future<void> _write(List<PendingShare> all) => all.isEmpty
      ? db.deviceSettingsDao.clear(_key)
      : db.deviceSettingsDao
          .write(_key, jsonEncode([for (final p in all) p.toJson()]));

  /// Takes what waits on the platform side, then clears share copies no
  /// waiting share still needs.
  Future<void> start() async {
    await writesReady;
    source.onArrival = () => unawaited(_pull());
    await _pull();
    await purgeMissingProfiles();
    await _serial(() async {
      final keep = {
        for (final p in await _read())
          for (final f in p.payload.files) f.path,
      };
      await source.sweep(keep);
    });
  }

  Future<void> _pull() => _serial(() async {
        _unwritten.addAll(await source.takePending());
        if (_unwritten.isEmpty) return;
        final got = [..._unwritten];
        final all = await _read();
        var id = all.fold<int>(0, (m, p) => p.id > m ? p.id : m);
        final profile = activeProfileId();
        await _write([
          ...all,
          for (final p in got)
            PendingShare(id: ++id, profileId: profile, payload: p),
        ]);
        _unwritten.clear();
        if (!_disposed) notifyListeners();
      });

  /// The oldest share for [profileId] (or for anyone), still waiting.
  Future<PendingShare?> nextFor(int profileId) => _serial(() async {
        for (final p in await _read()) {
          if (p.profileId == null || p.profileId == profileId) return p;
        }
        return null;
      });

  /// A shell is about to try saving [id]: counted first, on disk.
  Future<void> attempt(int id) => _serial(() async {
        await _write([
          for (final p in await _read()) p.id == id ? p.tried() : p,
        ]);
      });

  /// [share] is given up on: it no longer waits, and its copies go.
  Future<void> drop(PendingShare share) async {
    await done(share.id);
    for (final f in share.payload.files) {
      _discard(f.path);
    }
  }

  /// Shares bound to a reader who no longer exists (removed from the
  /// parents' screen, or replaced by a restore) go, with their copies:
  /// no other reader may take them.
  Future<void> purgeMissingProfiles() => _serial(() async {
        final all = await _read();
        if (all.isEmpty) return;
        final alive = {for (final p in await db.profilesDao.all()) p.id};
        final orphans = [
          for (final p in all)
            if (p.profileId != null && !alive.contains(p.profileId)) p,
        ];
        if (orphans.isEmpty) return;
        await _write([
          for (final p in all)
            if (!orphans.contains(p)) p,
        ]);
        for (final p in orphans) {
          for (final f in p.payload.files) {
            _discard(f.path);
          }
        }
      });

  /// [id] is saved; it no longer waits.
  Future<void> done(int id) => _serial(() async {
        await _write([
          for (final p in await _read())
            if (p.id != id) p,
        ]);
      });

  @override
  void dispose() {
    _disposed = true;
    source.onArrival = null;
    super.dispose();
  }
}
