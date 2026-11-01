/// What each work keeps on this device (1.5.8): its downloaded audio, a
/// leftover decoded copy, its transcript and each translation, with a
/// size and one way to delete each. The storage page lists every work;
/// the work page's ⋮ offers the same deletes for one.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:openhearth_design/openhearth_design.dart';

import '../../db/database.dart';
import '../../services/device_services.dart';
import '../episodes/episode_actions.dart';
import '../episodes/episode_selection.dart' show EpisodeBulk;
import '../models/format.dart';
import '../reader/translation/language_names.dart';
import '../reader/translation/translation_job.dart';
import 'recently_deleted.dart';

enum StoredKind { audio, decoded, transcript, translation }

class StoredPart {
  final StoredKind kind;

  /// The translation's language; null for every other kind.
  final String? lang;
  final int bytes;

  const StoredPart(this.kind, this.bytes, {this.lang});

  /// Text in the database is measured, but the file only shrinks once
  /// SQLite reuses the pages, so its size is "about".
  bool get inDatabase =>
      kind == StoredKind.transcript || kind == StoredKind.translation;

  String get label => switch (kind) {
        StoredKind.audio => 'Downloaded audio',
        StoredKind.decoded => 'Decoded audio',
        StoredKind.transcript => 'Transcript',
        StoredKind.translation => '${_langName(lang!)} translation',
      };

  String get sizeLabel =>
      inDatabase ? 'about ${formatBytes(bytes)}' : formatBytes(bytes);

  /// The ⋮ item and the delete button: names the act.
  String get deleteLabel => switch (kind) {
        StoredKind.audio => 'Remove download',
        StoredKind.decoded => 'Delete decoded audio',
        StoredKind.transcript => 'Delete transcript',
        StoredKind.translation => 'Delete ${_langName(lang!)} translation',
      };

  /// A stable key fragment: `audio`, `transcript`, `translation-ru`.
  String get keyName =>
      kind == StoredKind.translation ? 'translation-$lang' : kind.name;

  @override
  bool operator ==(Object other) =>
      other is StoredPart &&
      other.kind == kind &&
      other.lang == lang &&
      other.bytes == bytes;

  @override
  int get hashCode => Object.hash(kind, lang, bytes);
}

String _langName(String code) =>
    languageDisplayName(code.trim().toLowerCase().split(RegExp('[-_]')).first);

/// One work's stored parts. [work] is null for audio left behind by a
/// work that no longer exists (an unfollowed show's download).
class WorkStorage {
  final int workId;
  final Work? work;
  final Episode? episode;
  final List<StoredPart> parts;

  const WorkStorage({
    required this.workId,
    required this.work,
    required this.episode,
    required this.parts,
  });

  String get title => work?.title ?? 'Removed item';
  int get bytes => parts.fold(0, (a, p) => a + p.bytes);
  bool has(StoredKind kind) => parts.any((p) => p.kind == kind);
}

/// Every work holding something, biggest first. [profileId] keeps only
/// that reader's works (and audio no work owns any more); [onlyWorkId]
/// narrows it to one work (the work page). Without [services] (the web) only the
/// database parts are listed. File IO is sync on purpose: real-io
/// futures never complete under a widget test's fake-async zone.
Future<List<WorkStorage>> loadWorkStorage(
  AppDatabase db, {
  DeviceServices? services,
  int? profileId,
  int? onlyWorkId,
}) async {
  final parts = <int, List<StoredPart>>{};
  void add(int id, StoredPart p) {
    if (onlyWorkId != null && id != onlyWorkId) return;
    (parts[id] ??= []).add(p);
  }

  if (services != null && onlyWorkId != null) {
    // One work: look at its own files, not the whole cache.
    final url = (await db.feedsDao.episodeOf(onlyWorkId))?.enclosureUrl;
    final audio = url == null ? null : services.audioFileFor(onlyWorkId, url);
    if (audio != null && audio.existsSync()) {
      add(onlyWorkId, StoredPart(StoredKind.audio, audio.lengthSync()));
    }
    final pcm = services.pcmFileFor(onlyWorkId);
    if (pcm.existsSync()) {
      add(onlyWorkId, StoredPart(StoredKind.decoded, pcm.lengthSync()));
    }
  } else if (services != null) {
    _scan(services.audioFileFor(0, '').parent, (id, name, bytes) {
      // A partial download is the downloader's, not a stored file.
      if (name.endsWith('.part') || name.endsWith('.validator')) return;
      add(id, StoredPart(StoredKind.audio, bytes));
    });
    _scan(services.pcmFileFor(0).parent, (id, name, bytes) {
      add(id, StoredPart(StoredKind.decoded, bytes));
    });
  }
  for (final r in await db.spineDao.storedText(workId: onlyWorkId)) {
    add(
        r.workId,
        r.lang == null
            ? StoredPart(StoredKind.transcript, r.bytes)
            : StoredPart(StoredKind.translation, r.bytes, lang: r.lang));
  }

  final ids = parts.keys.toList();
  final works = <int, Work>{};
  final episodes = <int, Episode>{};
  for (final c in chunksForSql(ids)) {
    for (final w in await (db.select(db.works)..where((w) => w.id.isIn(c)))
        .get()) {
      works[w.id] = w;
    }
    for (final e
        in await (db.select(db.episodes)..where((e) => e.workId.isIn(c)))
            .get()) {
      episodes[e.workId] = e;
    }
  }
  final out = [
    for (final id in ids)
      if (profileId == null ||
          works[id] == null ||
          works[id]!.profileId == profileId)
        WorkStorage(
        workId: id,
        work: works[id],
        episode: episodes[id],
        parts: parts[id]!..sort(_partOrder),
      ),
  ]..sort((a, b) => b.bytes.compareTo(a.bytes));
  return out;
}

int _partOrder(StoredPart a, StoredPart b) {
  final k = a.kind.index.compareTo(b.kind.index);
  return k != 0 ? k : (a.lang ?? '').compareTo(b.lang ?? '');
}

/// Each file named `<workId>…` in [dir].
void _scan(Directory dir, void Function(int id, String name, int bytes) on) {
  if (!dir.existsSync()) return;
  for (final e in dir.listSync()) {
    if (e is! File) continue;
    final name = e.uri.pathSegments.last;
    final id = int.tryParse(name.split('.').first);
    if (id != null) on(id, name, e.lengthSync());
  }
}

/// Asks once, honest about what goes and how it comes back. A transcript
/// or translation that Recently deleted keeps ([restorable]) goes without
/// asking: the lasting way back replaces the question (1.5.9).
Future<bool> confirmDeletePart(
    BuildContext context, WorkStorage w, StoredPart p,
    {bool restorable = false}) {
  if (restorable && p.inDatabase) return Future.value(true);
  final (title, message) = switch (p.kind) {
    StoredKind.audio => (
        'Remove download?',
        'Frees ${formatBytes(p.bytes)}. The episode stays, and you can '
            'download it again.'
      ),
    StoredKind.decoded => (
        'Delete decoded audio?',
        'Frees ${formatBytes(p.bytes)}. It is made again the next time it '
            'is needed.'
      ),
    StoredKind.transcript => (
        'Delete transcript?',
        [
          'The transcript',
          if (w.has(StoredKind.translation)) ', its translations,',
          ' and your reading place in it go. You can transcribe again. '
              'The audio and your listening place stay.',
        ].join()
      ),
    StoredKind.translation => (
        'Delete the ${_langName(p.lang!)} translation?',
        'The transcript stays. You can translate again.'
      ),
  };
  return showOhConfirm(
    context,
    title: title,
    message: message,
    confirmLabel: p.deleteLabel,
    cancelLabel: 'Keep',
    destructive: true,
  );
}

/// Deletes [p] and says what happened. A transcribing job keeps what it
/// is using (the audio, its decoded copy, the transcript it will write),
/// the same rule as Remove download; a translating one keeps its
/// language, and the transcript that language is keyed to. With a
/// Recently deleted folder ([DeviceServices.recentlyDeleted]; none on the
/// web) a transcript or translation is kept there first.
Future<String> deletePart(
  WorkStorage w,
  StoredPart p, {
  required AppDatabase db,
  DeviceServices? services,
  EpisodeActions? actions,
}) async {
  final id = w.workId;
  switch (p.kind) {
    case StoredKind.audio:
      final episode = w.episode;
      if (w.work != null && episode != null && actions != null) {
        final r = await actions
            .removeDownloads([(work: w.work!, episode: episode)]);
        // A file fetched under an older enclosure URL has another name
        // than the one removeDownloads looks for; nothing is using it.
        if (r.kept == 0 && services != null) {
          final left = _deleteNamed(services.audioFileFor(0, '').parent, id);
          if (r.removed == 0 && left > 0) return 'Removed the download.';
        }
        return EpisodeBulk.removedMessage(r);
      }
      // Nothing can be using a removed item's file.
      if (services != null) {
        _deleteNamed(services.audioFileFor(0, '').parent, id);
      }
      return 'Removed the download.';
    case StoredKind.decoded:
      if (await isTranscribing(db, id)) {
        return 'Kept: a transcription is using it.';
      }
      if (services != null) {
        final f = services.pcmFileFor(id);
        if (f.existsSync()) f.deleteSync();
      }
      return 'Deleted the decoded audio.';
    case StoredKind.transcript:
      if (await isTranscribing(db, id)) {
        return 'Kept: a transcription is running for this item.';
      }
      if (await isTranslating(db, id)) {
        return 'Kept: a translation is running for this item.';
      }
      final bin = services?.recentlyDeleted;
      if (bin == null) {
        await db.spineDao.deleteTranscript(id);
        return 'Deleted the transcript. You can transcribe again.';
      }
      return await _keepThenDelete(db, bin, w, p,
              snapshot: () => db.spineDao.snapshotTranscript(id),
              delete: () => db.spineDao.deleteTranscript(id)) ??
          'Deleted the transcript. Restore it from Recently deleted.';
    case StoredKind.translation:
      final lang = p.lang!;
      if (await isTranslating(db, id, lang)) {
        return 'Kept: a translation is running for this item.';
      }
      final bin = services?.recentlyDeleted;
      if (bin == null) {
        await db.spineDao.deleteTranslation(id, lang);
        return 'Deleted the ${_langName(lang)} translation.';
      }
      return await _keepThenDelete(db, bin, w, p,
              snapshot: () => db.spineDao.snapshotTranslation(id, lang),
              delete: () => db.spineDao.deleteTranslation(id, lang)) ??
          'Deleted the ${_langName(lang)} translation. Restore it from '
              'Recently deleted.';
  }
}

/// Reads, saves and deletes in one transaction: if the copy can't be
/// written nothing is deleted, and nothing can change between what is
/// kept and what goes. Null when it went; otherwise why it was kept. The
/// files aren't part of the transaction, so a delete that fails after the
/// copy was saved lets the copy go too: Recently deleted never lists
/// something that is still there.
Future<String?> _keepThenDelete(
  AppDatabase db,
  RecentlyDeleted bin,
  WorkStorage w,
  StoredPart p, {
  required Future<SnapshotRows> Function() snapshot,
  required Future<void> Function() delete,
}) async {
  final id = bin.newId(w.workId, p.kind, p.lang);
  try {
    await db.transaction(() async {
      final rows = await snapshot();
      try {
        await bin.save(
            DeletedSnapshot(
              id: id,
              workId: w.workId,
              workTitle: w.title,
              kind: p.kind,
              lang: p.lang,
              deletedAt: bin.now(),
              bytes: p.bytes,
            ),
            rows);
      } catch (e) {
        throw _CopyNotSaved(e);
      }
      await delete();
    });
    return null;
  } catch (e) {
    debugPrint('Delete of ${w.workId} ${p.kind.name} kept: $e');
    try {
      await bin.discard(id);
    } catch (e) {
      debugPrint('Recently deleted: could not discard $id: $e');
    }
    return deleteFailedMessage(e);
  }
}

class _CopyNotSaved implements Exception {
  final Object cause;
  _CopyNotSaved(this.cause);
  @override
  String toString() => 'copy not saved: $cause';
}

/// Why a delete that threw kept everything, in plain words.
@visibleForTesting
String deleteFailedMessage(Object error) {
  final cause = error is _CopyNotSaved ? error.cause : error;
  // ENOSPC is 28 on Linux and Android, the only tier that keeps copies.
  if (cause is FileSystemException &&
      (cause.osError?.errorCode == 28 ||
          (cause.osError?.message.contains('No space') ?? false))) {
    return 'Kept: there was no room to keep a copy, so nothing was deleted.';
  }
  if (error is _CopyNotSaved || cause is FileSystemException) {
    return 'Kept: a copy couldn’t be saved, so nothing was deleted.';
  }
  return 'Kept: it couldn’t be deleted, so nothing changed.';
}

/// Deletes [id]'s complete files in [dir]; returns how many.
int _deleteNamed(Directory dir, int id) {
  if (!dir.existsSync()) return 0;
  var n = 0;
  for (final e in dir.listSync()) {
    if (e is! File) continue;
    final name = e.uri.pathSegments.last;
    if (name.split('.').first != '$id') continue;
    if (name.endsWith('.part') || name.endsWith('.validator')) continue;
    e.deleteSync();
    n++;
  }
  return n;
}

/// Whether an unfinished transcribe job (either stage) holds [workId].
Future<bool> isTranscribing(AppDatabase db, int workId) async =>
    (await _transcribeJobsOf(db, workId)).isNotEmpty;

/// Whether something is writing [workId]'s translation into [lang] (any
/// language when null). Two writers: a transcribe-and-translate job, from
/// the same job rows [isTranscribing] reads, whose Whisper translate
/// stage only ever writes English; and the reader's run, which has no job
/// row and is asked directly ([TranslationRun.isLive]).
Future<bool> isTranslating(AppDatabase db, int workId, [String? lang]) async {
  if (TranslationRun.isLive(workId, lang)) return true;
  if (lang != null && lang != 'en') return false;
  return (await _transcribeJobsOf(db, workId))
      .any((payload) => payload['translate'] == true);
}

Future<List<Map<Object?, Object?>>> _transcribeJobsOf(
    AppDatabase db, int workId) async {
  final out = <Map<Object?, Object?>>[];
  for (final j in await db.jobsDao.unfinished()) {
    if (j.kind != 'transcribe') continue;
    try {
      final payload = jsonDecode(j.payloadJson);
      if (payload is Map && (payload['workId'] as num?)?.toInt() == workId) {
        out.add(payload);
      }
    } on FormatException {
      continue;
    }
  }
  return out;
}
