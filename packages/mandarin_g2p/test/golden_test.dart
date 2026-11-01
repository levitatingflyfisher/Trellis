@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:mandarin_g2p/mandarin_g2p.dart';
import 'package:test/test.dart';

import 'support/compare.dart';

/// Every golden line made by misaki zh v1.1 itself (418 lines: 300 from
/// NTREX-128 Chinese, 118 written for Trellis), compared token for token,
/// with each intermediate stage checked so a difference shows where it
/// starts. Skipped unless two variables are set, because neither the
/// 10.9 MB of data nor the NTREX lines (CC-BY-SA) are committed:
///
///  * KOKORO_ZH_DATA_DIR: the folder with the seven data files
///    (jieba_dict.txt, jieba_finalseg_hmm.tsv, jieba_posseg_hmm.tsv,
///    pypinyin_single.tsv, pypinyin_phrases.tsv, pypinyin_aux.json,
///    misaki_zh_tables.json).
///  * KOKORO_ZH_GOLDEN: the path of zh_g2p_v2.json, made with Trellis's
///    word readings loaded (tool/golden_v2.py).
///
/// Set KOKORO_ZH_PLAIN_MISAKI=1 (with zh_g2p.json) to compare against
/// plain misaki, without Trellis's word readings. Both sets of goldens
/// were made with pypinyin-dict's large_pinyin not loaded, as Trellis
/// runs.
void main() {
  final dir = Platform.environment['KOKORO_ZH_DATA_DIR'];
  final golden = Platform.environment['KOKORO_ZH_GOLDEN'];
  final skip = dir == null || golden == null
      ? 'set KOKORO_ZH_DATA_DIR and KOKORO_ZH_GOLDEN to run'
      : false;

  late MandarinG2p g2p;
  late List<Map<String, dynamic>> items;

  setUpAll(() {
    if (skip != false) return;
    String read(String name) => File('$dir/$name').readAsStringSync();
    final sw = Stopwatch()..start();
    g2p = MandarinG2p.fromData(
      jiebaDict: read('jieba_dict.txt'),
      finalsegHmm: read('jieba_finalseg_hmm.tsv'),
      possegHmm: read('jieba_posseg_hmm.tsv'),
      pinyinSingle: read('pypinyin_single.tsv'),
      pinyinPhrases: read('pypinyin_phrases.tsv'),
      pinyinAux: read('pypinyin_aux.json'),
      misakiTables: read('misaki_zh_tables.json'),
      trellisOverrides: Platform.environment['KOKORO_ZH_PLAIN_MISAKI'] != '1',
    );
    print('data read and parsed in ${sw.elapsedMilliseconds} ms');
    items = ((jsonDecode(File(golden!).readAsStringSync())
            as Map<String, dynamic>)['items'] as List)
        .cast<Map<String, dynamic>>();
  });

  test('all golden lines give misaki’s input_ids, stage by stage', () {
    var equal = 0;
    final diffs = <String>[];
    for (final item in items) {
      final trace = ZhTrace();
      final String where;
      try {
        final got = g2p.g2p(item['text'] as String, trace: trace);
        where = firstDifference(item, trace, got);
      } catch (e) {
        diffs.add('${item['id']}: threw $e');
        continue;
      }
      if (where.isEmpty) {
        equal++;
      } else {
        diffs.add('${item['id']} ${jsonEncode(item['text'])}: $where');
      }
    }
    print('golden: $equal/${items.length} equal');
    for (final d in diffs) {
      print(d);
    }
    expect(diffs, isEmpty);
    expect(equal, items.length);
  }, skip: skip);
}
