/// Sentence-boundary segmentation for read-aloud pacing (the neural-TTS
/// campaign): sentences are the unit of speech, so the reader's speak loop
/// can tick per sentence instead of per whole block/paragraph.
import 'package:loom_core/loom_core.dart';
import 'package:test/test.dart';

Segment _prose(String text) => Segment(idx: 0, kind: SegmentKind.prose, text: text);

void main() {
  group('splitSentences: boundaries', () {
    test('splits on terminal punctuation', () {
      final s = splitSentences('The cat sat. The dog ran!');
      expect(s.map((x) => x.text).toList(), ['The cat sat.', 'The dog ran!']);
    });

    test('question and exclamation both end a sentence', () {
      final s = splitSentences('Really? Yes!');
      expect(s.map((x) => x.text).toList(), ['Really?', 'Yes!']);
    });

    test('a lone sentence with no terminal punctuation is still one sentence',
        () {
      final s = splitSentences('Just started');
      expect(s, hasLength(1));
      expect(s.single.text, 'Just started');
      expect(s.single.firstWordIdx, 0);
    });

    test('empty or whitespace-only text yields no sentences', () {
      expect(splitSentences(''), isEmpty);
      expect(splitSentences('   '), isEmpty);
    });

    test('an embedded quote with its own punctuation does not split the '
        'sentence — the safe failure mode is one long pause, not a clipped '
        'quote', () {
      final s = splitSentences('She said "stop!" and left.');
      expect(s, hasLength(1));
      expect(s.single.text, 'She said "stop!" and left.');
    });
  });

  group('splitSentences: modest abbreviation tolerance', () {
    test('a common title abbreviation does not end the sentence', () {
      final s = splitSentences('Dr. Smith arrived. He was late.');
      expect(s.map((x) => x.text).toList(),
          ['Dr. Smith arrived.', 'He was late.']);
    });

    test('a single-letter initial does not end the sentence', () {
      final s = splitSentences('J. K. Rowling wrote this. It sold well.');
      expect(s.map((x) => x.text).toList(),
          ['J. K. Rowling wrote this.', 'It sold well.']);
    });

    test('KNOWN LIMITATION: an un-listed abbreviation still splits '
        '(modest tolerance, not exhaustive — regression marker)', () {
      final s = splitSentences('It arrived Tues. morning.');
      expect(s.map((x) => x.text).toList(),
          ['It arrived Tues.', 'morning.']);
    });
  });

  group('splitSentences: firstWordIdx anchors the cursor law (ADR-0002)', () {
    test('the first sentence always starts at word 0', () {
      final s = splitSentences('The cat sat. The dog ran.');
      expect(s[0].firstWordIdx, 0);
    });

    test('the second sentence starts at the real word count of the first',
        () {
      final s = splitSentences('The cat sat. The dog ran.');
      expect(s[1].firstWordIdx, 3); // The, cat, sat.
    });

    // The discriminating case: a naive whitespace-token count would put
    // "It" at raw-token index 6 (Visit / URL / for / the / well-known /
    // archive.) — one short, because the tokenizer's own hyphen-split turns
    // "well-known" into TWO display words. A wrong index here is not a
    // stylistic quibble; it is a wrong PERSISTED cursor (savePosition
    // writes segmentIdx+wordIdx straight from this number), so firstWordIdx
    // must come from the same authority `globalWordIndex`/`cursorAt` trust
    // — tokenizeDocument itself — never a re-derived word count.
    test(
        'firstWordIdx matches tokenizeDocument exactly across a hyphenated '
        'compound and a URL, where a naive whitespace count would drift',
        () {
      const text = 'Visit https://example.com/a/b/c for the well-known '
          'archive. It updates nightly.';
      final sentences = splitSentences(text);
      final whole = tokenizeDocument([_prose(text)]);
      expect(sentences, hasLength(2));
      expect(sentences[0].firstWordIdx, 0);
      final itIdx = whole.words.indexOf('It');
      expect(itIdx, 7, reason: 'sanity: the hyphen split really does shift '
          'the real tokenizer index');
      expect(sentences[1].firstWordIdx, itIdx);
    });

    test('firstWordIdx composes with globalWordIndex the same way a '
        'Position.wordIdx does', () {
      final block = _prose('One two three. Four five.');
      final doc = tokenizeDocument([block]);
      final sentences = splitSentences(block.text);
      // Sentence 1 ("Four five.") should land on its own first word via
      // the SAME machinery cursorAt/globalWordIndex already use.
      final idx = sentences[1].firstWordIdx;
      expect(doc.words[idx], 'Four');
    });
  });

  group('splitSentences: CJK terminators (Campaign 8 "Babel widens" Phase '
      '3) — a real gap, not hypothetical: without this, a whole CJK '
      'paragraph would speak as ONE long utterance, exactly the '
      '"long-utterance stall" ADR-0006 built this splitter to fix', () {
    test('the ideographic full stop ends a sentence with no trailing '
        'whitespace required — CJK prose has none between sentences', () {
      final s = splitSentences('你好。再见。');
      expect(s.map((x) => x.text).toList(), ['你好。', '再见。']);
    });

    test('fullwidth exclamation and question marks also end a sentence',
        () {
      final s = splitSentences('今日は！天気がいいですね？');
      expect(s.map((x) => x.text).toList(),
          ['今日は！', '天気がいいですね？']);
    });

    test('a ONE-CHARACTER sentence before the terminator still splits — '
        'the ASCII single-letter-initial heuristic ("J.") must not '
        'misfire on CJK, where a one-character clause is an ordinary '
        'short sentence, never an abbreviation', () {
      final s = splitSentences('好。坏。');
      expect(s.map((x) => x.text).toList(), ['好。', '坏。']);
    });

    test('CJK and ASCII sentences in the same text both split correctly '
        '— the CJK rule does not disturb the ASCII one', () {
      final s = splitSentences('Hello. 你好。');
      expect(s.map((x) => x.text).toList(), ['Hello.', '你好。']);
    });

    test('an ASCII decimal point is unaffected by the CJK addition '
        '(regression: still one sentence, no trailing-whitespace boundary '
        'inside the number)', () {
      final s = splitSentences('It costs \$3.50 today.');
      expect(s, hasLength(1));
      expect(s.single.text, 'It costs \$3.50 today.');
    });

    test('firstWordIdx for a CJK sentence composes with the SAME '
        'tokenizeDocument authority the ASCII case uses', () {
      final block = _prose('你好。再见。');
      final doc = tokenizeDocument([block]);
      final sentences = splitSentences(block.text);
      expect(sentences, hasLength(2));
      expect(sentences[0].firstWordIdx, 0);
      final idx = sentences[1].firstWordIdx;
      expect(doc.words[idx], '再');
    });
  });
}
