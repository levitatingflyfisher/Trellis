import 'dart:io';

import 'package:mandarin_g2p/src/pinyin.dart';
import 'package:mandarin_g2p/src/trellis_overrides.dart';
import 'package:test/test.dart';

void main() {
  test('every override is a multi-character word with one syllable each', () {
    expect(trellisPhraseOverrides, isNotEmpty);
    expect(trellisPhraseOverrides.length, lessThanOrEqualTo(100));
    for (final e in trellisPhraseOverrides.entries) {
      final n = e.key.runes.length;
      expect(n, greaterThan(1), reason: e.key);
      expect(e.value.length, n, reason: e.key);
      for (final s in e.value) {
        expect(s.length, 1, reason: e.key);
      }
    }
  });

  test('the overrides win over pypinyin’s own phrases and characters', () {
    String fixture(String name) =>
        File('test/fixtures/tiny/$name').readAsStringSync();
    final tables = PinyinTables.parse(
      single: '${fixture('pypinyin_single.tsv')}'
          '671D\tcháo,zhāo\n9C9C\txiān,xiǎn\n6B63\tzhèng,zhēng\n'
          '5F53\tdāng,dàng\n',
      phrases: '${fixture('pypinyin_phrases.tsv')}正当\tzhèng dāng\n',
      aux: fixture('pypinyin_aux.json'),
      phrasesOverride: {
        '不': [
          ['bu4']
        ],
        ...trellisPhraseOverrides,
      },
    );
    expect(tables.finalsTone3('朝鲜'), ['ao2', 'ian3']);
    expect(tables.finalsTone3('不正当'), ['u4', 'eng4', 'ang4']);
    expect(tables.finalsTone3('正当'), ['eng4', 'ang1'],
        reason: '正当 alone keeps pypinyin’s reading');
  });
}
