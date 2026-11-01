import 'dart:convert';
import 'dart:io';

import 'package:mandarin_g2p/src/jieba.dart';
import 'package:mandarin_g2p/src/jieba_dict.dart';
import 'package:mandarin_g2p/src/jieba_hmm.dart';
import 'package:test/test.dart';

/// Tiny tables in test/fixtures/tiny/; the expected cuts are real jieba
/// 0.42.1's on the same tables (tool/tiny_jieba_expectations.py).
void main() {
  String fixture(String name) =>
      File('test/fixtures/tiny/$name').readAsStringSync();

  final dict = JiebaDict.parse(fixture('jieba_dict.txt'));
  final jieba = Jieba(
    dict,
    FinalsegHmm.parse(fixture('jieba_finalseg_hmm.tsv')),
    PossegHmm.parse(fixture('jieba_posseg_hmm.tsv')),
  );
  final expected =
      jsonDecode(fixture('jieba_expected.json')) as Map<String, dynamic>;

  group('dictionary', () {
    test('a word listed twice keeps its last frequency; total counts both', () {
      expect(dict.freqOf('B超'), 4);
      expect(dict.total, 2802);
    });
    test('a prefix that is no word has frequency 0 and tag x', () {
      expect(dict.freqOf('北京大'), 0);
      expect(dict.tagOf('北京大'), 'x');
      expect(dict.tagOf('北京大学'), 'nt');
    });
  });

  for (final kind in ['cut', 'posCut', 'cutForSearch']) {
    group(kind, () {
      final cases = expected[kind] as Map<String, dynamic>;
      for (final e in cases.entries) {
        test(jsonEncode(e.key), () {
          final got = switch (kind) {
            'cut' => jieba.cut(e.key),
            'cutForSearch' => jieba.cutForSearch(e.key),
            _ => [
                for (final (w, t) in jieba.posCut(e.key)) [w, t]
              ],
          };
          expect(got, e.value);
        });
      }
    });
  }
}
