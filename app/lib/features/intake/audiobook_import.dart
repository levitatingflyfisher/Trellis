/// The audiobook import repository (ADR-0013, Campaign 7): turns a picked
/// file list into one new Work + its ordered AudiobookFiles rows, with
/// every dart:io touch behind an injectable interface so this is
/// unit-testable without a real filesystem — the same shape as every other
/// intake door's DB-writing half.
library;

import 'dart:io';

import 'package:intake_core/intake_core.dart';

import '../../db/database.dart';
import 'audiobook_picker_gateway.dart';
import 'paste_intake.dart' show epochDayUtcNow;

/// What one import attempt produced. [skippedNames] lists files that
/// could no longer be read at import time (moved/deleted between picking
/// and confirming) — the import still succeeds with whatever remained
/// readable, a calm sentence rather than a crash.
typedef AudiobookImportOutcome = ({
  int workId,
  int fileCount,
  List<String> skippedNames,
});

void _defaultCopyFile(String sourcePath, String destPath) {
  final dest = File(destPath);
  dest.parent.createSync(recursive: true);
  File(sourcePath).copySync(destPath);
}

class AudiobookImportRepository {
  AudiobookImportRepository({
    required this.db,
    required this.destinationFor,
    bool Function(String path)? readable,
    void Function(String sourcePath, String destPath)? copyFile,
  }) : readable = readable ?? ((p) => File(p).existsSync()),
       copyFile = copyFile ?? _defaultCopyFile;

  final AppDatabase db;

  /// Where the copied file for ([workId], [fileIdx]) lands — the caller
  /// passes `services.audiobookFileFor`; tests pass an in-memory stand-in.
  final File Function(int workId, int fileIdx, String sourceName)
  destinationFor;

  /// Re-checked per file right before copying — the "moved folder" case
  /// (ADR-0013): a source can vanish between picking and confirming, and
  /// this is where that gets caught.
  final bool Function(String path) readable;

  final void Function(String sourcePath, String destPath) copyFile;

  /// Imports [picked] as one new audiobook work titled [title]. Files
  /// sharing a source [PickedAudioFile.path] are deduplicated (first one
  /// wins — a picker returning the same file twice is not two files).
  /// Ordering is natural sort on [PickedAudioFile.name] (ADR-0013: Phase
  /// 1 never supplies disc/track tags, so [orderAudiobookFiles]'s tagged
  /// branch is exercised at its own layer, not from here).
  ///
  /// Returns null when every picked file turned out unreadable — nothing
  /// was created, there is nothing to import. A PARTIAL loss (some files
  /// readable, some not) still imports the readable ones.
  Future<AudiobookImportOutcome?> import({
    required int profileId,
    required List<PickedAudioFile> picked,
    required String title,
  }) async {
    final seenPaths = <String>{};
    final deduped = [
      for (final f in picked)
        if (seenPaths.add(f.path)) f,
    ];
    final ordered = [...deduped]
      ..sort((a, b) => naturalCompareAudiobookNames(a.name, b.name));

    final keep = <PickedAudioFile>[];
    final skipped = <String>[];
    for (final f in ordered) {
      if (readable(f.path)) {
        keep.add(f);
      } else {
        skipped.add(f.name);
      }
    }
    if (keep.isEmpty) return null;

    final workId = await db.spineDao.insertWork(
      profileId: profileId,
      kind: 'audiobook',
      title: title,
      persistence: 'work',
      firstSeenEpochDay: epochDayUtcNow(),
    );
    await db.audiobooksDao.insertAudiobook(workId);

    final destinations = <String>[];
    for (var i = 0; i < keep.length; i++) {
      final dest = destinationFor(workId, i, keep[i].name);
      copyFile(keep[i].path, dest.path);
      destinations.add(dest.path);
    }
    await db.audiobooksDao.insertFiles(workId, destinations);

    return (workId: workId, fileCount: keep.length, skippedNames: skipped);
  }
}
