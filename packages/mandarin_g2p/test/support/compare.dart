import 'dart:convert';

import 'package:mandarin_g2p/mandarin_g2p.dart';

/// The first stage where [trace] and [got] differ from the golden item,
/// or '' when every stage and the ids match.
String firstDifference(
    Map<String, dynamic> item, ZhTrace trace, KokoroZhTokens got) {
  String j(Object? o) => jsonEncode(o);
  if (trace.cn2an != item['cn2an']) {
    return 'cn2an ${j(trace.cn2an)} != ${j(item['cn2an'])}';
  }
  if (trace.punctMapped != item['punct_mapped']) {
    return 'punctuation ${j(trace.punctMapped)} != ${j(item['punct_mapped'])}';
  }
  final split = [
    for (final (en, zh) in trace.enZhSplit) [en, zh]
  ];
  if (j(split) != j(item['en_zh_split'])) {
    return 'en/zh split ${j(split)} != ${j(item['en_zh_split'])}';
  }
  final segs = item['segments'] as List;
  if (segs.length != trace.segments.length) {
    return 'segment count ${trace.segments.length} != ${segs.length}';
  }
  for (var s = 0; s < segs.length; s++) {
    final want = segs[s] as Map<String, dynamic>;
    final have = trace.segments[s];
    final pos = [
      for (final (w, t) in have.posseg) [w, t]
    ];
    if (j(pos) != j(want['posseg'])) {
      return 'posseg ${j(pos)} != ${j(want['posseg'])}';
    }
    final steps = want['pre_merge_steps'] as List;
    for (var k = 0; k < steps.length; k++) {
      final (name, seg) = have.preMergeSteps[k];
      final s2 = [
        for (final (w, t) in seg) [w, t]
      ];
      if (name != steps[k][0] || j(s2) != j(steps[k][1])) {
        return '$name ${j(s2)} != ${j(steps[k][1])}';
      }
    }
    final words = want['words'] as List;
    if (words.length != have.words.length) {
      return 'word count ${have.words.length} != ${words.length}';
    }
    for (var w = 0; w < words.length; w++) {
      final ww = words[w] as Map<String, dynamic>;
      final hw = have.words[w];
      for (final (name, mine) in [
        ('word', hw.word),
        ('initials', hw.initials),
        ('finals', hw.finals),
        ('tag', hw.tag),
        ('finals_sandhi', hw.finalsSandhi),
        ('initials_erhua', hw.initialsErhua),
        ('finals_erhua', hw.finalsErhua),
      ]) {
        if (j(mine) != j(ww[name])) {
          return '${ww['word']} $name ${j(mine)} != ${j(ww[name])}';
        }
      }
    }
    if (have.phonemes != want['phonemes']) {
      return 'segment phonemes ${j(have.phonemes)} != ${j(want['phonemes'])}';
    }
  }
  if (got.phonemes != item['phonemes']) {
    return 'phonemes ${j(got.phonemes)} != ${j(item['phonemes'])}';
  }
  if (got.lenPs != item['len_ps']) return 'len_ps ${got.lenPs}';
  if (got.styleRow != item['style_row']) return 'style_row ${got.styleRow}';
  if (j(got.inputIds) != j(item['input_ids'])) {
    return 'input_ids ${j(got.inputIds)} != ${j(item['input_ids'])}';
  }
  return '';
}
