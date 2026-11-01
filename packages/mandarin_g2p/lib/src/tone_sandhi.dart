/// Mandarin tone sandhi: 不 and 一, neutral tones, third-tone runs, and
/// the word merges done before them. A port of misaki's
/// `tone_sandhi.py` (github.com/hexgrad/misaki@fba1236, Apache-2.0),
/// itself adapted from PaddleSpeech's `t2s/frontend/tone_sandhi.py`
/// (Apache-2.0, Copyright (c) 2021 PaddlePaddle Authors).
///
/// Licensed under the Apache License, Version 2.0; you may not use this
/// file except in compliance with the License. You may obtain a copy at
/// http://www.apache.org/licenses/LICENSE-2.0. Changes from the original:
/// translated from Python to Dart, with the same rules in the same order.
///
/// Where Python would raise (an empty final reached by `x[-1]`, a list
/// shorter than the word), this code throws too, so a caller sees the
/// same failure misaki has.
library;

import 'jieba.dart';
import 'pinyin.dart';
import 'py_text.dart';

const _bu = '不';
const _yi = '一';
const _xEng = {'x', 'eng'};

class ToneSandhi {
  ToneSandhi({
    required this.jieba,
    required this.pinyin,
    required this.mustNeutral,
    required this.mustNotNeutral,
    required this.punc,
  });

  final Jieba jieba;
  final PinyinTables pinyin;
  final Set<String> mustNeutral;
  final Set<String> mustNotNeutral;

  /// `self.punc`, a string searched with `in`.
  final String punc;

  /// `_split_word`: the word cut in two around its shortest search word.
  List<String> splitWord(String word) {
    final list = jieba.cutForSearch(word);
    // sorted(key=len) is stable; Dart's sort is not, so sort by
    // (length, position).
    final idx = List<int>.generate(list.length, (i) => i)
      ..sort((a, b) {
        final d = pyLen(list[a]) - pyLen(list[b]);
        return d != 0 ? d : a - b;
      });
    final first = list[idx.first];
    final chars = pyChars(word);
    final n = pyLen(first);
    if (word.indexOf(first) == 0) {
      return [first, chars.sublist(n).join()];
    }
    return [chars.sublist(0, chars.length - n).join(), first];
  }

  List<String> _neutralSandhi(String word, String pos, List<String> finals) {
    if (mustNotNeutral.contains(word)) return finals;
    final w = pyChars(word);
    for (var j = 0; j < w.length; j++) {
      if (j - 1 >= 0 && w[j] == w[j - 1] && 'nva'.contains(_first(pos))) {
        finals[j] = _tone(finals[j], '5');
      }
    }
    final geIdx = w.indexOf('个');
    final last = w.isEmpty ? '' : w.last;
    if (w.isNotEmpty && '吧呢啊呐噻嘛吖嗨呐哦哒滴哩哟喽啰耶喔诶'.contains(last)) {
      _setLast(finals, '5');
    } else if (w.isNotEmpty && '的地得'.contains(last)) {
      _setLast(finals, '5');
    } else if (w.length == 1 &&
        '了着过'.contains(word) &&
        const {'ul', 'uz', 'ug'}.contains(pos)) {
      _setLast(finals, '5');
    } else if (w.length > 1 &&
        '们子'.contains(last) &&
        const {'r', 'n'}.contains(pos)) {
      _setLast(finals, '5');
    } else if (w.length > 1 &&
        '上下'.contains(last) &&
        const {'s', 'l', 'f'}.contains(pos)) {
      _setLast(finals, '5');
    } else if (w.length > 1 &&
        '来去'.contains(last) &&
        '上下进出回过起开'.contains(w[w.length - 2])) {
      _setLast(finals, '5');
    } else if ((geIdx >= 1 &&
            (_isNumeric(w[geIdx - 1]) ||
                '几有两半多各整每做是'.contains(w[geIdx - 1]))) ||
        word == '个') {
      finals[geIdx] = _tone(finals[geIdx], '5');
    } else {
      if (mustNeutral.contains(word) || mustNeutral.contains(_last2(w))) {
        _setLast(finals, '5');
      }
    }

    final wordList = splitWord(word);
    final n0 = pyLen(wordList[0]);
    final finalsList = [
      finals.sublist(0, n0 < finals.length ? n0 : finals.length),
      finals.sublist(n0 < finals.length ? n0 : finals.length),
    ];
    for (var i = 0; i < wordList.length; i++) {
      final sub = wordList[i];
      if (mustNeutral.contains(sub) ||
          mustNeutral.contains(_last2(pyChars(sub)))) {
        _setLast(finalsList[i], '5');
      }
    }
    return [...finalsList[0], ...finalsList[1]];
  }

  List<String> _buSandhi(String word, List<String> finals) {
    final w = pyChars(word);
    if (w.length == 3 && w[1] == _bu) {
      finals[1] = _tone(finals[1], '5');
    } else {
      for (var i = 0; i < w.length; i++) {
        if (w[i] == _bu &&
            i + 1 < w.length &&
            _lastChar(finals[i + 1]) == '4') {
          finals[i] = _tone(finals[i], '2');
        }
      }
    }
    return finals;
  }

  List<String> _yiSandhi(String word, List<String> finals) {
    final w = pyChars(word);
    if (w.contains(_yi) && w.where((c) => c != _yi).every(_isNumeric)) {
      return finals;
    } else if (w.length == 3 && w[1] == _yi && w[0] == w.last) {
      finals[1] = _tone(finals[1], '5');
    } else if (word.startsWith('第一')) {
      finals[1] = _tone(finals[1], '1');
    } else {
      for (var i = 0; i < w.length; i++) {
        if (w[i] == _yi && i + 1 < w.length) {
          final next = _lastChar(finals[i + 1]);
          if (next == '4' || next == '5') {
            finals[i] = _tone(finals[i], '2');
          } else if (!punc.contains(w[i + 1])) {
            finals[i] = _tone(finals[i], '4');
          }
        }
      }
    }
    return finals;
  }

  static bool _allToneThree(List<String> finals) {
    for (final x in finals) {
      if (_lastChar(x) != '3') return false;
    }
    return true;
  }

  List<String> _threeSandhi(String word, List<String> finals) {
    final n = pyLen(word);
    if (n == 2 && _allToneThree(finals)) {
      finals[0] = _tone(finals[0], '2');
    } else if (n == 3) {
      final wordList = splitWord(word);
      if (_allToneThree(finals)) {
        final l0 = pyLen(wordList[0]);
        if (l0 == 2) {
          finals[0] = _tone(finals[0], '2');
          finals[1] = _tone(finals[1], '2');
        } else if (l0 == 1) {
          finals[1] = _tone(finals[1], '2');
        }
      } else {
        final l0 = pyLen(wordList[0]);
        final cut = l0 < finals.length ? l0 : finals.length;
        final finalsList = [finals.sublist(0, cut), finals.sublist(cut)];
        for (var i = 0; i < finalsList.length; i++) {
          final sub = finalsList[i];
          if (_allToneThree(sub) && sub.length == 2) {
            sub[0] = _tone(sub[0], '2');
          } else if (i == 1 &&
              !_allToneThree(sub) &&
              _lastChar(sub[0]) == '3' &&
              _lastChar(_listLast(finalsList[0])) == '3') {
            finalsList[0][finalsList[0].length - 1] =
                _tone(_listLast(finalsList[0]), '2');
          }
          finals = [...finalsList[0], ...finalsList[1]];
        }
      }
    } else if (n == 4) {
      final finalsList = [finals.sublist(0, 2), finals.sublist(2)];
      finals = [];
      for (final sub in finalsList) {
        if (_allToneThree(sub)) sub[0] = _tone(sub[0], '2');
        finals.addAll(sub);
      }
    }
    return finals;
  }

  List<TaggedWord> _mergeBu(List<TaggedWord> seg) {
    final out = <TaggedWord>[];
    for (var i = 0; i < seg.length; i++) {
      var (word, pos) = seg[i];
      if (!_xEng.contains(pos)) {
        final lastWord = i > 0 ? seg[i - 1].$1 : null;
        if (lastWord == _bu) word = lastWord! + word;
      }
      final nextPos = i + 1 < seg.length ? seg[i + 1].$2 : null;
      if (word != _bu || nextPos == null || _xEng.contains(nextPos)) {
        out.add((word, pos));
      }
    }
    return out;
  }

  List<TaggedWord> _mergeYi(List<TaggedWord> seg) {
    var out = <TaggedWord>[];
    var skipNext = false;
    for (var i = 0; i < seg.length; i++) {
      if (skipNext) {
        skipNext = false;
        continue;
      }
      final (word, pos) = seg[i];
      if (i - 1 >= 0 &&
          word == _yi &&
          i + 1 < seg.length &&
          seg[i - 1].$1 == seg[i + 1].$1 &&
          seg[i - 1].$2 == 'v' &&
          !_xEng.contains(seg[i + 1].$2)) {
        out[out.length - 1] = (out.last.$1 + _yi + seg[i + 1].$1, out.last.$2);
        skipNext = true;
      } else {
        out.add((word, pos));
      }
    }
    seg = out;
    out = <TaggedWord>[];
    for (final (word, pos) in seg) {
      if (out.isNotEmpty && out.last.$1 == _yi && !_xEng.contains(pos)) {
        out[out.length - 1] = (out.last.$1 + word, out.last.$2);
      } else {
        out.add((word, pos));
      }
    }
    return out;
  }

  List<List<String>> _finalsForMerge(List<TaggedWord> seg) => [
        for (final (word, pos) in seg)
          if (_xEng.contains(pos))
            ['0']
          else
            enFix(word, pinyin.finalsTone3(word))
      ];

  /// misaki's fix after pypinyin 0.44: 嗯 reads n2.
  static List<String> enFix(String word, List<String> finals) {
    final w = pyChars(word);
    for (var i = 0; i < w.length; i++) {
      if (w[i] == '嗯') {
        if (i >= finals.length) throw RangeError.index(i, finals);
        finals[i] = 'n2';
      }
    }
    return finals;
  }

  static bool _isReduplication(String word) {
    final w = pyChars(word);
    return w.length == 2 && w[0] == w[1];
  }

  List<TaggedWord> _mergeThree(List<TaggedWord> seg, {required bool second}) {
    final sub = _finalsForMerge(seg);
    final out = <TaggedWord>[];
    final mergeLast = List<bool>.filled(seg.length, false);
    for (var i = 0; i < seg.length; i++) {
      final (word, pos) = seg[i];
      final bool cond;
      if (_xEng.contains(pos) || i - 1 < 0) {
        cond = false;
      } else if (second) {
        cond = _lastChar(_listLast(sub[i - 1])) == '3' &&
            _lastChar(sub[i][0]) == '3' &&
            !mergeLast[i - 1];
      } else {
        cond = _allToneThree(sub[i - 1]) &&
            _allToneThree(sub[i]) &&
            !mergeLast[i - 1];
      }
      if (cond) {
        if (!_isReduplication(seg[i - 1].$1) &&
            pyLen(seg[i - 1].$1) + pyLen(seg[i].$1) <= 3) {
          out[out.length - 1] = (out.last.$1 + seg[i].$1, out.last.$2);
          mergeLast[i] = true;
        } else {
          out.add((word, pos));
        }
      } else {
        out.add((word, pos));
      }
    }
    return out;
  }

  List<TaggedWord> _mergeEr(List<TaggedWord> seg) {
    final out = <TaggedWord>[];
    for (var i = 0; i < seg.length; i++) {
      final (word, pos) = seg[i];
      if (i - 1 >= 0 && word == '儿' && !_xEng.contains(out.last.$2)) {
        out[out.length - 1] = (out.last.$1 + word, out.last.$2);
      } else {
        out.add((word, pos));
      }
    }
    return out;
  }

  List<TaggedWord> _mergeReduplication(List<TaggedWord> seg) {
    final out = <TaggedWord>[];
    for (final (word, pos) in seg) {
      if (out.isNotEmpty && word == out.last.$1 && !_xEng.contains(pos)) {
        out[out.length - 1] = (out.last.$1 + word, out.last.$2);
      } else {
        out.add((word, pos));
      }
    }
    return out;
  }

  /// `pre_merge_for_modify`, with each step's result passed to [onStep]
  /// when given (for tests that compare the steps).
  List<TaggedWord> preMerge(List<TaggedWord> seg,
      {void Function(String step, List<TaggedWord> seg)? onStep}) {
    seg = _mergeBu(seg);
    onStep?.call('_merge_bu', seg);
    seg = _mergeYi(seg);
    onStep?.call('_merge_yi', seg);
    seg = _mergeReduplication(seg);
    onStep?.call('_merge_reduplication', seg);
    seg = _mergeThree(seg, second: false);
    onStep?.call('_merge_continuous_three_tones', seg);
    seg = _mergeThree(seg, second: true);
    onStep?.call('_merge_continuous_three_tones_2', seg);
    seg = _mergeEr(seg);
    onStep?.call('_merge_er', seg);
    return seg;
  }

  /// `modified_tone`: 不, 一, neutral and third-tone sandhi in that order.
  List<String> modifiedTone(String word, String pos, List<String> finals) {
    finals = _buSandhi(word, finals);
    finals = _yiSandhi(word, finals);
    finals = _neutralSandhi(word, pos, finals);
    finals = _threeSandhi(word, finals);
    return finals;
  }
}

// ---- Python string and list helpers ------------------------------------

String _first(String s) {
  if (s.isEmpty) throw RangeError('string index out of range');
  return pyChars(s).first;
}

/// `s[-1]`, raising on an empty string as Python does.
String _lastChar(String s) {
  if (s.isEmpty) throw RangeError('string index out of range');
  return pyChars(s).last;
}

T _listLast<T>(List<T> l) {
  if (l.isEmpty) throw RangeError('list index out of range');
  return l.last;
}

/// `s[:-1] + tone`.
String _tone(String s, String tone) {
  final c = pyChars(s);
  return (c.isEmpty ? '' : c.sublist(0, c.length - 1).join()) + tone;
}

void _setLast(List<String> finals, String tone) {
  if (finals.isEmpty) throw RangeError('list index out of range');
  finals[finals.length - 1] = _tone(finals.last, tone);
}

String _last2(List<String> chars) =>
    chars.sublist(chars.length >= 2 ? chars.length - 2 : 0).join();

bool _isNumeric(String ch) => ch.runes.every(pyIsNumeric) && ch.isNotEmpty;
