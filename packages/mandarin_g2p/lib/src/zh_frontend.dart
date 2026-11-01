/// misaki's Chinese front end for Kokoro v1.1-zh: `ZHG2P(version='1.1')`
/// in `zh.py` and `ZHFrontend` in `zh_frontend.py`
/// (github.com/hexgrad/misaki@fba1236, Apache-2.0, Copyright hexgrad;
/// `zh_frontend.py` adapted from PaddleSpeech's
/// `t2s/frontend/zh_frontend.py`, Apache-2.0, Copyright (c) 2021
/// PaddlePaddle Authors).
///
/// Licensed under the Apache License, Version 2.0; you may not use this
/// file except in compliance with the License. You may obtain a copy at
/// http://www.apache.org/licenses/LICENSE-2.0. Changes from the original:
/// translated from Python to Dart; no English callback, so a Latin run
/// becomes the unknown mark, as misaki does when `en_callable` is None.
library;

import 'dart:convert';

import 'cn2an.dart';
import 'jieba.dart';
import 'pinyin.dart';
import 'py_text.dart';
import 'tone_sandhi.dart';

/// The tables misaki holds as code, read from `misaki_zh_tables.json`.
class MisakiTables {
  MisakiTables.parse(String json) {
    final m = jsonDecode(json) as Map<String, dynamic>;
    zhMap = (m['zh_map'] as Map<String, dynamic>).cast<String, String>();
    frontendPunc =
        (m['frontend_punc'] as String).runes.map(String.fromCharCode).toSet();
    phrasesOverride = (m['phrases_override'] as Map<String, dynamic>)
        .map((k, v) => MapEntry(k, [
              for (final s in v as List) (s as List).cast<String>(),
            ]));
    singleOverride =
        (m['single_override'] as Map<String, dynamic>).cast<String, String>();
    mustErhua = (m['must_erhua'] as List).cast<String>().toSet();
    notErhua = (m['not_erhua'] as List).cast<String>().toSet();
    mustNeutral = (m['must_neural_tone_words'] as List).cast<String>().toSet();
    mustNotNeutral =
        (m['must_not_neural_tone_words'] as List).cast<String>().toSet();
    sandhiPunc = m['sandhi_punc'] as String;
    mapPunctuation = [
      for (final p in m['map_punctuation'] as List)
        ((p as List)[0] as String, p[1] as String),
    ];
    unk = m['unk'] as String;
  }

  late final Map<String, String> zhMap;
  late final Set<String> frontendPunc;
  late final Map<String, List<List<String>>> phrasesOverride;
  late final Map<String, String> singleOverride;
  late final Set<String> mustErhua;
  late final Set<String> notErhua;
  late final Set<String> mustNeutral;
  late final Set<String> mustNotNeutral;
  late final String sandhiPunc;
  late final List<(String, String)> mapPunctuation;
  late final String unk;
}

/// One word or mark of the front end's output (misaki's `MToken`).
class ZhToken {
  ZhToken(this.text, this.tag);
  final String text;
  final String tag;
  String? phonemes;
  String whitespace = '';
}

/// The steps of one word, for tests that compare intermediate stages.
class ZhWordTrace {
  ZhWordTrace(this.word, this.initials, this.finals);
  final String word;
  final List<String> initials;
  final List<String> finals;
  late String tag;
  late List<String> finalsSandhi;
  late List<String> initialsErhua;
  late List<String> finalsErhua;
}

/// The steps of one Chinese segment, for tests.
class ZhSegmentTrace {
  ZhSegmentTrace(this.zh);
  final String zh;
  late List<TaggedWord> posseg;
  final List<(String, List<TaggedWord>)> preMergeSteps = [];
  final List<ZhWordTrace> words = [];
  late String phonemes;
  late List<ZhToken> tokens;
}

/// The steps of a whole line, for tests.
class ZhTrace {
  late String cn2an;
  late String punctMapped;
  final List<(String, String)> enZhSplit = [];
  final List<ZhSegmentTrace> segments = [];
}

class ZhFrontend {
  ZhFrontend(this.jieba, this.pinyin, this.tables)
      : _sandhi = ToneSandhi(
          jieba: jieba,
          pinyin: pinyin,
          mustNeutral: tables.mustNeutral,
          mustNotNeutral: tables.mustNotNeutral,
          punc: tables.sandhiPunc,
        );

  final Jieba jieba;
  final PinyinTables pinyin;
  final MisakiTables tables;
  final ToneSandhi _sandhi;

  ToneSandhi get sandhi => _sandhi;

  static final _enZh =
      RegExp(r"([A-Za-z '-]*[A-Za-z][A-Za-z '-]*)|([^A-Za-z]+)");

  /// `ZHG2P.map_punctuation`.
  String mapPunctuation(String text) {
    for (final (from, to) in tables.mapPunctuation) {
      text = text.replaceAll(from, to);
    }
    return pyStrip(text);
  }

  /// `ZHG2P.__call__(text)` with version 1.1 and no English callback:
  /// the phoneme string.
  String call(String text, {ZhTrace? trace}) {
    if (pyStrip(text).isEmpty) return '';
    text = an2cnTransform(text);
    trace?.cn2an = text;
    text = mapPunctuation(text);
    trace?.punctMapped = text;
    final segments = <String>[];
    for (final m in _enZh.allMatches(text)) {
      final en = pyStrip(m[1] ?? '');
      final zh = pyStrip(m[2] ?? '');
      trace?.enZhSplit.add((en, zh));
      if (zh.isNotEmpty) {
        segments.add(frontend(zh, trace: trace));
      } else {
        segments.add(tables.unk);
      }
    }
    return segments.join(' ');
  }

  /// `_get_initials_finals`.
  (List<String>, List<String>) initialsFinals(String word) {
    final ini = pinyin.initials(word);
    final fin = ToneSandhi.enFix(word, pinyin.finalsTone3(word));
    final initials = <String>[];
    final finals = <String>[];
    final n = ini.length < fin.length ? ini.length : fin.length;
    for (var k = 0; k < n; k++) {
      final c = ini[k];
      var v = fin[k];
      if (_iDigit.hasMatch(v)) {
        if (c == 'z' || c == 'c' || c == 's') {
          v = v.replaceAll('i', 'ii');
        } else if (c == 'zh' || c == 'ch' || c == 'sh' || c == 'r') {
          v = v.replaceAll('i', 'iii');
        }
      }
      initials.add(c);
      finals.add(v);
    }
    return (initials, finals);
  }

  static final _iDigit = RegExp('^i[$pyDigitClass]', unicode: true);

  /// `_merge_erhua`.
  (List<String>, List<String>) mergeErhua(
      List<String> initials, List<String> finals, String word, String pos) {
    final w = pyChars(word);
    for (var i = 0; i < finals.length; i++) {
      if (i == finals.length - 1 && _at(w, i) == '儿' && finals[i] == 'er1') {
        finals[i] = 'er2';
      }
    }
    if (!tables.mustErhua.contains(word) &&
        (tables.notErhua.contains(word) ||
            const {'a', 'j', 'nr'}.contains(pos))) {
      return (initials, finals);
    }
    if (finals.length != w.length) return (initials, finals);
    final newI = <String>[];
    final newF = <String>[];
    final last2 = w.sublist(w.length >= 2 ? w.length - 2 : 0).join();
    for (var i = 0; i < finals.length; i++) {
      final phn = finals[i];
      if (i == finals.length - 1 &&
          w[i] == '儿' &&
          (phn == 'er2' || phn == 'er5') &&
          !tables.notErhua.contains(last2) &&
          newF.isNotEmpty) {
        final f = pyChars(newF.last);
        if (f.isEmpty) throw RangeError('string index out of range');
        newF[newF.length - 1] =
            '${f.sublist(0, f.length - 1).join()}R${f.last}';
      } else {
        newI.add(initials[i]);
        newF.add(phn);
      }
    }
    return (newI, newF);
  }

  static String _at(List<String> w, int i) {
    if (i >= w.length) throw RangeError('string index out of range');
    return w[i];
  }

  static final _beforeDigit = RegExp('(?=[$pyDigitClass])', unicode: true);

  /// `ZHFrontend.__call__(text)`: the phoneme string of one Chinese run.
  String frontend(String text, {ZhTrace? trace}) {
    final seg = trace == null ? null : ZhSegmentTrace(text);
    if (seg != null) trace!.segments.add(seg);
    final tokens = <ZhToken>[];
    final cut = jieba.posCut(text);
    seg?.posseg = cut;
    final merged = _sandhi.preMerge(cut,
        onStep: seg == null
            ? null
            : (name, s) => seg.preMergeSteps.add((name, List.of(s))));
    final punc = tables.frontendPunc;
    for (var (word, pos) in merged) {
      final chars = word.runes.toList();
      if (pos == 'x' && _allIn(chars, 0x4E00, 0x9FFF)) {
        pos = 'X';
      } else if (pos != 'x' && punc.contains(word)) {
        pos = 'x';
      }
      final tk = ZhToken(word, pos);
      if (pos == 'x' || pos == 'eng') {
        if (!pyIsSpaceString(word)) {
          if (pos == 'x' && punc.contains(word)) tk.phonemes = word;
          tokens.add(tk);
        } else if (tokens.isNotEmpty) {
          tokens.last.whitespace += word;
        }
        continue;
      } else if (tokens.isNotEmpty &&
          tokens.last.tag != 'x' &&
          tokens.last.tag != 'eng' &&
          tokens.last.whitespace.isEmpty) {
        tokens.last.whitespace = '/';
      }
      var (subI, subF) = initialsFinals(word);
      final wt =
          seg == null ? null : ZhWordTrace(word, List.of(subI), List.of(subF));
      if (wt != null) seg!.words.add(wt);
      subF = _sandhi.modifiedTone(word, pos, subF);
      if (wt != null) {
        wt.tag = pos;
        wt.finalsSandhi = List.of(subF);
      }
      (subI, subF) = mergeErhua(subI, subF, word, pos);
      if (wt != null) {
        wt.initialsErhua = List.of(subI);
        wt.finalsErhua = List.of(subF);
      }
      final phones = <String>[];
      final n = subI.length < subF.length ? subI.length : subF.length;
      for (var k = 0; k < n; k++) {
        final c = subI[k];
        final v = subF[k];
        if (c.isNotEmpty) phones.add(c);
        if (v.isNotEmpty && (!punc.contains(v) || v != c)) phones.add(v);
      }
      var joined =
          phones.join('_').replaceAll('_eR', '_er').replaceAll('R', '_R');
      joined = joined.replaceAll(_beforeDigit, '_');
      tk.phonemes =
          joined.split('_').map((p) => tables.zhMap[p] ?? tables.unk).join();
      tokens.add(tk);
    }
    final b = StringBuffer();
    for (final tk in tokens) {
      b
        ..write(tk.phonemes ?? tables.unk)
        ..write(tk.whitespace);
    }
    final result = b.toString();
    if (seg != null) {
      seg.phonemes = result;
      seg.tokens = tokens;
    }
    return result;
  }

  // '一' <= min(word) and max(word) <= '鿿'
  static bool _allIn(List<int> chars, int lo, int hi) {
    if (chars.isEmpty) throw ArgumentError('min() arg is an empty sequence');
    for (final c in chars) {
      if (c < lo || c > hi) return false;
    }
    return true;
  }
}
