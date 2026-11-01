/// A sorted word list in one [Uint16List], for the two big tables (jieba's
/// 350,000 words, pypinyin's 47,000 phrases). It answers the two questions
/// both libraries ask of their Python dicts, "is this a word?" and "is
/// this the start of some word?", by binary search, without a String or
/// a hash entry per word or per prefix.
library;

import 'dart:typed_data';

class SortedWords {
  SortedWords._(this._chars, this._starts);

  /// Sorts [words] by UTF-16 code unit. When a word appears more than
  /// once the last one is kept, as a Python dict keeps the last value.
  /// Returns the table and, for each word in it, the index in [words] it
  /// came from.
  static (SortedWords, Int32List) build(List<String> words) {
    final order = List<int>.generate(words.length, (i) => i)
      ..sort((a, b) {
        final c = words[a].compareTo(words[b]);
        return c != 0 ? c : a - b;
      });
    final keep = <int>[];
    for (var k = 0; k < order.length; k++) {
      if (k + 1 < order.length && words[order[k]] == words[order[k + 1]]) {
        continue;
      }
      keep.add(order[k]);
    }
    var total = 0;
    for (final k in keep) {
      total += words[k].length;
    }
    final chars = Uint16List(total);
    final starts = Int32List(keep.length + 1);
    var c = 0;
    for (var w = 0; w < keep.length; w++) {
      starts[w] = c;
      final s = words[keep[w]];
      for (var i = 0; i < s.length; i++) {
        chars[c++] = s.codeUnitAt(i);
      }
    }
    starts[keep.length] = c;
    return (SortedWords._(chars, starts), Int32List.fromList(keep));
  }

  final Uint16List _chars;
  final Int32List _starts;

  int get length => _starts.length - 1;

  int _len(int w) => _starts[w + 1] - _starts[w];

  /// The index of [word], or -1.
  int indexOf(String word) {
    var lo = 0;
    var hi = length;
    for (var d = 0; d < word.length && lo < hi; d++) {
      final c = word.codeUnitAt(d);
      lo = _lower(lo, hi, d, c);
      hi = _upper(lo, hi, d, c);
    }
    if (lo < hi && _len(lo) == word.length) return lo;
    return -1;
  }

  /// One step of a prefix walk: from the range [lo, hi) of words sharing
  /// their first [depth] code units, the range whose next unit is [c].
  /// An empty range means no word starts that way. The range's first
  /// word is the prefix itself when [hasLength] says so, since a word
  /// sorts before every longer word it starts.
  (int, int) narrow(int lo, int hi, int depth, int c) {
    final a = _lower(lo, hi, depth, c);
    return (a, _upper(a, hi, depth, c));
  }

  /// Whether word [w] has exactly [len] code units.
  bool hasLength(int w, int len) => _len(w) == len;

  // The key of word w at depth d: -1 when the word ends there, so
  // shorter words sort first, as they do.
  int _key(int w, int d) => d < _len(w) ? _chars[_starts[w] + d] : -1;

  int _lower(int lo, int hi, int d, int c) {
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_key(mid, d) < c) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  int _upper(int lo, int hi, int d, int c) {
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_key(mid, d) <= c) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}
