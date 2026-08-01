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

  group('tokenizer: M8 FIXED (Campaign 8 "Babel widens" Phase 3) — '
      'space-less CJK now segments per the UAX #29 baseline instead of '
      'collapsing to a single "…" placeholder', () {
    test('a long CJK run no longer collapses — each Han ideograph is its '
        'own word, so a 40-character run produces 40 words, never the '
        'maxTokenChars skip', () {
      final st = tokenizeDocument([_prose(0, '想' * 40)]);
      expect(st.words, List.filled(40, '想'));
      expect(st.skipped, 0);
    });

    test('a real Chinese sentence tokenizes character-by-character, '
        'terminal punctuation folded onto the last character', () {
      final st = tokenizeDocument([_prose(0, '你好，世界。')]);
      expect(st.words, ['你', '好，', '世', '界。']);
    });

    test('a real Japanese sentence keeps its Katakana run whole and '
        'gives Hiragana one word per character (the documented ceiling)',
        () {
      final st = tokenizeDocument([_prose(0, '私はアメリカに行く。')]);
      expect(st.words, ['私', 'は', 'アメリカ', 'に', '行', 'く。']);
    });

    test('CJK terminal punctuation carries the same 1.7 sentence-end '
        'pacing weight ASCII .!? does', () {
      final st = tokenizeDocument([_prose(0, '你好。')]);
      expect(st.pacing.last, 1.7);
    });

    test('CJK text mixed with plain ASCII in the same document tokenizes '
        'each block by its own script, undisturbed by the other', () {
      final st = tokenizeDocument(
          [_prose(0, 'Hello there.'), _prose(1, '你好。')]);
      expect(st.words, ['Hello', 'there.', '你', '好。']);
    });

    test('a mixed-script token (a product name inside CJK prose) keeps '
        'its Latin/digit run whole', () {
      final st = tokenizeDocument([_prose(0, 'iPhone15発売。')]);
      expect(st.words, ['iPhone15', '発', '売。']);
    });
  });
}
