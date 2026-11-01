import 'package:russian_g2p/russian_g2p.dart';
import 'package:test/test.dart';

const a = '́';

void main() {
  group('one word with its stress marked', () {
    test('hard consonants and a stressed vowel', () {
      expect(wordPhonemes('ма${a}ма'), 'ˈmamə');
      expect(wordPhonemes('до${a}м'), 'ˈdom');
    });

    test('a soft consonant before е, ё, и, ю, я and ь', () {
      expect(wordPhonemes('не${a}т'), 'ˈnʲet');
      expect(wordPhonemes('лёд'), 'ˈlʲot');
      expect(wordPhonemes('мать'), 'ˈmatʲ');
      expect(wordPhonemes('люби${a}ть'), 'lʲʊˈbʲitʲ');
    });

    test('о and а reduce: ɐ just before the stress or first, ə elsewhere', () {
      expect(wordPhonemes('молоко${a}'), 'məɫɐˈko');
      expect(wordPhonemes('окно${a}'), 'ɐˈkno');
      expect(wordPhonemes('го${a}лос'), 'ˈɡoɫəs');
    });

    test('after a soft consonant an unstressed е or я is ɪ', () {
      expect(wordPhonemes('река${a}'), 'rʲɪˈka');
      expect(wordPhonemes('пята${a}к'), 'pʲɪˈtak');
    });

    test('е, ё, ю, я first or after a vowel or a sign start with j', () {
      expect(wordPhonemes('я${a}блоко'), 'ˈjabɫəkə');
      expect(wordPhonemes('мою${a}'), 'mɐˈju');
      expect(wordPhonemes('съе${a}л'), 'ˈsjeɫ');
      expect(wordPhonemes('семья${a}'), 'sʲɪmʲˈja');
    });

    test('ж, ш, ц stay hard; ч and щ are always soft', () {
      expect(wordPhonemes('жи${a}знь'), 'ˈʐɨzʲnʲ');
      expect(wordPhonemes('шесто${a}й'), 'ʂɨˈstoj');
      expect(wordPhonemes('цирк'), 'ˈtsɨrk');
      expect(wordPhonemes('час'), 'ˈtɕas');
      expect(wordPhonemes('щи'), 'ˈɕːi');
    });

    test('a voiced consonant at the end of a word is said voiceless', () {
      expect(wordPhonemes('хлеб'), 'ˈxlʲep');
      expect(wordPhonemes('друг'), 'ˈdruk');
      expect(wordPhonemes('нож'), 'ˈnoʂ');
    });

    test('a cluster takes the voicing of its last consonant', () {
      expect(wordPhonemes('ло${a}дка'), 'ˈɫotkə');
      expect(wordPhonemes('про${a}сьба'), 'ˈprozʲbə');
      expect(wordPhonemes('вокза${a}л'), 'vɐˈɡzaɫ');
      // в does not voice what comes before it.
      expect(wordPhonemes('сва${a}дьба'), 'ˈsvadʲbə');
    });

    test('г in the endings -ого and -его is said в', () {
      expect(wordPhonemes('кра${a}сного'), 'ˈkrasnəvə');
      expect(wordPhonemes('его${a}'), 'jɪˈvo');
      expect(wordPhonemes('мно${a}го'), 'ˈmnoɡə');
    });

    test('-тся and -ться are one ts', () {
      expect(wordPhonemes('учи${a}ться'), 'ʊˈtɕitsə');
      expect(wordPhonemes('мо${a}ется'), 'ˈmojɪtsə');
    });

    test('с and з soften before a soft dental', () {
      expect(wordPhonemes('гость'), 'ˈɡosʲtʲ');
    });

    test('a few words are not said as they are spelled', () {
      expect(wordPhonemes('что'), 'ˈʂto');
      expect(wordPhonemes('коне${a}чно'), 'kɐˈnʲeʂnə');
      expect(wordPhonemes('со${a}лнце'), 'ˈsontsə');
      expect(wordPhonemes('здра${a}вствуй'), 'ˈzdrastvʊj');
      expect(wordPhonemes('сего${a}дня'), 'sʲɪˈvodnʲə');
    });

    test('тц and дц are one ts', () {
      expect(wordPhonemes('отцы${a}'), 'ɐˈtsɨ');
      expect(wordPhonemes('два${a}дцать'), 'ˈdvatsətʲ');
    });

    test('a word with no mark keeps its vowels whole and has no stress', () {
      expect(wordPhonemes('молоко'), 'moɫoko');
    });

    test('capitals and ё written е with a mark', () {
      expect(wordPhonemes('Москва${a}'), 'mɐˈskva');
      expect(wordPhonemes('е${a}лка'), 'ˈjeɫkə');
    });
  });

  group('a sentence', () {
    test('words are joined by spaces and punctuation is kept', () {
      expect(sentencePhonemes('Да, ма${a}ма до${a}ма.'), 'ˈda, ˈmamə ˈdomə.');
    });

    test('short function words take no stress', () {
      expect(sentencePhonemes('Я в до${a}ме и на у${a}лице.'),
          'ˈja v ˈdomʲɪ ɪ nə ˈulʲɪtsə.');
    });
  });

  group('every symbol is one the voice knows', () {
    test('the output alphabet', () {
      final words = [
        'жи${a}знь', 'щи', 'вокза${a}л', 'семья${a}', 'учи${a}ться',
        'здра${a}вствуй', 'фу${a}тбол', 'хи${a}трый', 'эх',
      ];
      for (final w in words) {
        for (final s in phonemeSymbols(wordPhonemes(w))) {
          expect(denisSymbols, contains(s), reason: '$w gives $s');
        }
      }
    });
  });
}
