/// Port of ohPrimer rebuild/test/tokenizer.test.mjs (19 donor asserts).
///
/// The donor JS (rebuild/src/scripts/15-tokenizer.js) is the spec; every
/// donor `ok`/`eq` maps to exactly one expect below, in donor order. The
/// donor's Document {blocks} input becomes a List of spine Segments:
/// text→prose, chapter→heading, segment(kind)→code/table/figure.
import 'package:loom_core/loom_core.dart';
import 'package:test/test.dart';

Segment _prose(int idx, String text) =>
    Segment(idx: idx, kind: SegmentKind.prose, text: text);

void main() {
  group('tokenizer: text block', () {
    final st = tokenizeDocument([_prose(0, 'The quick brown fox.')]);

    test('splits words', () {
      expect(st.words, ['The', 'quick', 'brown', 'fox.']);
    });
    test('originals parallel to words', () {
      expect(st.originals.length, st.words.length);
    });
    test('pacing parallel to words', () {
      expect(st.pacing.length, st.words.length);
    });
    test('paragraph-end word gets a longer pause', () {
      expect(st.pacing[3], greaterThanOrEqualTo(1.5));
    });
  });

  group('tokenizer: chapters + blockStartWordIdx', () {
    final st = tokenizeDocument([
      const Segment(idx: 0, kind: SegmentKind.heading, text: 'One'),
      _prose(1, 'alpha beta'),
    ]);

    test('chapter recorded at word index', () {
      expect(st.chapters, hasLength(1));
      expect(st.chapters.single.idx, 0);
      expect(st.chapters.single.title, 'One');
    });
    test('block start indices track word count', () {
      expect(st.blockStartWordIdx, [0, 0]);
    });
    test('chapter emits no word', () {
      expect(st.words, ['alpha', 'beta']);
    });
  });

  group('tokenizer: segment sentinel', () {
    final st = tokenizeDocument(
        [const Segment(idx: 0, kind: SegmentKind.figure, text: 'x')]);

    test('segment emits a sentinel token', () {
      expect(st.words, ['[figure]']);
    });
    test('segment recorded in map', () {
      expect(st.segments[0]?.kind, SegmentKind.figure);
    });
  });

  group('tokenizer: URL abbreviation + long-token skip', () {
    final url = tokenizeDocument(
        [_prose(0, 'see https://www.example.com/a/b/c now')]);
    final long = tokenizeDocument([_prose(0, 'x${'y' * 40}')]);

    test('abbreviates URL', () {
      expect(url.words[1], 'example.com/…/c');
    });
    test('keeps original URL', () {
      expect(url.originals[1], 'https://www.example.com/a/b/c');
    });
    test('over-long token becomes ellipsis', () {
      expect(long.words, ['…']);
    });
    test('skipped counter increments', () {
      expect(long.skipped, 1);
    });
  });

  group('tokenizer: hyphenated compound split', () {
    final st = tokenizeDocument([_prose(0, 'mother-in-law')]);

    test('splits hyphenated compound', () {
      expect(st.words, ['mother', 'in', 'law']);
    });
    test('inter-part pacing tightened', () {
      expect(st.pacing[0], 0.8);
      expect(st.pacing[1], 0.8);
    });
  });

  group('tokenizer: punctuation delays', () {
    test('sentence end 1.7', () {
      expect(getPunctuationDelay('end.'), 1.7);
    });
    test('comma 1.0', () {
      expect(getPunctuationDelay('clause,'), 1.0);
    });
    test('semicolon 1.2', () {
      expect(getPunctuationDelay('semi;'), 1.2);
    });
  });

  group('tokenizer: KNOWN LIMITATION M8 (space-less CJK)', () {
    // Documents current (donor-faithful, buggy) behavior: a long space-less
    // run collapses to "…". When M8 is fixed (grapheme-aware splitting),
    // update this assertion.
    test('M8: long CJK run is currently skipped (regression marker)', () {
      final st = tokenizeDocument([_prose(0, '想' * 40)]);
      expect(st.words, ['…']);
    });
  });
}
