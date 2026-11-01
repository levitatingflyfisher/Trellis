/// Writing a finished transcription onto the episode work (ADR-0002).
///
/// One transaction replaces the work's spine rows — segments, layers,
/// alignments — from the first segment that changed. It is written again
/// after every window while the transcript is made, so the unchanged part
/// keeps its rows and a reader's place in it. Over the show notes (no
/// alignments yet) everything is replaced and the place cleared: a cursor
/// over vanished segments would lie. The alignment blob carries best-effort word timings as JSON
/// `[[word, t0, t1], …]`; sentence-level stays the guarantee.
///
/// A translate pass rides along as `mt` layer rows projected onto the SAME
/// segments by time overlap: each English span joins the transcript segment
/// holding its midpoint. Partial translation is natural (per-segment layers,
/// ADR-0002), never an error.
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:loom_core/loom_core.dart' as core;
import 'package:ml_runtime/ml_runtime.dart';
import 'package:transcribe_core/transcribe_core.dart';

import '../../db/database.dart';

/// `[[word, tStartMs, tEndMs], …]` for the words of [chunks] whose midpoint
/// falls inside [a]'s span. Empty when the engine produced no word timings —
/// an absence, never an invention.
List<List<Object>> wordTimingRows(
  core.Alignment a,
  List<TranscriptChunk> chunks,
) {
  final rows = <List<Object>>[];
  for (final c in chunks) {
    for (final w in c.words ?? const <WordTiming>[]) {
      final mid = w.midpointMs;
      if (mid >= a.tStartMs && mid < a.tEndMs) {
        rows.add([w.word, w.tStartMs, w.tEndMs]);
      }
    }
  }
  return rows;
}

Uint8List encodeWordTimingBlob(List<List<Object>> rows) =>
    Uint8List.fromList(utf8.encode(jsonEncode(rows)));

List<List<Object>> decodeWordTimingBlob(Uint8List blob) => [
  for (final row in jsonDecode(utf8.decode(blob)) as List)
    [
      (row as List)[0] as String,
      (row[1] as num).toInt(),
      (row[2] as num).toInt(),
    ],
];

/// segmentIdx → English text: every translated span (via its alignment)
/// joins the transcript segment whose span holds its midpoint; several
/// spans in one segment concatenate in time order.
Map<int, String> projectTranslation({
  required List<core.Alignment> transcriptAlignments,
  required TranscriptionResult translated,
}) {
  final textOf = {for (final s in translated.segments) s.idx: s.text};
  final out = <int, String>{};
  final sorted = [...translated.alignments]
    ..sort((a, b) => a.tStartMs.compareTo(b.tStartMs));
  for (final span in sorted) {
    final mid = (span.tStartMs + span.tEndMs) ~/ 2;
    core.Alignment? home;
    for (final t in transcriptAlignments) {
      if (mid >= t.tStartMs && mid < t.tEndMs) {
        home = t;
        break;
      }
    }
    if (home == null) continue;
    final text = textOf[span.segmentIdx];
    if (text == null || text.isEmpty) continue;
    final existing = out[home.segmentIdx];
    out[home.segmentIdx] = existing == null ? text : '$existing $text';
  }
  return out;
}

/// Replaces [workId]'s spine rows with [result] (and [translation]'s mt
/// layer when present) in ONE transaction. The work learns its language
/// from a transcribe run when it had none, but only a `declared` one (the
/// user's, the work's own): a `feed` or `detected` language still labels
/// the transcript, which translate offers need, yet is only a guess about
/// the show. Persisting it would outrank the feed's tag on every later run.
Future<void> writeTranscript({
  required AppDatabase db,
  required int workId,
  required TranscriptionResult result,
  TranscriptionResult? translation,
  String? langSource,
}) async {
  final mt = translation == null
      ? const <int, String>{}
      : projectTranslation(
          transcriptAlignments: result.alignments,
          translated: translation,
        );

  await db.transaction(() async {
    // Written again after every window while it is made: the part that
    // did not change keeps its rows, so a reader's place there stays.
    final keep = await _unchangedPrefix(db, workId, result);
    if (keep == null || result.segments.isEmpty) {
      // Not a transcript yet (the show notes): a place over them would lie.
      await (db.delete(
        db.positions,
      )..where((p) => p.workId.equals(workId))).go();
    } else {
      // A place past a tail that got shorter goes to the last sentence.
      await (db.update(db.positions)..where(
            (p) =>
                p.workId.equals(workId) &
                p.segmentIdx.isBiggerOrEqualValue(result.segments.length),
          ))
          .write(
            PositionsCompanion(
              segmentIdx: Value(result.segments.length - 1),
              wordIdx: const Value(0),
            ),
          );
    }
    final from = keep ?? 0;
    await (db.delete(db.alignments)..where(
          (a) =>
              a.workId.equals(workId) & a.segmentIdx.isBiggerOrEqualValue(from),
        ))
        .go();
    await (db.delete(db.layers)..where(
          (l) =>
              l.workId.equals(workId) &
              (l.segmentIdx.isBiggerOrEqualValue(from) |
                  (translation == null
                      ? const Constant(false)
                      : l.kind.equals(core.LayerKind.mt.name) &
                            l.lang.equals(translation.lang))),
        ))
        .go();
    await (db.delete(db.segments)..where(
          (s) => s.workId.equals(workId) & s.idx.isBiggerOrEqualValue(from),
        ))
        .go();

    await db.spineDao.insertSegments(workId, [
      for (final s in result.segments)
        if (s.idx >= from) (idx: s.idx, kind: s.kind.name, text: s.text),
    ]);
    await db.spineDao.insertLayers(workId, [
      for (final l in result.layers)
        if (l.segmentIdx >= from)
          (
            segmentIdx: l.segmentIdx,
            lang: l.lang,
            kind: l.kind.name,
            text: l.text,
          ),
      for (final e in mt.entries)
        (
          segmentIdx: e.key,
          lang: translation!.lang,
          kind: core.LayerKind.mt.name,
          text: e.value,
        ),
    ]);
    await db.batch(
      (b) => b.insertAll(db.alignments, [
        for (final a in result.alignments)
          if (a.segmentIdx >= from)
            AlignmentsCompanion.insert(
              workId: workId,
              segmentIdx: a.segmentIdx,
              tStartMs: a.tStartMs,
              tEndMs: a.tEndMs,
              wordTimings: Value(
                encodeWordTimingBlob(wordTimingRows(a, result.mergedChunks)),
              ),
            ),
      ]),
    );

    // 'und' is an honest "could not tell", never worth persisting.
    if (result.layerKind == core.LayerKind.transcript &&
        result.lang != 'und' &&
        (langSource == null || langSource == 'declared')) {
      await (db.update(db.works)
            ..where((w) => w.id.equals(workId) & w.lang.isNull()))
          .write(WorksCompanion(lang: Value(result.lang)));
    }
  });
}

/// How many of [result]'s segments the work already holds unchanged, text
/// and times, from the first; null when what it holds is not a transcript
/// (no alignments: the show notes), which is replaced whole.
Future<int?> _unchangedPrefix(
  AppDatabase db,
  int workId,
  TranscriptionResult result,
) async {
  final aligned = {
    for (final a in await db.spineDao.alignmentsOf(workId)) a.segmentIdx: a,
  };
  if (aligned.isEmpty) return null;
  final held = await db.spineDao.segmentsOf(workId);
  var keep = 0;
  while (keep < held.length && keep < result.segments.length) {
    final h = held[keep];
    final a = aligned[h.idx];
    final want = result.alignments[keep];
    if (h.idx != keep ||
        h.body != result.segments[keep].text ||
        a == null ||
        a.tStartMs != want.tStartMs ||
        a.tEndMs != want.tEndMs) {
      break;
    }
    keep++;
  }
  return keep;
}

/// Takes [workId]'s transcript away whole — segments, layers, alignments
/// and the place in them — in one transaction: what discarding a
/// transcription whose text showed as it was made leaves behind. The show
/// notes stay in their own table.
Future<void> removeTranscript(AppDatabase db, int workId) =>
    db.transaction(() async {
      await (db.delete(db.positions)..where((p) => p.workId.equals(workId)))
          .go();
      await (db.delete(db.alignments)..where((a) => a.workId.equals(workId)))
          .go();
      await (db.delete(db.layers)..where((l) => l.workId.equals(workId)))
          .go();
      await (db.delete(db.segments)..where((s) => s.workId.equals(workId)))
          .go();
    });
