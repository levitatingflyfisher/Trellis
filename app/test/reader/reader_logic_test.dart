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
}
