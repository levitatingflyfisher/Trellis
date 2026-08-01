/// The chapters drawer's own logic (ADR-0013, Campaign 7): one chapter
/// list spanning a whole audiobook's files, addressed the same way the
/// position law is — (fileIdx, startMs). M4B/M4A files contribute their
/// own chpl-atom chapters (`intake_core`'s `parseM4bChapters`); a file
/// with none (an MP3, or an M4B that simply has no chpl atom) contributes
/// exactly one chapter of its own, starting at 0 — "each file is a
/// chapter" from the spec, applied uniformly rather than as a special
/// case.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:intake_core/intake_core.dart';

import '../../db/database.dart';

/// One chapter, addressed in the same (fileIdx, startMs) terms as a
/// Position or a Capture.
class AudiobookChapter {
  final int fileIdx;
  final int startMs;
  final String title;
  const AudiobookChapter({
    required this.fileIdx,
    required this.startMs,
    required this.title,
  });
}

/// Only the first 32MB of a file is ever read for chapter parsing — a
/// well-formed M4B/M4A carries its `moov` box (and the `chpl` atom inside
/// it) near the front, long before the actual audio payload. A file whose
/// `moov` lands past this cap degrades to "no chapters found" for that
/// file (parseM4bChapters's own truncation tolerance), never a multi-
/// hundred-MB read.
const audiobookChapterPrefixCap = 32 * 1024 * 1024;

Uint8List readAudiobookChapterPrefix(String path) {
  final file = File(path);
  final len = file.lengthSync();
  final cap = len < audiobookChapterPrefixCap ? len : audiobookChapterPrefixCap;
  final raf = file.openSync();
  try {
    return raf.readSync(cap);
  } finally {
    raf.closeSync();
  }
}

/// Builds the full chapter list for [files] (already in playback order).
/// [readPrefix] is injectable so tests never touch a real filesystem —
/// the real caller passes [readAudiobookChapterPrefix].
List<AudiobookChapter> chaptersFor(
  List<AudiobookFileRow> files,
  Uint8List Function(String path) readPrefix,
) {
  final chapters = <AudiobookChapter>[];
  for (final f in files) {
    final parsed = parseM4bChapters(readPrefix(f.path));
    if (parsed.isEmpty) {
      chapters.add(
        AudiobookChapter(
          fileIdx: f.fileIdx,
          startMs: 0,
          title: 'File ${f.fileIdx + 1}',
        ),
      );
    } else {
      for (final c in parsed) {
        chapters.add(
          AudiobookChapter(fileIdx: f.fileIdx, startMs: c.startMs, title: c.title),
        );
      }
    }
  }
  return chapters;
}
