import 'dart:convert';
import 'dart:io';

import 'package:mandarin_g2p/mandarin_g2p.dart';
import 'package:test/test.dart';

/// The 118 golden lines written for Trellis (一 and 不 sandhi, third
/// tones, neutral tones, erhua, numbers, dates, percentages, mixed Latin
/// text), as misaki zh v1.1 read them on the full data, run here on the
/// slice of the data those lines touch (tool/make_targeted_fixture.py
/// says why the slice gives the same answers). Always on, unlike
/// golden_test.dart.
void main() {
  String fixture(String name) =>
      File('test/fixtures/targeted/$name').readAsStringSync();

  final g2p = MandarinG2p.fromData(
    jiebaDict: fixture('jieba_dict.txt'),
    finalsegHmm: fixture('jieba_finalseg_hmm.tsv'),
    possegHmm: fixture('jieba_posseg_hmm.tsv'),
    pinyinSingle: fixture('pypinyin_single.tsv'),
    pinyinPhrases: fixture('pypinyin_phrases.tsv'),
    pinyinAux: fixture('pypinyin_aux.json'),
    misakiTables: fixture('misaki_zh_tables.json'),
  );
  final items = ((jsonDecode(fixture('targeted_golden.json'))
          as Map<String, dynamic>)['items'] as List)
      .cast<Map<String, dynamic>>();

  test('the fixture holds all 118 targeted lines', () {
    expect(items.length, 118);
  });
  for (final item in items) {
    test('${item['id']} ${item['category']} ${item['text']}', () {
      final got = g2p.g2p(item['text'] as String);
      expect(got.phonemes, item['phonemes']);
      expect(got.lenPs, item['len_ps']);
      expect(got.inputIds, item['input_ids']);
    });
  }
}
