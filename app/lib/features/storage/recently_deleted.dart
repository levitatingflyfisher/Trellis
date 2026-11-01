/// "Recently deleted" (1.5.9): a deleted transcript or translation waits
/// here for 30 days before it is gone for good (the fleet delete ruling:
/// a deliberate delete gets a way back that lasts, not a timed snackbar).
///
/// No schema change: each snapshot is two JSON files beside the database
/// under `<app support>/recently_deleted/`: `<id>.json`, the small
/// description the list shows, and `<id>.rows.json`, the rows themselves,
/// read only on restore. File IO is sync on purpose: real-io futures never
/// complete under a widget test's fake-async zone.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../db/database.dart';
import 'work_storage.dart';

/// One deleted transcript or translation, as the list shows it.
class DeletedSnapshot {
  final String id;
  final int workId;
  final String workTitle;

  /// [StoredKind.transcript] or [StoredKind.translation].
  final StoredKind kind;

  /// The translation's language; null for a transcript.
  final String? lang;
  final DateTime deletedAt;
  final int bytes;

  const DeletedSnapshot({
    required this.id,
    required this.workId,
    required this.workTitle,
    required this.kind,
    required this.lang,
    required this.deletedAt,
    required this.bytes,
  });

  /// What it was, as the storage page named it: `Transcript`,
  /// `Russian translation`.
  String get label => StoredPart(kind, bytes, lang: lang).label;

  Map<String, Object?> toJson() => {
        'id': id,
        'workId': workId,
        'workTitle': workTitle,
        'kind': kind.name,
        'lang': lang,
        'deletedAtMs': deletedAt.millisecondsSinceEpoch,
        'bytes': bytes,
      };

  factory DeletedSnapshot.fromJson(Map<String, Object?> j) {
    final kind = StoredKind.values.byName(j['kind']! as String);
    if (kind != StoredKind.transcript && kind != StoredKind.translation) {
      throw FormatException('not a restorable kind: ${kind.name}');
    }
    return DeletedSnapshot(
      id: j['id']! as String,
      workId: (j['workId']! as num).toInt(),
      workTitle: j['workTitle']! as String,
      kind: kind,
      lang: j['lang'] as String?,
      deletedAt: DateTime.fromMillisecondsSinceEpoch(
          (j['deletedAtMs']! as num).toInt()),
      bytes: (j['bytes']! as num).toInt(),
    );
  }
}

/// The snapshots on disk. [now] is the clock a purge measures age by.
class RecentlyDeleted {
  final Directory dir;
  final DateTime Function() now;

  RecentlyDeleted(this.dir, {DateTime Function()? now})
      : now = now ?? DateTime.now;

  static final _safeId = RegExp(r'^[A-Za-z0-9_-]+$');

  File _meta(String id) => File('${dir.path}/${_checked(id)}.json');
  File _rows(String id) => File('${dir.path}/${_checked(id)}.rows.json');

  static String _checked(String id) {
    if (!_safeId.hasMatch(id)) throw ArgumentError.value(id, 'id');
    return id;
  }

  /// A fresh id for [workId]'s [kind]: unique per deletion, and a plain
  /// file name.
  String newId(int workId, StoredKind kind, [String? lang]) => [
        now().microsecondsSinceEpoch,
        workId,
        kind.name,
        if (lang != null) lang.replaceAll(RegExp('[^A-Za-z0-9]'), '_'),
      ].join('-');

  /// Writes the rows, then the description: a snapshot is listed only
  /// once both are whole. Each goes through a temporary file and a rename,
  /// so a kill mid-write leaves nothing half-written that a list reads.
  Future<DeletedSnapshot> save(DeletedSnapshot meta, SnapshotRows rows) async {
    dir.createSync(recursive: true);
    _writeAtomic(_rows(meta.id), jsonEncode(_encodeRows(rows)));
    _writeAtomic(_meta(meta.id), jsonEncode(meta.toJson()));
    return meta;
  }

  /// Newest first. A damaged description is logged and left out; it never
  /// takes the list down with it.
  Future<List<DeletedSnapshot>> list() async {
    if (!dir.existsSync()) return const [];
    final out = <DeletedSnapshot>[];
    for (final f in _metaFiles()) {
      final s = _read(f);
      if (s != null) out.add(s);
    }
    out.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    return out;
  }

  /// The rows of snapshot [id]. Throws if they are missing or damaged.
  Future<SnapshotRows> rowsOf(String id) async =>
      _decodeRows(jsonDecode(_rows(id).readAsStringSync()));

  /// Removes snapshot [id], including what a save that failed part-way
  /// left behind.
  Future<void> discard(String id) async {
    for (final f in [
      _meta(id),
      _rows(id),
      File('${_meta(id).path}.tmp'),
      File('${_rows(id).path}.tmp'),
    ]) {
      if (f.existsSync()) f.deleteSync();
    }
  }

  /// Deletes every snapshot deleted more than [age] ago, and rows a kill
  /// left without their description once they are that old too. Returns
  /// how many snapshots went. Per file and failure-tolerant: this runs at
  /// app start, which a broken file must never stop.
  Future<int> purgeOlderThan(Duration age) async {
    if (!dir.existsSync()) return 0;
    final cutoff = now().subtract(age);
    var purged = 0;
    for (final f in _metaFiles()) {
      final s = _read(f);
      if (s == null || !s.deletedAt.isBefore(cutoff)) continue;
      try {
        await discard(s.id);
        purged++;
      } catch (e) {
        debugPrint('Recently deleted: could not purge ${s.id}: $e');
      }
    }
    for (final e in dir.listSync()) {
      if (e is! File || !e.path.endsWith('.rows.json')) continue;
      try {
        final meta = File(e.path.replaceFirst(RegExp(r'\.rows\.json$'), '.json'));
        if (!meta.existsSync() && e.lastModifiedSync().isBefore(cutoff)) {
          e.deleteSync();
        }
      } catch (err) {
        debugPrint('Recently deleted: skipped ${e.path}: $err');
      }
    }
    return purged;
  }

  Iterable<File> _metaFiles() => dir.listSync().whereType<File>().where((f) =>
      f.path.endsWith('.json') && !f.path.endsWith('.rows.json'));

  DeletedSnapshot? _read(File f) {
    try {
      return DeletedSnapshot.fromJson(
          (jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>());
    } catch (e) {
      debugPrint('Recently deleted: skipped ${f.path}: $e');
      return null;
    }
  }

  static void _writeAtomic(File f, String text) {
    final tmp = File('${f.path}.tmp')..writeAsStringSync(text, flush: true);
    tmp.renameSync(f.path);
  }

  // JSON has no bytes: a blob (word timings) travels as {"b64": ...}.
  // Nothing else in a row is a map, so the tag can't be mistaken.
  static Object _encodeRows(SnapshotRows rows) => {
        for (final MapEntry(:key, :value) in rows.entries)
          key: [
            for (final row in value)
              {
                for (final MapEntry(:key, :value) in row.entries)
                  key: value is Uint8List ? {'b64': base64Encode(value)} : value,
              },
          ],
      };

  static SnapshotRows _decodeRows(Object? json) => {
        for (final MapEntry(:key, :value) in (json! as Map).entries)
          key as String: [
            for (final row in value as List)
              {
                for (final MapEntry(:key, :value) in (row as Map).entries)
                  key as String: value is Map
                      ? base64Decode(value['b64'] as String)
                      : value,
              },
          ],
      };
}

/// Puts [s] back and says what happened in plain words. Refuses rather
/// than mix, and keeps the copy unless it can never come back.
Future<String> restoreDeleted(
    AppDatabase db, RecentlyDeleted bin, DeletedSnapshot s) async {
  final lang = s.lang;
  final what = lang == null
      ? 'the transcript'
      : 'the ${StoredPart(s.kind, 0, lang: lang).label}';
  if (await isTranscribing(db, s.workId)) {
    return 'Not restored: a transcription is running for this item.';
  }
  if (lang != null && await isTranslating(db, s.workId, lang)) {
    return 'Not restored: a translation is running for this item.';
  }
  final SnapshotRows rows;
  try {
    rows = await bin.rowsOf(s.id);
  } catch (e) {
    debugPrint('Recently deleted: ${s.id} unreadable: $e');
    return 'Couldn’t restore it: the saved copy is damaged.';
  }
  final RestoreResult result;
  try {
    result = lang == null
        ? await db.spineDao.restoreTranscript(s.workId, rows)
        : await db.spineDao.restoreTranslation(s.workId, lang, rows);
  } catch (e) {
    // One transaction: whatever failed took the whole restore with it.
    debugPrint('Recently deleted: ${s.id} not restored: $e');
    return 'Couldn’t restore it: something went wrong putting it back, so '
        'nothing changed. The copy is kept.';
  }
  switch (result) {
    case RestoreResult.restored:
      await _discardQuietly(bin, s.id);
      return 'Restored $what of “${s.workTitle}”.';
    case RestoreResult.transcriptExists:
      return 'Not restored: this item has a newer transcript. Delete that '
          'one first to bring this one back.';
    case RestoreResult.translationExists:
      return 'Not restored: this item has a newer '
          '${StoredPart(s.kind, 0, lang: lang).label}. Delete that one first '
          'to bring this one back.';
    case RestoreResult.sourceChanged:
      return 'Not restored: the transcript it translates has changed.';
    case RestoreResult.sourceGone:
      return 'Not restored: the transcript it translates is gone. Restore '
          'the transcript first.';
    case RestoreResult.workGone:
      await _discardQuietly(bin, s.id);
      return 'Not restored: the item is no longer in your library.';
  }
}

/// The restore already happened; a copy that won't go only stays listed,
/// and offering it again is refused as a newer one.
Future<void> _discardQuietly(RecentlyDeleted bin, String id) async {
  try {
    await bin.discard(id);
  } catch (e) {
    debugPrint('Recently deleted: could not discard $id: $e');
  }
}
