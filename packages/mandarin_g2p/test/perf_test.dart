@TestOn('vm')
library;

import 'dart:io';

import 'package:mandarin_g2p/mandarin_g2p.dart';
import 'package:test/test.dart';

/// Load time and per-sentence time on the full data. Skipped unless
/// KOKORO_ZH_DATA_DIR names the folder with the seven data files. It
/// prints the numbers and fails only on gross slowness (a desktop JIT
/// run; a phone is slower).
void main() {
  final dir = Platform.environment['KOKORO_ZH_DATA_DIR'];
  final skip = dir == null ? 'set KOKORO_ZH_DATA_DIR to run' : false;

  // 100 characters, written for this test.
  const sentence = '今天早上我们一起去公园散步，看见很多老人在打太极拳，'
      '孩子们在草地上放风筝。中午我们在湖边的小饭馆吃了饺子和面条，'
      '下午三点半回到家里，大家都觉得有点儿累，但是心情非常好。'
      '晚上爸爸做了鱼，我们一起看电视。';

  test('load and convert times', () {
    expect(sentence.runes.length, 100);
    String read(String name) => File('$dir/$name').readAsStringSync();
    final files = {
      for (final n in [
        'jieba_dict.txt',
        'jieba_finalseg_hmm.tsv',
        'jieba_posseg_hmm.tsv',
        'pypinyin_single.tsv',
        'pypinyin_phrases.tsv',
        'pypinyin_aux.json',
        'misaki_zh_tables.json',
      ])
        n: read(n),
    };
    final loads = <int>[];
    late MandarinG2p g2p;
    for (var i = 0; i < 3; i++) {
      final sw = Stopwatch()..start();
      g2p = MandarinG2p.fromData(
        jiebaDict: files['jieba_dict.txt']!,
        finalsegHmm: files['jieba_finalseg_hmm.tsv']!,
        possegHmm: files['jieba_posseg_hmm.tsv']!,
        pinyinSingle: files['pypinyin_single.tsv']!,
        pinyinPhrases: files['pypinyin_phrases.tsv']!,
        pinyinAux: files['pypinyin_aux.json']!,
        misakiTables: files['misaki_zh_tables.json']!,
      );
      loads.add(sw.elapsedMilliseconds);
    }
    final first = Stopwatch()..start();
    final out = g2p.g2p(sentence);
    final firstUs = first.elapsedMicroseconds;
    const n = 50;
    final sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      g2p.g2p(sentence);
    }
    final perUs = sw.elapsedMicroseconds / n;
    print('load (ms, parse only, three runs): $loads');
    print('first sentence: ${(firstUs / 1000).toStringAsFixed(1)} ms; '
        'then ${(perUs / 1000).toStringAsFixed(2)} ms per 100-character '
        'sentence; ${out.lenPs} phonemes');
    expect(loads.last, lessThan(5000));
    expect(perUs, lessThan(200000));
  }, skip: skip);
}
