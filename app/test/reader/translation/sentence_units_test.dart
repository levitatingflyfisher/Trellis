import 'package:flutter_test/flutter_test.dart';
import 'package:loom_core/loom_core.dart' as core;
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/translation/sentence_units.dart';

/// sentenceUnitsOf: the canonical (segIdx, sentenceIdx) numbering the
/// translation batch job and the reader's display/speech substitution both
/// key off (ADR-0008 "Babel" Phase 3) — and translatedTextFor: the ONE
/// lookup both call sites use, enforcing the sourceText staleness law the
/// store's own docstring promises.
void main() {
  group('sentenceUnitsOf', () {
    test('splits a prose segment into its sentences, numbered from 0',
        () {
      final segments = [
        const core.Segment(
            idx: 0,
            kind: core.SegmentKind.prose,
            text: 'Hello there. How are you?'),
      ];
      final units = sentenceUnitsOf(segments);
      expect(units, hasLength(2));
      expect(units[0].segIdx, 0);
      expect(units[0].sentenceIdx, 0);
      expect(units[0].text, 'Hello there.');
      expect(units[1].segIdx, 0);
      expect(units[1].sentenceIdx, 1);
      expect(units[1].text, 'How are you?');
    });

    test('keys by the segment\'s own idx, never its position in the list',
        () {
      // A work whose segments start at a non-zero idx (a deletion, a
      // partial ingest) — the numbering law must key off Segment.idx, not
      // "which position in this list", or the store would mis-key every
      // sentence in a work like this.
      final segments = [
        const core.Segment(idx: 5, kind: core.SegmentKind.prose, text: 'Five.'),
        const core.Segment(idx: 6, kind: core.SegmentKind.prose, text: 'Six.'),
        const core.Segment(idx: 7, kind: core.SegmentKind.prose, text: 'Seven.'),
      ];
      final units = sentenceUnitsOf(segments);
      expect(units.map((u) => u.segIdx), [5, 6, 7]);
      expect(units.map((u) => u.sentenceIdx), [0, 0, 0]);
    });

    test('headings are included, the same speakable filter speech uses',
        () {
      final segments = [
        const core.Segment(
            idx: 0, kind: core.SegmentKind.heading, text: 'Chapter One'),
      ];
      final units = sentenceUnitsOf(segments);
      expect(units, hasLength(1));
      expect(units.single.text, 'Chapter One');
    });

    test('code, table, and figure segments are never translatable units',
        () {
      final segments = [
        const core.Segment(
            idx: 0, kind: core.SegmentKind.code, text: 'print("hi")'),
        const core.Segment(idx: 1, kind: core.SegmentKind.table, text: 'a|b'),
        const core.Segment(
            idx: 2, kind: core.SegmentKind.figure, text: 'A chart.'),
      ];
      expect(sentenceUnitsOf(segments), isEmpty);
    });

    test('a blank segment contributes nothing', () {
      final segments = [
        const core.Segment(idx: 0, kind: core.SegmentKind.prose, text: '   '),
      ];
      expect(sentenceUnitsOf(segments), isEmpty);
    });

    test('sentenceIdx is the RAW splitSentences index — a run of blank '
        'sentences never renumbers what follows', () {
      // Two consecutive terminators can yield an empty sentence between
      // them; whatever loom_core's splitter does with it, this function's
      // numbering must track the SAME list position splitSentences itself
      // assigns, so a stored row's index can never point at a different
      // sentence than the one that produced it.
      final direct = core.splitSentences('One. Two. Three.');
      final segments = [
        const core.Segment(
            idx: 9, kind: core.SegmentKind.prose, text: 'One. Two. Three.'),
      ];
      final units = sentenceUnitsOf(segments);
      expect(units.map((u) => u.sentenceIdx),
          List.generate(direct.length, (i) => i));
    });
  });

  group('translatedTextFor', () {
    TranslationSentence row({required String sourceText, required String body}) =>
        TranslationSentence(
            workId: 1,
            segmentIdx: 0,
            sentenceIdx: 0,
            lang: 'es',
            sourceText: sourceText,
            body: body);

    test('returns the stored body when sourceText matches the current '
        'sentence', () {
      final stored = {(0, 0): row(sourceText: 'Hello.', body: 'Hola.')};
      expect(
          translatedTextFor(
              stored: stored,
              segIdx: 0,
              sentenceIdx: 0,
              currentSourceText: 'Hello.'),
          'Hola.');
    });

    test('no stored row means no translation', () {
      expect(
          translatedTextFor(
              stored: const {},
              segIdx: 0,
              sentenceIdx: 0,
              currentSourceText: 'Hello.'),
          isNull);
    });

    test('a stale row (sourceText no longer matches) reads as missing — the '
        'fallback-to-English law, not a mismatched translation', () {
      final stored = {(0, 0): row(sourceText: 'Hello.', body: 'Hola.')};
      expect(
          translatedTextFor(
              stored: stored,
              segIdx: 0,
              sentenceIdx: 0,
              currentSourceText: 'Hello there.'),
          isNull);
    });

    test('a different (segIdx, sentenceIdx) key is not found', () {
      final stored = {(0, 0): row(sourceText: 'Hello.', body: 'Hola.')};
      expect(
          translatedTextFor(
              stored: stored,
              segIdx: 0,
              sentenceIdx: 1,
              currentSourceText: 'Hello.'),
          isNull);
    });
  });
}
