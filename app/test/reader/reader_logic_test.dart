import 'package:flutter_test/flutter_test.dart';
import 'package:loom_core/loom_core.dart';
import 'package:trellis/features/reader/reader_logic.dart';

/// The reader's pure projections: the donor ORP pivot heuristic
/// (ohPrimer getORP), the cursor law's word↔(segmentIdx, wordIdx) mapping
/// (ADR-0002), and punctuation dwell.
void main() {
  group('orpIndex (donor getORP: n<=1?0 : n<=5?1 : n<=9?2 : 3)', () {
    test('empty and single-char words pivot at 0', () {
      expect(orpIndex(''), 0);
      expect(orpIndex('a'), 0);
    });
    test('short words (2..5) pivot at 1', () {
      expect(orpIndex('to'), 1);
      expect(orpIndex('hello'), 1);
    });
    test('medium words (6..9) pivot at 2', () {
      expect(orpIndex('bridge'), 2);
      expect(orpIndex('wonderful'), 2);
    });
    test('long words (10+) pivot at 3', () {
      expect(orpIndex('strawberry'), 3);
      expect(orpIndex('extraordinarily'), 3);
    });
  });

  group('cursor law mapping', () {
    // heading (no word) · prose (3 words) · code sentinel (1 word) · prose (2)
    final blocks = [
      const Segment(idx: 0, kind: SegmentKind.heading, text: 'Chapter I'),
      const Segment(idx: 1, kind: SegmentKind.prose, text: 'One two three.'),
      const Segment(idx: 2, kind: SegmentKind.code, text: 'x = 1'),
      const Segment(idx: 3, kind: SegmentKind.prose, text: 'Four five'),
    ];
    final doc = tokenizeDocument(blocks);

    test('the tokenizer fixture is what this group assumes', () {
      expect(doc.words, ['One', 'two', 'three.', '[code]', 'Four', 'five']);
      expect(doc.blockStartWordIdx, [0, 0, 3, 4]);
    });

    test('a word maps to the block that owns it, never a heading', () {
      expect(cursorAt(doc, 0), (segment: 1, word: 0));
      expect(cursorAt(doc, 2), (segment: 1, word: 2));
      expect(cursorAt(doc, 3), (segment: 2, word: 0));
      expect(cursorAt(doc, 5), (segment: 3, word: 1));
    });

    test('cursorAt clamps out-of-range global indices', () {
      expect(cursorAt(doc, -5), (segment: 1, word: 0));
      expect(cursorAt(doc, 99), (segment: 3, word: 1));
    });

    test('globalWordIndex is the inverse of cursorAt', () {
      for (var w = 0; w < doc.words.length; w++) {
        final c = cursorAt(doc, w);
        expect(globalWordIndex(doc, c.segment, c.word), w);
      }
    });

    test('globalWordIndex clamps a stale wordIdx inside its segment', () {
      expect(globalWordIndex(doc, 1, 99), 2, reason: 'last word of block 1');
      expect(globalWordIndex(doc, 3, 99), 5);
    });

    test('a position pointing at a word-less heading falls forward', () {
      expect(globalWordIndex(doc, 0, 0), 0);
    });
  });

  group('punctuation dwell (donor: ms = 60000/wpm * pacing)', () {
    test('base word at 300 wpm is 200ms', () {
      expect(msPerWord(300, 1.0), 200);
    });
    test('sentence end dwells 1.7x', () {
      expect(msPerWord(300, 1.7), 340);
    });
    test('faster wpm shrinks the dwell proportionally', () {
      expect(msPerWord(600, 1.2), 120);
    });
  });

  group('gaussianOpacity (donor gauss(d,s) = exp(-(d*d)/(2*s*s)), sigma 2.0)',
      () {
    test('distance 0 is full strength', () {
      expect(gaussianOpacity(0, 2.0), closeTo(1.0, 1e-9));
    });
    test('matches the donor curve at distance 2 == sigma', () {
      // exp(-(4)/(8)) = exp(-0.5)
      expect(gaussianOpacity(2, 2.0), closeTo(0.6065306597, 1e-9));
    });
    test('never drops below the donor floor of 0.01', () {
      expect(gaussianOpacity(50, 2.0), 0.01);
    });
    test('distance is measured absolute — sign does not matter', () {
      expect(gaussianOpacity(-3, 2.0), gaussianOpacity(3, 2.0));
    });
  });

  group('gaussianScale (donor: 0.85 + 0.15*gauss(d,s))', () {
    test('distance 0 is full scale', () {
      expect(gaussianScale(0, 2.0), closeTo(1.0, 1e-9));
    });
    test('far neighbors settle toward the 0.85 floor', () {
      expect(gaussianScale(50, 2.0), closeTo(0.85, 1e-6));
    });
  });

  group('gaussianBlurRadius (donor: dist>sigma*1.5 ? min(2,(dist-sigma)*0.7) : 0)',
      () {
    test('inside the 1.5*sigma threshold there is no blur', () {
      expect(gaussianBlurRadius(2, 2.0), 0.0);
      expect(gaussianBlurRadius(3, 2.0), 0.0); // exactly sigma*1.5, not >
    });
    test('just past the threshold blurs a little', () {
      // dist=4, sigma=2: (4-2)*0.7 = 1.4
      expect(gaussianBlurRadius(4, 2.0), closeTo(1.4, 1e-9));
    });
    test('caps at 2px even for very distant neighbors', () {
      expect(gaussianBlurRadius(50, 2.0), 2.0);
    });
  });

  group('orpBeforeReserve (donor: min-width = charWidth * orp, cw = fontSize*0.6)',
      () {
    test('orp-0 words (n<=1) reserve nothing', () {
      expect(orpBeforeReserve('a', 20), 0);
    });
    test('reserve scales with the char-width estimate and the orp bucket',
        () {
      // 'hello' -> orp 1, charWidth 20 -> reserve 20
      expect(orpBeforeReserve('hello', 20), 20);
      // 'wonderful' -> orp 2, charWidth 20 -> reserve 40
      expect(orpBeforeReserve('wonderful', 20), 40);
      // 'extraordinarily' -> orp 3, charWidth 20 -> reserve 60
      expect(orpBeforeReserve('extraordinarily', 20), 60);
    });
  });

  group('shouldOfferRecap (Campaign 4 Phase 4: >3 UTC days untouched, '
      '>10% progress, not finished)', () {
    test('a work never opened offers nothing — no position to gap from', () {
      expect(
          shouldOfferRecap(
              lastTouchedEpochDay: null, todayEpochDay: 200, progress: 0.5),
          isFalse);
    });
    test('exactly 3 days untouched does not offer yet — the gap must '
        'exceed 3, not just reach it', () {
      expect(
          shouldOfferRecap(
              lastTouchedEpochDay: 197, todayEpochDay: 200, progress: 0.5),
          isFalse);
    });
    test('more than 3 days untouched with real progress offers', () {
      expect(
          shouldOfferRecap(
              lastTouchedEpochDay: 196, todayEpochDay: 200, progress: 0.5),
          isTrue);
    });
    test('barely-started progress (<=10%) offers nothing — nothing to '
        'catch up on yet', () {
      expect(
          shouldOfferRecap(
              lastTouchedEpochDay: 100, todayEpochDay: 200, progress: 0.10),
          isFalse);
    });
    test('a finished work offers nothing — there is no "so far" left to '
        'recap', () {
      expect(
          shouldOfferRecap(
              lastTouchedEpochDay: 100, todayEpochDay: 200, progress: 1.0),
          isFalse);
    });
  });

  group('preCursorText (Campaign 4 Phase 4\'s privacy law: never assemble '
      'text at or after the reading cursor)', () {
    test('only segments strictly before currentSegmentIdx are joined', () {
      final rows = [
        (idx: 0, body: 'Chapter one begins.'),
        (idx: 1, body: 'Something happens next.'),
        (idx: 2, body: 'A twist nobody saw coming.'),
        (idx: 3, body: 'The reader has not reached this yet.'),
      ];
      final text = preCursorText(rows, 2);
      expect(text, 'Chapter one begins.\n\nSomething happens next.');
      expect(text, isNot(contains('twist')));
      expect(text, isNot(contains('not reached')));
    });
    test('blank segments (headings with no body) are skipped, not joined '
        'as empty lines', () {
      final rows = [
        (idx: 0, body: 'Chapter One'),
        (idx: 1, body: ''),
        (idx: 2, body: 'The real text.'),
      ];
      expect(preCursorText(rows, 3), 'Chapter One\n\nThe real text.');
    });
    test('a cursor at the very first segment assembles nothing — there is '
        'no "so far" yet', () {
      final rows = [(idx: 0, body: 'Chapter one begins.')];
      expect(preCursorText(rows, 0), '');
    });
  });
}
