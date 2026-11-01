/// jieba's word cutting: the dictionary DAG, the max-probability route,
/// the HMM for runs the dictionary does not know, `cut_for_search`, and
/// `posseg.lcut` (cutting with part-of-speech tags). Ported from jieba
/// 0.42.1 (github.com/fxsjy/jieba, `__init__.py`, `posseg/__init__.py`),
/// MIT License, Copyright (c) 2013 Sun Junyi.
///
/// Only the paths misaki uses are here: `cut(s)` with HMM on (accurate
/// mode) and `posseg.lcut(s)` with HMM on. Indices count code points, as
/// Python's do.
library;

import 'dart:math' as math;

import 'jieba_dict.dart';
import 'jieba_hmm.dart';

/// A word and its jieba part-of-speech tag.
typedef TaggedWord = (String word, String tag);

class Jieba {
  Jieba(this.dict, this.finalseg, this.posseg)
      : _logTotal = math.log(dict.total.toDouble());

  final JiebaDict dict;
  final FinalsegHmm finalseg;
  final PossegHmm posseg;
  final double _logTotal;

  // re_han_default: [一-鿕a-zA-Z0-9+#&\._%\-]
  static bool _isHanDefault(int c) =>
      _isHanInternal(c) || c == 0x25 /* % */ || c == 0x2D /* - */;

  // re_han_internal (posseg): [一-鿕a-zA-Z0-9+#&\._]
  static bool _isHanInternal(int c) =>
      (c >= 0x4E00 && c <= 0x9FD5) ||
      _isAlnum(c) ||
      c == 0x2B ||
      c == 0x23 ||
      c == 0x26 ||
      c == 0x2E ||
      c == 0x5F;

  // re_han_detail / finalseg's re_han: [一-鿕]
  static bool _isHanOnly(int c) => c >= 0x4E00 && c <= 0x9FD5;

  static bool _isAlnum(int c) =>
      (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x5A) ||
      (c >= 0x61 && c <= 0x7A);

  static bool _isDigitOrDot(int c) => (c >= 0x30 && c <= 0x39) || c == 0x2E;

  /// Splits [s] into runs inside and outside a character class, as
  /// `re.split('([class]+)', s)` does (empty pieces are not kept; no
  /// caller here uses them).
  static List<(List<int>, bool)> _runs(List<int> s, bool Function(int) inside) {
    final out = <(List<int>, bool)>[];
    var i = 0;
    while (i < s.length) {
      final kind = inside(s[i]);
      var j = i + 1;
      while (j < s.length && inside(s[j]) == kind) {
        j++;
      }
      out.add((s.sublist(i, j), kind));
      i = j;
    }
    return out;
  }

  /// Non-Han blocks: re_skip `(\r\n|\s)` splits whitespace one character
  /// at a time (\r\n together), and the rest yields one character at a
  /// time; so every code point is its own piece but \r\n.
  static List<String> _skipPieces(List<int> blk) {
    final out = <String>[];
    for (var i = 0; i < blk.length; i++) {
      if (blk[i] == 0x0D && i + 1 < blk.length && blk[i + 1] == 0x0A) {
        out.add('\r\n');
        i++;
      } else {
        out.add(String.fromCharCode(blk[i]));
      }
    }
    return out;
  }

  /// `get_DAG` and `calc`: for each start, the best end (inclusive).
  List<int> _route(List<int> s) {
    final n = s.length;
    final dagEnds = List<List<int>>.filled(n, const []);
    final dagFreq = List<List<int>>.filled(n, const []);
    for (var k = 0; k < n; k++) {
      final ends = <int>[];
      final freqs = <int>[];
      var lo = 0;
      var hi = dict.length;
      var i = k;
      // while i < N and frag in FREQ
      while (i < n) {
        final r = dict.narrow(lo, hi, i - k, s[i]);
        lo = r.$1;
        hi = r.$2;
        if (lo >= hi) break; // frag is no prefix of any word
        if (dict.hasLength(lo, i - k + 1) && dict.freqAt(lo) != 0) {
          ends.add(i);
          freqs.add(dict.freqAt(lo));
        }
        i++;
      }
      if (ends.isEmpty) {
        ends.add(k);
        freqs.add(1); // FREQ.get(char) is missing or 0: `or 1`
      }
      dagEnds[k] = ends;
      dagFreq[k] = freqs;
    }
    final routeP = List<double>.filled(n + 1, 0);
    final routeX = List<int>.filled(n + 1, 0);
    for (var idx = n - 1; idx >= 0; idx--) {
      double? best;
      var bestX = -1;
      final ends = dagEnds[idx];
      final freqs = dagFreq[idx];
      for (var j = 0; j < ends.length; j++) {
        final x = ends[j];
        final f = freqs[j] == 0 ? 1 : freqs[j];
        final p = math.log(f.toDouble()) - _logTotal + routeP[x + 1];
        if (best == null || p > best || (p == best && x > bestX)) {
          best = p;
          bestX = x;
        }
      }
      routeP[idx] = best!;
      routeX[idx] = bestX;
    }
    return routeX;
  }

  /// `jieba.lcut(sentence)`: accurate mode with the HMM.
  List<String> cut(String sentence) {
    final out = <String>[];
    for (final (blk, han) in _runs(sentence.runes.toList(), _isHanDefault)) {
      if (han) {
        out.addAll(_cutDag(blk));
      } else {
        out.addAll(_skipPieces(blk));
      }
    }
    return out;
  }

  List<String> _cutDag(List<int> s) {
    final route = _route(s);
    final out = <String>[];
    var x = 0;
    final n = s.length;
    var buf = <int>[];
    void flush() {
      if (buf.length == 1) {
        out.add(String.fromCharCodes(buf));
      } else if (dict.freqOf(String.fromCharCodes(buf)) == 0) {
        out.addAll(_finalsegCut(buf));
      } else {
        for (final c in buf) {
          out.add(String.fromCharCode(c));
        }
      }
      buf = <int>[];
    }

    while (x < n) {
      final y = route[x] + 1;
      if (y - x == 1) {
        buf.add(s[x]);
      } else {
        if (buf.isNotEmpty) flush();
        out.add(String.fromCharCodes(s, x, y));
      }
      x = y;
    }
    if (buf.isNotEmpty) flush();
    return out;
  }

  // finalseg.cut: Han runs through the HMM; other runs split by
  // re_skip "([a-zA-Z0-9]+(?:\.\d+)?%?)".
  List<String> _finalsegCut(List<int> s) {
    final out = <String>[];
    for (final (blk, han) in _runs(s, _isHanOnly)) {
      if (han) {
        out.addAll(finalseg.cutHan(blk));
      } else {
        out.addAll(_reSkipFinalseg(blk));
      }
    }
    return out;
  }

  static final RegExp _finalsegSkip = RegExp(r'[a-zA-Z0-9]+(?:\.\d+)?%?');

  static List<String> _reSkipFinalseg(List<int> blk) {
    final str = String.fromCharCodes(blk);
    final out = <String>[];
    var last = 0;
    for (final m in _finalsegSkip.allMatches(str)) {
      if (m.start > last) out.add(str.substring(last, m.start));
      out.add(m[0]!);
      last = m.end;
    }
    if (last < str.length) out.add(str.substring(last));
    return out;
  }

  /// `jieba.lcut_for_search(sentence)` with the HMM.
  List<String> cutForSearch(String sentence) {
    final out = <String>[];
    for (final w in cut(sentence)) {
      final r = w.runes.toList();
      if (r.length > 2) {
        for (var i = 0; i < r.length - 1; i++) {
          final g = String.fromCharCodes(r, i, i + 2);
          if (dict.freqOf(g) != 0) out.add(g);
        }
      }
      if (r.length > 3) {
        for (var i = 0; i < r.length - 2; i++) {
          final g = String.fromCharCodes(r, i, i + 3);
          if (dict.freqOf(g) != 0) out.add(g);
        }
      }
      out.add(w);
    }
    return out;
  }

  /// `jieba.posseg.lcut(sentence)` with the HMM.
  List<TaggedWord> posCut(String sentence) {
    final out = <TaggedWord>[];
    for (final (blk, han) in _runs(sentence.runes.toList(), _isHanInternal)) {
      if (han) {
        out.addAll(_posCutDag(blk));
      } else {
        // Every piece of a non-Han block is tagged x: re_num and re_eng
        // need characters that would have been inside the Han block.
        for (final p in _skipPieces(blk)) {
          out.add((p, 'x'));
        }
      }
    }
    return out;
  }

  List<TaggedWord> _posCutDag(List<int> s) {
    final route = _route(s);
    final out = <TaggedWord>[];
    var x = 0;
    final n = s.length;
    var buf = <int>[];
    void flush() {
      final b = String.fromCharCodes(buf);
      if (buf.length == 1) {
        out.add((b, dict.tagOf(b)));
      } else if (dict.freqOf(b) == 0) {
        out.addAll(_cutDetail(buf));
      } else {
        for (final c in buf) {
          final e = String.fromCharCode(c);
          out.add((e, dict.tagOf(e)));
        }
      }
      buf = <int>[];
    }

    while (x < n) {
      final y = route[x] + 1;
      if (y - x == 1) {
        buf.add(s[x]);
      } else {
        if (buf.isNotEmpty) flush();
        final w = String.fromCharCodes(s, x, y);
        out.add((w, dict.tagOf(w)));
      }
      x = y;
    }
    if (buf.isNotEmpty) flush();
    return out;
  }

  static final RegExp _detailSkip = RegExp(r'[\.0-9]+|[a-zA-Z0-9]+');

  // posseg's __cut_detail.
  List<TaggedWord> _cutDetail(List<int> s) {
    final out = <TaggedWord>[];
    for (final (blk, han) in _runs(s, _isHanOnly)) {
      if (han) {
        out.addAll(posseg.cutHan(blk));
        continue;
      }
      final str = String.fromCharCodes(blk);
      final pieces = <String>[];
      var last = 0;
      for (final m in _detailSkip.allMatches(str)) {
        if (m.start > last) pieces.add(str.substring(last, m.start));
        pieces.add(m[0]!);
        last = m.end;
      }
      if (last < str.length) pieces.add(str.substring(last));
      for (final x in pieces) {
        final c = x.codeUnitAt(0);
        if (_isDigitOrDot(c)) {
          out.add((x, 'm'));
        } else if (_isAlnum(c)) {
          out.add((x, 'eng'));
        } else {
          out.add((x, 'x'));
        }
      }
    }
    return out;
  }
}
