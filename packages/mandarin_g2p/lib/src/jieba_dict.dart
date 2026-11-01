/// jieba's main dictionary (`dict.txt`: word, frequency, part-of-speech
/// tag per line) held compactly: the words in a [SortedWords] table with
/// parallel arrays for frequency and tag.
///
/// jieba itself keeps a Python dict of every word and every prefix of
/// every word (prefixes with frequency 0). A prefix test here is a
/// narrowing binary search over the sorted words instead; the answers
/// are the same.
///
/// From jieba 0.42.1 (github.com/fxsjy/jieba), MIT License,
/// Copyright (c) 2013 Sun Junyi.
library;

import 'dart:typed_data';

import 'sorted_words.dart';

class JiebaDict {
  JiebaDict._(this._words, this._freq, this._tag, this.tags, this.total);

  /// Parses jieba's dict.txt text. A first line starting with `#` is a
  /// header and is skipped. As in jieba, a word listed twice keeps its
  /// last frequency and tag, and [total] counts every line.
  factory JiebaDict.parse(String text) {
    final words = <String>[];
    final freqs = <int>[];
    final tagIds = <int>[];
    final tags = <String>[];
    final tagIndex = <String, int>{};
    var total = 0;
    var pos = 0;
    final n = text.length;
    if (n > 0 && text.codeUnitAt(0) == 0x23) {
      final nl = text.indexOf('\n');
      pos = nl < 0 ? n : nl + 1;
    }
    while (pos < n) {
      var end = text.indexOf('\n', pos);
      if (end < 0) end = n;
      var e = end;
      if (e > pos && text.codeUnitAt(e - 1) == 0x0D) e--;
      if (e > pos) {
        final sp1 = text.indexOf(' ', pos);
        if (sp1 < 0 || sp1 >= e) {
          throw FormatException('jieba dict line without frequency', text, pos);
        }
        var sp2 = text.indexOf(' ', sp1 + 1);
        if (sp2 < 0 || sp2 > e) sp2 = e;
        final f = int.parse(text.substring(sp1 + 1, sp2));
        final tag = sp2 < e ? text.substring(sp2 + 1, e) : '';
        words.add(text.substring(pos, sp1));
        freqs.add(f);
        tagIds.add(tagIndex.putIfAbsent(tag, () {
          tags.add(tag);
          return tags.length - 1;
        }));
        total += f;
      }
      pos = end + 1;
    }
    if (tags.length > 256) throw const FormatException('too many tags');
    final (table, source) = SortedWords.build(words);
    final freq = Int32List(table.length);
    final tag = Uint8List(table.length);
    for (var w = 0; w < table.length; w++) {
      freq[w] = freqs[source[w]];
      tag[w] = tagIds[source[w]];
    }
    return JiebaDict._(table, freq, tag, tags, total);
  }

  final SortedWords _words;
  final Int32List _freq;
  final Uint8List _tag;

  /// Every distinct tag, indexed by the tag ids.
  final List<String> tags;

  /// The sum of every frequency in the file.
  final int total;

  int get length => _words.length;

  /// jieba's `FREQ.get(word)`, with 0 for a word that is missing (jieba
  /// stores prefixes as 0 and treats both alike).
  int freqOf(String word) {
    final i = _words.indexOf(word);
    return i < 0 ? 0 : _freq[i];
  }

  /// jieba's `word_tag_tab.get(word, 'x')`.
  String tagOf(String word) {
    final i = _words.indexOf(word);
    return i < 0 ? 'x' : tags[_tag[i]];
  }

  /// See [SortedWords.narrow].
  (int, int) narrow(int lo, int hi, int depth, int c) =>
      _words.narrow(lo, hi, depth, c);

  /// Whether word [w] has exactly [len] characters.
  bool hasLength(int w, int len) => _words.hasLength(w, len);

  /// The frequency of word [w].
  int freqAt(int w) => _freq[w];
}
