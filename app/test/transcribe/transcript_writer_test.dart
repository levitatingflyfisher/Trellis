import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loom_core/loom_core.dart' as core;
import 'package:ml_runtime/ml_runtime.dart';
import 'package:transcribe_core/transcribe_core.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/transcribe/transcript_writer.dart';

/// Writing a finished transcription onto the episode work (ADR-0002): the
/// spine rows are REPLACED in one transaction — segments, layers,
/// alignments (with best-effort word timings in the blob), stale positions
/// cleared, the work's language learned. A translate pass projects English
/// text onto the transcript's segments by time overlap, becoming `mt`
/// layer rows — partial translation is natural, never an error.
void main() {
  group('word timings per alignment', () {
    test('words land in the segment whose span holds their midpoint', () {
      final chunks = [
        TranscriptChunk(text: 'ab', tStartMs: 0, tEndMs: 1000, words: [
          WordTiming(word: 'a', tStartMs: 0, tEndMs: 400),
          WordTiming(word: 'b', tStartMs: 400, tEndMs: 900),
        ]),
        TranscriptChunk(text: 'c', tStartMs: 1000, tEndMs: 2000, words: [
          WordTiming(word: 'c', tStartMs: 1100, tEndMs: 1500),
        ]),
      ];
      final rows = wordTimingRows(
          const core.Alignment(segmentIdx: 0, tStartMs: 0, tEndMs: 1000),
          chunks);
      expect(rows, [
        ['a', 0, 400],
        ['b', 400, 900],
      ]);
      final rows2 = wordTimingRows(
          const core.Alignment(segmentIdx: 1, tStartMs: 1000, tEndMs: 2000),
          chunks);
      expect(rows2, [
        ['c', 1100, 1500],
      ]);
    });

    test('no word timings means an empty list, not an invention', () {
      final rows = wordTimingRows(
          const core.Alignment(segmentIdx: 0, tStartMs: 0, tEndMs: 1000),
          [TranscriptChunk(text: 'ab', tStartMs: 0, tEndMs: 1000)]);
      expect(rows, isEmpty);
    });

    test('the blob codec roundtrips', () {
      final rows = [
        ['hola', 0, 300],
        ['mundo', 300, 800],
      ];
      expect(decodeWordTimingBlob(encodeWordTimingBlob(rows)), rows);
    });
  });

  group('projecting a translate pass onto transcript segments', () {
    TranscriptionResult mt(List<(String, int, int)> pieces) =>
        TranscriptionResult(
          lang: 'en',
          layerKind: core.LayerKind.mt,
          segments: [
            for (var i = 0; i < pieces.length; i++)
              core.Segment(
                  idx: i, kind: core.SegmentKind.prose, text: pieces[i].$1)
          ],
          alignments: [
            for (var i = 0; i < pieces.length; i++)
              core.Alignment(
                  segmentIdx: i,
                  tStartMs: pieces[i].$2,
                  tEndMs: pieces[i].$3)
          ],
          layers: [
            for (var i = 0; i < pieces.length; i++)
              core.Layer(
                  segmentIdx: i,
                  lang: 'en',
                  kind: core.LayerKind.mt,
                  text: pieces[i].$1)
          ],
          mergedChunks: [
            for (final p in pieces)
              TranscriptChunk(text: p.$1, tStartMs: p.$2, tEndMs: p.$3)
          ],
        );

    const transcriptSpans = [
      core.Alignment(segmentIdx: 0, tStartMs: 0, tEndMs: 2000),
      core.Alignment(segmentIdx: 1, tStartMs: 2000, tEndMs: 4000),
      core.Alignment(segmentIdx: 2, tStartMs: 4000, tEndMs: 6000),
    ];

    test('each English span joins the transcript segment holding its '
        'midpoint', () {
      final projected = projectTranslation(
          transcriptAlignments: transcriptSpans,
          translated: mt([
            ('Hello there.', 0, 1800),
            ('How are you?', 2100, 3900),
            ('Fine.', 4200, 5800),
          ]));
      expect(projected, {
        0: 'Hello there.',
        1: 'How are you?',
        2: 'Fine.',
      });
    });

    test('two English spans inside one transcript segment concatenate',
        () {
      final projected = projectTranslation(
          transcriptAlignments: transcriptSpans,
          translated: mt([
            ('One.', 0, 800),
            ('Two.', 900, 1900),
            ('Three.', 4200, 5600),
          ]));
      expect(projected[0], 'One. Two.');
      expect(projected.containsKey(1), isFalse,
          reason: 'partial translation is natural — no invented rows');
      expect(projected[2], 'Three.');
    });
  });

  group('writeTranscript', () {
    late AppDatabase db;
    late int profileId;
    late int workId;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      profileId = await db.profilesDao.create('Ada');
      workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: 'Um episódio',
          persistence: 'ephemeron',
          firstSeenEpochDay: 100,
          sourceUrl: 'https://cast.example.test/1.mp3');
      // The feed description placeholder + a stale position over it.
      await db.spineDao.insertSegments(
          workId, const [(idx: 0, kind: 'prose', text: 'Show notes.')]);
      await db.spineDao.savePosition(
          profileId: profileId,
          workId: workId,
          segmentIdx: 0,
          wordIdx: 1,
          lastModality: 'read');
    });
    tearDown(() => db.close());

    TranscriptionResult transcriptResult() => TranscriptionResult(
          lang: 'pt',
          layerKind: core.LayerKind.transcript,
          segments: const [
            core.Segment(
                idx: 0, kind: core.SegmentKind.prose, text: 'Olá mundo.'),
            core.Segment(
                idx: 1, kind: core.SegmentKind.prose, text: 'Tudo bem?'),
          ],
          alignments: const [
            core.Alignment(segmentIdx: 0, tStartMs: 0, tEndMs: 1500),
            core.Alignment(segmentIdx: 1, tStartMs: 1500, tEndMs: 2600),
          ],
          layers: const [
            core.Layer(
                segmentIdx: 0,
                lang: 'pt',
                kind: core.LayerKind.transcript,
                text: 'Olá mundo.'),
            core.Layer(
                segmentIdx: 1,
                lang: 'pt',
                kind: core.LayerKind.transcript,
                text: 'Tudo bem?'),
          ],
          mergedChunks: [
            TranscriptChunk(
                text: 'Olá mundo.',
                tStartMs: 0,
                tEndMs: 1500,
                words: [
                  WordTiming(word: 'Olá', tStartMs: 0, tEndMs: 700),
                  WordTiming(word: 'mundo.', tStartMs: 700, tEndMs: 1500),
                ]),
            TranscriptChunk(text: 'Tudo bem?', tStartMs: 1500, tEndMs: 2600),
          ],
        );

    test('replaces the spine rows and learns the language', () async {
      await writeTranscript(db: db, workId: workId, result: transcriptResult());

      final segments = await db.spineDao.segmentsOf(workId);
      expect([for (final s in segments) s.body], ['Olá mundo.', 'Tudo bem?'],
          reason: 'the placeholder description is gone');

      final layers = await db.spineDao.layersOf(workId, lang: 'pt');
      expect(layers, hasLength(2));
      expect(layers.first.kind, 'transcript');

      final alignments = await db.spineDao.alignmentsOf(workId);
      expect(alignments, hasLength(2));
      expect(alignments.first.tEndMs, 1500);
      expect(decodeWordTimingBlob(alignments.first.wordTimings!), [
        ['Olá', 0, 700],
        ['mundo.', 700, 1500],
      ]);

      final work = (await db.spineDao.worksOf(profileId))
          .singleWhere((w) => w.id == workId);
      expect(work.lang, 'pt');

      expect(
          await db.spineDao.position(profileId: profileId, workId: workId),
          isNull,
          reason: 'a position over vanished segments would lie');
    });

    test('a translate companion becomes mt layer rows on the SAME segments',
        () async {
      final translation = TranscriptionResult(
        lang: 'en',
        layerKind: core.LayerKind.mt,
        segments: const [
          core.Segment(
              idx: 0, kind: core.SegmentKind.prose, text: 'Hello world.'),
          core.Segment(
              idx: 1, kind: core.SegmentKind.prose, text: 'How are you?'),
        ],
        alignments: const [
          core.Alignment(segmentIdx: 0, tStartMs: 0, tEndMs: 1400),
          core.Alignment(segmentIdx: 1, tStartMs: 1600, tEndMs: 2500),
        ],
        layers: const [
          core.Layer(
              segmentIdx: 0,
              lang: 'en',
              kind: core.LayerKind.mt,
              text: 'Hello world.'),
          core.Layer(
              segmentIdx: 1,
              lang: 'en',
              kind: core.LayerKind.mt,
              text: 'How are you?'),
        ],
        mergedChunks: [
          TranscriptChunk(text: 'Hello world.', tStartMs: 0, tEndMs: 1400),
          TranscriptChunk(text: 'How are you?', tStartMs: 1600, tEndMs: 2500),
        ],
      );

      await writeTranscript(
          db: db,
          workId: workId,
          result: transcriptResult(),
          translation: translation);

      final segments = await db.spineDao.segmentsOf(workId);
      expect([for (final s in segments) s.body], ['Olá mundo.', 'Tudo bem?'],
          reason: 'canonical text stays in the source language');

      final en = await db.spineDao.layersOf(workId, lang: 'en');
      expect(en, hasLength(2));
      expect(en.first.kind, 'mt');
      expect(en.first.body, 'Hello world.');
      expect(en.last.body, 'How are you?');
    });

    test('running it twice leaves one clean set of rows (idempotent replace)',
        () async {
      await writeTranscript(db: db, workId: workId, result: transcriptResult());
      await writeTranscript(db: db, workId: workId, result: transcriptResult());

      expect(await db.spineDao.segmentsOf(workId), hasLength(2));
      expect(await db.spineDao.alignmentsOf(workId), hasLength(2));
      expect(await db.spineDao.layersOf(workId, lang: 'pt'), hasLength(2));
    });

    test('json blob content survives the drift blob column', () async {
      await writeTranscript(db: db, workId: workId, result: transcriptResult());
      final alignment = (await db.spineDao.alignmentsOf(workId)).first;
      final decoded =
          jsonDecode(utf8.decode(alignment.wordTimings!)) as List<dynamic>;
      expect(decoded, hasLength(2));
    });
  });
}
