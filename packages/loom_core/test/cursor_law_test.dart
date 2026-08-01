import 'package:test/test.dart';
import 'package:loom_core/loom_core.dart';

/// ADR-0002, the cursor law: a Position never references a modality or a
/// language. Renderers PROJECT it. These tests are the law's enforcement —
/// if a projection ever consults lastModality, or a format switch moves the
/// cursor, this file fails.
void main() {
  // A 3-segment bilingual work with audio alignment:
  //   seg 0: "Hola mundo."        [0ms – 2000ms]
  //   seg 1: "¿Cómo estás hoy?"   [2000ms – 5000ms]
  //   seg 2: "Adiós."             [5000ms – 6500ms]
  final segments = [
    const Segment(idx: 0, kind: SegmentKind.prose, text: 'Hola mundo.'),
    const Segment(idx: 1, kind: SegmentKind.prose, text: '¿Cómo estás hoy?'),
    const Segment(idx: 2, kind: SegmentKind.prose, text: 'Adiós.'),
  ];
  final layers = [
    const Layer(segmentIdx: 0, lang: 'es', kind: LayerKind.original, text: 'Hola mundo.'),
    const Layer(segmentIdx: 1, lang: 'es', kind: LayerKind.original, text: '¿Cómo estás hoy?'),
    const Layer(segmentIdx: 2, lang: 'es', kind: LayerKind.original, text: 'Adiós.'),
    const Layer(segmentIdx: 0, lang: 'en', kind: LayerKind.mt, text: 'Hello world.'),
    const Layer(segmentIdx: 1, lang: 'en', kind: LayerKind.mt, text: 'How are you today?'),
  ];
  final alignments = [
    const Alignment(segmentIdx: 0, tStartMs: 0, tEndMs: 2000),
    const Alignment(segmentIdx: 1, tStartMs: 2000, tEndMs: 5000),
    const Alignment(segmentIdx: 2, tStartMs: 5000, tEndMs: 6500),
  ];
  final spine = Spine(segments: segments, layers: layers, alignments: alignments);

  group('cursor law — position is modality-free', () {
    test('stopping the audio mid-sentence and opening the reader lands on the same segment', () {
      // Listening in the car: playback is at 3200ms (inside segment 1).
      final pos = spine.positionAtAudioTime(3200);
      expect(pos.segmentIdx, 1);

      // Opening the reader projects the SAME position — no data moves.
      final text = spine.projectText(pos);
      expect(text, '¿Cómo estás hoy?');
    });

    test('the same position projects into another language layer at the same segment', () {
      final pos = spine.positionAtAudioTime(3200);
      expect(spine.projectText(pos, lang: 'en'), 'How are you today?');
    });

    test('a language with no layer for the segment falls back to the original', () {
      final pos = spine.positionAtAudioTime(5600); // segment 2: no en layer
      expect(spine.projectText(pos, lang: 'en'), 'Adiós.');
    });

    test('switching back from reading to listening resumes at the segment start time', () {
      // She read ahead to segment 2, then hits play.
      const pos = Position(segmentIdx: 2, wordIdx: 0, lastModality: Modality.read);
      expect(spine.projectAudioTime(pos), 5000);
    });

    test('two positions differing ONLY in lastModality project identically', () {
      const a = Position(segmentIdx: 1, wordIdx: 2, lastModality: Modality.read);
      const b = Position(segmentIdx: 1, wordIdx: 2, lastModality: Modality.listen);
      expect(spine.projectText(a), spine.projectText(b));
      expect(spine.projectAudioTime(a), spine.projectAudioTime(b));
      expect(spine.projectText(a, lang: 'en'), spine.projectText(b, lang: 'en'));
    });

    test('audio time before the first alignment clamps to the first segment', () {
      expect(spine.positionAtAudioTime(-50).segmentIdx, 0);
    });

    test('audio time past the last alignment clamps to the last segment', () {
      expect(spine.positionAtAudioTime(99999).segmentIdx, 2);
    });

    test('a gap between alignments resolves to the preceding segment', () {
      // Real transcripts have silences; the cursor should not jump ahead
      // during one. Gap spine: [0-1000], [3000-4000].
      final gappy = Spine(
        segments: segments.sublist(0, 2),
        layers: const [],
        alignments: const [
          Alignment(segmentIdx: 0, tStartMs: 0, tEndMs: 1000),
          Alignment(segmentIdx: 1, tStartMs: 3000, tEndMs: 4000),
        ],
      );
      expect(gappy.positionAtAudioTime(2000).segmentIdx, 0);
    });

    test('a segment with no alignment projects the nearest preceding aligned start', () {
      // Segment 1 unaligned (e.g. a heading inserted between audio sentences):
      final partial = Spine(
        segments: segments,
        layers: const [],
        alignments: const [
          Alignment(segmentIdx: 0, tStartMs: 0, tEndMs: 2000),
          Alignment(segmentIdx: 2, tStartMs: 5000, tEndMs: 6500),
        ],
      );
      const pos = Position(segmentIdx: 1, wordIdx: 0, lastModality: Modality.read);
      expect(partial.projectAudioTime(pos), 0);
    });
  });

  group('the study crown — read<->listen handoff round-trips', () {
    // Phase 3's "Listen from here" / "Read from here" verbs are thin UI
    // wiring over positionAtAudioTime/projectAudioTime, which already exist
    // (this file proves them). The spec asks for a "position symmetry
    // property... round-trips within one word" — that claim does not hold
    // for THIS data model: Alignment is (segmentIdx, tStartMs, tEndMs), no
    // word-level timing, so positionAtAudioTime always returns wordIdx: 0
    // and projectAudioTime never reads wordIdx at all (see both bodies in
    // spine.dart). The honest, provable claim is: round-trips within one
    // SEGMENT — sentence-level is the alignment guarantee ADR-0002 already
    // states. wordIdx survives the round trip unchanged only because
    // projectAudioTime ignores it, not because it was honored.
    for (final startMs in [0, 1999, 2000, 3200, 4999, 5000, 6499]) {
      test(
          'listen($startMs) -> read -> listen lands back on the same segment '
          '(start time may move to the segment\'s own start — that IS the '
          'projection, not drift)', () {
        final firstStop = spine.positionAtAudioTime(startMs);
        final backToAudio = spine.projectAudioTime(firstStop);
        final secondStop = spine.positionAtAudioTime(backToAudio);
        expect(secondStop.segmentIdx, firstStop.segmentIdx);
      });
    }

    test('read -> listen -> read round-trips a reading Position\'s segment '
        'exactly (wordIdx is preserved too, since the reader supplies it '
        'and nothing on this path can overwrite it)', () {
      const reading =
          Position(segmentIdx: 1, wordIdx: 2, lastModality: Modality.read);
      final audioMs = spine.projectAudioTime(reading);
      final backToListen = spine.positionAtAudioTime(audioMs);
      expect(backToListen.segmentIdx, reading.segmentIdx);
      // The listen side is honestly wordIdx: 0 (see the group doc comment) —
      // the READER is what re-supplies wordIdx 2 on the way back, not this
      // projection. Assert what the pure function actually promises, not
      // more.
      expect(backToListen.wordIdx, 0);
    });
  });
}
