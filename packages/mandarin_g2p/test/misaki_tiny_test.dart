import 'dart:convert';
import 'dart:io';

import 'package:mandarin_g2p/mandarin_g2p.dart';
import 'package:mandarin_g2p/src/jieba.dart';
import 'package:mandarin_g2p/src/jieba_dict.dart';
import 'package:mandarin_g2p/src/jieba_hmm.dart';
import 'package:mandarin_g2p/src/pinyin.dart';
import 'package:mandarin_g2p/src/zh_frontend.dart';
import 'package:test/test.dart';

import 'support/compare.dart';

/// misaki zh v1.1 end to end on the tiny tables in test/fixtures/tiny/:
/// 不 and 一 merges and sandhi, reduplication, third-tone merges and
/// sandhi, neutral tones, erhua, numbers, punctuation, Latin runs, and a
/// line misaki itself fails on. The expected values are real misaki's on
/// the same tables (tool/tiny_misaki_expectations.py).
void main() {
  String fixture(String name) =>
      File('test/fixtures/tiny/$name').readAsStringSync();

  final g2p = MandarinG2p.fromData(
    jiebaDict: fixture('jieba_dict.txt'),
    finalsegHmm: fixture('jieba_finalseg_hmm.tsv'),
    possegHmm: fixture('jieba_posseg_hmm.tsv'),
    pinyinSingle: fixture('pypinyin_single.tsv'),
    pinyinPhrases: fixture('pypinyin_phrases.tsv'),
    pinyinAux: fixture('pypinyin_aux.json'),
    misakiTables: fixture('misaki_zh_tables.json'),
  );
  final tables = MisakiTables.parse(fixture('misaki_zh_tables.json'));
  final frontend = ZhFrontend(
    Jieba(
      JiebaDict.parse(fixture('jieba_dict.txt')),
      FinalsegHmm.parse(fixture('jieba_finalseg_hmm.tsv')),
      PossegHmm.parse(fixture('jieba_posseg_hmm.tsv')),
    ),
    PinyinTables.parse(
      single: fixture('pypinyin_single.tsv'),
      phrases: fixture('pypinyin_phrases.tsv'),
      aux: fixture('pypinyin_aux.json'),
      singleOverride: tables.singleOverride,
      phrasesOverride: tables.phrasesOverride,
    ),
    tables,
  );
  final expected =
      jsonDecode(fixture('misaki_expected.json')) as Map<String, dynamic>;
  final direct = expected['direct'] as Map<String, dynamic>;

  group('whole lines', () {
    for (final item
        in (expected['items'] as List).cast<Map<String, dynamic>>()) {
      final text = item['text'] as String;
      if (item.containsKey('error')) {
        test('$text fails as misaki does (${item['error']})', () {
          expect(() => g2p.g2p(text), throwsA(isA<Error>()));
        });
        continue;
      }
      test(text, () {
        final trace = ZhTrace();
        final got = g2p.g2p(text, trace: trace);
        expect(firstDifference(item, trace, got), '');
      });
    }
  });

  group('modified_tone', () {
    for (final c in direct['modified_tone'] as List) {
      test('${c[0]} ${c[1]}', () {
        final got = frontend.sandhi.modifiedTone(
            c[0] as String, c[1] as String, (c[2] as List).cast<String>());
        expect(got, c[3]);
      });
    }
  });

  group('erhua', () {
    for (final c in direct['erhua'] as List) {
      test('${c[2]} ${c[3]} ${c[1]}', () {
        final (i, f) = frontend.mergeErhua((c[0] as List).cast<String>(),
            (c[1] as List).cast<String>(), c[2] as String, c[3] as String);
        expect([i, f], c[4]);
      });
    }
  });

  group('pre_merge', () {
    for (final c in direct['pre_merge'] as List) {
      test(jsonEncode(c[0]), () {
        final seg = [
          for (final p in c[0] as List) (p[0] as String, p[1] as String)
        ];
        final got = [
          for (final (w, t) in frontend.sandhi.preMerge(seg)) [w, t]
        ];
        expect(got, c[1]);
      });
    }
  });

  group('split_word', () {
    for (final c in direct['split_word'] as List) {
      test(c[0], () => expect(frontend.sandhi.splitWord(c[0] as String), c[1]));
    }
  });

  test('g2pChunks splits a line over 510 phonemes into pieces that fit', () {
    final text = List.filled(60, '你好，世界！').join();
    final whole = g2p.g2p(text);
    expect(whole.lenPs, greaterThan(510));
    final chunks = g2p.g2pChunks(text);
    expect(chunks.length, greaterThan(1));
    for (final c in chunks) {
      expect(c.lenPs, lessThanOrEqualTo(510));
      expect(c.inputIds.first, 0);
      expect(c.inputIds.last, 0);
      expect(c.styleRow, c.lenPs - 1);
    }
    // Every piece ends at a sentence mark here, and nothing is lost.
    expect(chunks.map((c) => c.phonemes).join(' '), whole.phonemes.trim());
  });
}
