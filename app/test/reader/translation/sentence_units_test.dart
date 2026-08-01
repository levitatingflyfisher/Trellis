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

  group('Campaign 8 "Babel widens" Phase 2: long-form endurance', () {
    // An episode is hundreds of sentences, not the handful every other
    // test in this file uses. This proves the SAME two functions the
    // reader's speak loop calls per-sentence (sentenceUnitsOf once up
    // front, translatedTextFor on every unit) hold their contract at that
    // scale: correct count, the fallback law honored for every single
    // unit (not sampled), and fast — a pure-Dart proof over the unit-list
    // construction itself, not a `testWidgets` drive through hundreds of
    // simulated pumps (which would mostly measure the test harness, not
    // the reader). Background/lock-screen playback (audio_service) is a
    // recorded dependency gap, not built here — see the ADR.
    const segmentCount = 600; // ~1200 sentences at 2/segment: a long episode
    late List<core.Segment> segments;

    setUp(() {
      segments = [
        for (var i = 0; i < segmentCount; i++)
          core.Segment(
              idx: i,
              kind: core.SegmentKind.prose,
              text: 'Sentence $i part one. Sentence $i part two.'),
      ];
    });

    test('sentenceUnitsOf produces exactly two units per segment, correctly '
        'numbered, across the whole episode', () {
      final sw = Stopwatch()..start();
      final units = sentenceUnitsOf(segments);
      sw.stop();

      expect(units, hasLength(segmentCount * 2));
      for (var i = 0; i < segmentCount; i++) {
        expect(units[i * 2].segIdx, i);
        expect(units[i * 2].sentenceIdx, 0);
        expect(units[i * 2].text, 'Sentence $i part one.');
        expect(units[i * 2 + 1].segIdx, i);
        expect(units[i * 2 + 1].sentenceIdx, 1);
        expect(units[i * 2 + 1].text, 'Sentence $i part two.');
      }
      expect(sw.elapsedMilliseconds, lessThan(5000),
          reason: 'an episode-sized document must not stall the reader '
              'opening it');
    });

    test('the per-sentence fallback law holds for EVERY unit at scale — a '
        'resumable batch that only got partway through a long episode '
        'must never stall the speak queue on what it has not reached '
        'yet', () {
      final units = sentenceUnitsOf(segments);
      // Simulates a batch that was cancelled/paused partway: only every
      // third sentence got translated before the run stopped — the
      // realistic mid-episode shape, not "all or nothing".
      final stored = <(int, int), TranslationSentence>{
        for (var i = 0; i < units.length; i += 3)
          (units[i].segIdx, units[i].sentenceIdx): TranslationSentence(
              workId: 1,
              segmentIdx: units[i].segIdx,
              sentenceIdx: units[i].sentenceIdx,
              lang: 'es',
              sourceText: units[i].text,
              body: 'ES: ${units[i].text}'),
      };

      final sw = Stopwatch()..start();
      var translatedCount = 0;
      var fallbackCount = 0;
      for (var i = 0; i < units.length; i++) {
        final u = units[i];
        final t = translatedTextFor(
            stored: stored,
            segIdx: u.segIdx,
            sentenceIdx: u.sentenceIdx,
            currentSourceText: u.text);
        if (i % 3 == 0) {
          expect(t, 'ES: ${u.text}',
              reason: 'unit $i was translated in the simulated batch');
          translatedCount++;
        } else {
          expect(t, isNull,
              reason: 'unit $i was never reached by the simulated batch '
                  '— it must fall back to English, not throw or stall');
          fallbackCount++;
        }
      }
      sw.stop();

      expect(translatedCount, stored.length);
      expect(fallbackCount, units.length - stored.length);
      expect(sw.elapsedMilliseconds, lessThan(5000),
          reason: 'the per-sentence lookup the speak loop makes once per '
              'sentence must not degrade across an episode-length run');
    });

    test('a stale re-ingest partway through a long episode falls back '
        'sentence-by-sentence, not episode-wide — the staleness law '
        'scoped correctly at scale', () {
      final units = sentenceUnitsOf(segments);
      final stored = <(int, int), TranslationSentence>{
        for (final u in units)
          (u.segIdx, u.sentenceIdx): TranslationSentence(
              workId: 1,
              segmentIdx: u.segIdx,
              sentenceIdx: u.sentenceIdx,
              lang: 'es',
              sourceText: u.text,
              body: 'ES: ${u.text}'),
      };
      // Re-ingest reshapes exactly ONE sentence deep into the episode —
      // its stored row is now stale; every other row must be unaffected.
      final reshapedIdx = segmentCount ~/ 2;
      final reshapedUnit = units[reshapedIdx * 2];

      for (var i = 0; i < units.length; i++) {
        final u = units[i];
        final currentText =
            i == reshapedIdx * 2 ? 'A reshaped sentence entirely.' : u.text;
        final t = translatedTextFor(
            stored: stored,
            segIdx: u.segIdx,
            sentenceIdx: u.sentenceIdx,
            currentSourceText: currentText);
        if (i == reshapedIdx * 2) {
          expect(t, isNull,
              reason: 'the reshaped sentence at segIdx '
                  '${reshapedUnit.segIdx} reads as stale, not mismatched');
        } else {
          expect(t, 'ES: ${u.text}',
              reason: 'unit $i, untouched by the reshape, keeps its '
                  'translation — one stale sentence never invalidates the '
                  'whole episode');
        }
      }
    });
  });
}
