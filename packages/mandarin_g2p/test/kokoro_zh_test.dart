import 'package:mandarin_g2p/mandarin_g2p.dart';
import 'package:test/test.dart';

void main() {
  group('vocabulary and ids', () {
    test('holds the 171 symbols of the v1.1-zh config, no pad', () {
      expect(kokoroZhVocab.length, 171);
      expect(kokoroZhVocab.values.contains(0), isFalse);
      expect(kokoroZhVocab['ㄓ'], 23);
      expect(kokoroZhVocab['云'], 176);
      expect(kokoroZhVocab['̃'], 17);
    });
    test('pads both ends and drops what the vocabulary lacks', () {
      // misaki's 一天 (a golden line).
      expect(kokoroZhIds('ㄧ4ㄊ言1'), [0, 127, 173, 49, 146, 171, 0]);
      final t = KokoroZhTokens('❓ ㄋㄧ2');
      expect(t.inputIds, [0, 16, 73, 127, 172, 0]);
      expect(t.lenPs, 5, reason: 'len(ps) counts the unknown mark');
      expect(t.styleRow, 4);
    });
  });

  test('speed follows make_zh.py exactly, times 1.1', () {
    // Python's own values of speed_callable.
    expect(kokoroZhSpeed(1), 1.1);
    expect(kokoroZhSpeed(83), 1.1);
    expect(kokoroZhSpeed(84), 1.0978);
    expect(kokoroZhSpeed(133), 0.9900000000000001);
    expect(kokoroZhSpeed(182), 0.8822000000000001);
    expect(kokoroZhSpeed(183), 0.8800000000000001);
    expect(kokoroZhSpeed(400), 0.8800000000000001);
  });

  test('style row is len(ps) - 1', () {
    expect(styleRowFor(1), 0);
    expect(styleRowFor(510), 509);
  });

  group('splitting over 510 phonemes', () {
    String run(int n) => List.filled(n, 'ㄚ').join();

    test('leaves a short string whole', () {
      expect(splitKokoroPhonemes('ㄋㄧ2ㄏㄠ3.'), ['ㄋㄧ2ㄏㄠ3.']);
    });
    test('cuts after the last sentence mark first', () {
      final ps = '${run(100)}, ${run(100)}. ${run(200)}, ${run(200)}';
      final parts = splitKokoroPhonemes(ps);
      expect(parts, ['${run(100)}, ${run(100)}.', '${run(200)}, ${run(200)}']);
    });
    test('then a colon or semicolon, then a comma', () {
      final ps = '${run(300)}, ${run(100)}; ${run(300)}';
      expect(splitKokoroPhonemes(ps), ['${run(300)}, ${run(100)};', run(300)]);
      final ps2 = '${run(300)}, ${run(300)}';
      expect(splitKokoroPhonemes(ps2), ['${run(300)},', run(300)]);
    });
    test('keeps a closing quote with its sentence', () {
      final ps = '“${run(300)}!” ${run(300)}';
      expect(splitKokoroPhonemes(ps), ['“${run(300)}!”', run(300)]);
    });
    test('with no mark, cuts at a word break and drops it', () {
      final ps = '${run(400)}/${run(300)}';
      expect(splitKokoroPhonemes(ps), [run(400), run(300)]);
    });
    test('with nothing at all, cuts at 510', () {
      final parts = splitKokoroPhonemes(run(1200));
      expect(parts.map((p) => p.length), [510, 510, 180]);
    });
    test('every piece fits', () {
      final ps = List.filled(40, '${run(30)}/${run(20)}, ').join();
      final parts = splitKokoroPhonemes(ps);
      expect(parts.length, greaterThan(1));
      for (final p in parts) {
        expect(p.runes.length, lessThanOrEqualTo(510));
      }
    });
  });
}
