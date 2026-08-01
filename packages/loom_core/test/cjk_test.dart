import 'package:loom_core/loom_core.dart';
import 'package:test/test.dart';

/// The CJK segmentation baseline (Campaign 8 "Babel widens" Phase 3): the
/// character-level default UAX #29 already specifies for Han ideographs
/// and Hiragana absent a dictionary, plus the WB13 Katakana-run join —
/// this is the honest floor, not a full dictionary segmenter (that ceiling
/// — real Japanese grammatical words — is recorded, not shipped here; see
/// docs/reference/mt-models.md).
void main() {
  group('isHanIdeograph / isHiragana / isKatakana / containsCjk', () {
    test('classifies one character from each script correctly', () {
      expect(isHanIdeograph('日'.runes.first), isTrue);
      expect(isHanIdeograph('a'.runes.first), isFalse);
      expect(isHiragana('あ'.runes.first), isTrue);
      expect(isHiragana('日'.runes.first), isFalse);
      expect(isKatakana('ア'.runes.first), isTrue);
      expect(isKatakana('あ'.runes.first), isFalse);
    });

    test('containsCjk is true for any CJK codepoint anywhere in the '
        'string, false for plain ASCII', () {
      expect(containsCjk('日本語'), isTrue);
      expect(containsCjk('iPhone15日本語版'), isTrue);
      expect(containsCjk('Hello, world!'), isFalse);
      expect(containsCjk(''), isFalse);
    });
  });

  group('segmentCjkRun — Chinese (Han only)', () {
    test('one Han ideograph becomes one unit each — the honest '
        'no-dictionary default', () {
      expect(segmentCjkRun('你好'), ['你', '好']);
    });

    test('a full stop attaches to the preceding unit, not its own token',
        () {
      expect(segmentCjkRun('你好。'), ['你', '好。']);
    });

    test('multiple sentences in one run: each terminator closes its own '
        'preceding unit', () {
      expect(segmentCjkRun('你好。再见。'), ['你', '好。', '再', '见。']);
    });

    test('the ideographic comma attaches the same way as the full stop',
        () {
      expect(segmentCjkRun('你好，世界'), ['你', '好，', '世', '界']);
    });
  });

  group('segmentCjkRun — Japanese (mixed Han/Hiragana/Katakana)', () {
    test('a maximal Katakana run stays one unit (UAX #29 WB13)', () {
      expect(segmentCjkRun('アメリカ'), ['アメリカ']);
    });

    test('Hiragana is one character per unit — the documented ceiling '
        '(a real grammatical word like 食べる splits into 食/べ/る here; '
        'TinySegmenter or a dictionary is the honest fix, not shipped)',
        () {
      expect(segmentCjkRun('食べる'), ['食', 'べ', 'る']);
    });

    test('Han, Hiragana and Katakana runs each segment by their own rule '
        'within one mixed string', () {
      expect(segmentCjkRun('私はアメリカに行く'),
          ['私', 'は', 'アメリカ', 'に', '行', 'く']);
    });

    test('a fullwidth question mark attaches to the preceding unit', () {
      expect(segmentCjkRun('元気？'), ['元', '気？']);
    });
  });

  group('segmentCjkRun — mixed-script runs', () {
    test('an embedded Latin/digit run (e.g. a product name) groups into '
        'one unit, the same maximal-token shape whitespace tokenizing '
        'already gives plain Latin text', () {
      expect(segmentCjkRun('iPhone15発売'), ['iPhone15', '発', '売']);
    });

    test('leading punctuation with nothing before it in this run becomes '
        'its own unit rather than being silently dropped', () {
      expect(segmentCjkRun('。你好'), ['。', '你', '好']);
    });

    test('an empty run produces no units', () {
      expect(segmentCjkRun(''), isEmpty);
    });
  });
}
