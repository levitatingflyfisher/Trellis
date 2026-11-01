import 'dart:convert';
import 'dart:io';

import 'package:mandarin_g2p/src/pinyin.dart';
import 'package:test/test.dart';

/// Tiny tables in test/fixtures/tiny/ (pypinyin_aux.json is pypinyin's
/// own, MIT); the expected values are real pypinyin 0.55.0's on the same
/// tables with misaki's overrides (tool/tiny_pinyin_expectations.py).
void main() {
  String fixture(String name) =>
      File('test/fixtures/tiny/$name').readAsStringSync();

  final tables = PinyinTables.parse(
    single: fixture('pypinyin_single.tsv'),
    phrases: fixture('pypinyin_phrases.tsv'),
    aux: fixture('pypinyin_aux.json'),
    singleOverride: {'地': 'de,di4'},
    phrasesOverride: {
      '不': [
        ['bu4']
      ],
      '嗲': [
        ['dia3']
      ],
    },
  );
  final expected =
      jsonDecode(fixture('pinyin_expected.json')) as Map<String, dynamic>;

  void cases(String name, Object? Function(String) run) {
    group(name, () {
      for (final e in (expected[name] as Map<String, dynamic>).entries) {
        test(e.key, () => expect(run(e.key), e.value));
      }
    });
  }

  cases('initials', tables.toInitials);
  cases('finalsTone3', tables.toFinalsTone3);
  cases('lazyInitials', tables.initials);
  cases('lazyFinals', tables.finalsTone3);
}
