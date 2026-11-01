@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/reader/speech/kokoro/kokoro_front_end.dart';

/// The Chinese front end as the engine gets it: the data files read off
/// the main isolate, each sentence into Kokoro's chunks. Run on the
/// mandarin_g2p package's committed slice of the data, which is exact
/// for its 118 targeted lines (written for Trellis, MIT).
void main() {
  const fixture = '../packages/mandarin_g2p/test/fixtures/targeted';
  final paths = {
    'jiebaDict': '$fixture/jieba_dict.txt',
    'finalsegHmm': '$fixture/jieba_finalseg_hmm.tsv',
    'possegHmm': '$fixture/jieba_posseg_hmm.tsv',
    'pinyinSingle': '$fixture/pypinyin_single.tsv',
    'pinyinPhrases': '$fixture/pypinyin_phrases.tsv',
    'pinyinAux': '$fixture/pypinyin_aux.json',
    'misakiTables': '$fixture/misaki_zh_tables.json',
  };

  test('each targeted line becomes misaki’s ids, in one chunk', () async {
    final frontEnd = await loadKokoroFrontEnd(paths);
    final golden = jsonDecode(
            File('$fixture/targeted_golden.json').readAsStringSync())
        as Map<String, dynamic>;
    var n = 0;
    for (final item
        in (golden['items'] as List).cast<Map<String, dynamic>>()) {
      final chunks = frontEnd(item['text'] as String);
      final ids = (item['input_ids'] as List).cast<int>();
      if (ids.length <= 2) {
        expect(chunks, isEmpty, reason: '${item['text']}: nothing to say');
        continue;
      }
      expect(chunks.single.inputIds, ids, reason: '${item['text']}');
      expect(chunks.single.lenPs, item['len_ps'], reason: '${item['text']}');
      n++;
    }
    expect(n, greaterThan(100));
  });

  test('a missing data file is a typed, calm error', () async {
    await expectLater(
        loadKokoroFrontEnd({...paths, 'jiebaDict': '$fixture/nope.txt'}),
        throwsA(isA<KokoroFrontEndMissingException>()));
  });
}
