/// A Hugging Face `tokenizer.json` Unigram tokenizer: the Prepend("▁")
/// normalizer, Metaspace words (each starting at a ▁), a Viterbi search
/// over each word, and byte fallback for what no piece covers. This is
/// how Kyutai's Pocket TTS runtime reads text (its configs name the
/// `tokenizers` backend and the `tokenizer.json` beside the weights).
///
/// The rules follow the `tokenizers` library (Apache-2.0):
///  * a position no single-character piece covers gets an unknown node
///    scored at the lowest piece score minus 10 (`kUnkPenalty`);
///  * consecutive unknown characters fuse into one unknown run;
///  * with byte fallback, an unknown run becomes its UTF-8 bytes as
///    `<0xNN>` pieces, when every one of them is in the vocabulary.
///
/// Ids are positions in the vocabulary list. Pure Dart, no file access.
library;

import 'dart:convert';
import 'dart:typed_data';

class UnigramTokenizer {
  final List<String> _pieces;
  final Map<String, int> _idByPiece;
  final Float64List _scores;
  final int unkId;
  final bool byteFallback;
  final int _maxPieceRunes;
  final double _unkScore;

  /// The word-start mark (U+2581), which stands for a space.
  static const space = '▁';

  UnigramTokenizer._(this._pieces, this._idByPiece, this._scores, this.unkId,
      this.byteFallback, this._maxPieceRunes, this._unkScore);

  /// Parses a `tokenizer.json`. Throws [FormatException] when its model
  /// is not Unigram.
  factory UnigramTokenizer.fromJson(String source) {
    final Object? root;
    try {
      root = jsonDecode(source);
    } on FormatException {
      throw const FormatException('Not a tokenizer.json file.');
    }
    final model = root is Map ? root['model'] : null;
    if (model is! Map || model['type'] != 'Unigram') {
      throw const FormatException('Not a Unigram tokenizer.');
    }
    final vocab = model['vocab'];
    if (vocab is! List || vocab.isEmpty) {
      throw const FormatException('A Unigram tokenizer with no vocabulary.');
    }
    final pieces = <String>[];
    final ids = <String, int>{};
    final scores = Float64List(vocab.length);
    var maxRunes = 1;
    var minScore = double.infinity;
    for (var i = 0; i < vocab.length; i++) {
      final entry = vocab[i] as List;
      final piece = entry[0] as String;
      final score = (entry[1] as num).toDouble();
      pieces.add(piece);
      ids.putIfAbsent(piece, () => i);
      scores[i] = score;
      if (score < minScore) minScore = score;
      final runes = piece.runes.length;
      if (runes > maxRunes) maxRunes = runes;
    }
    return UnigramTokenizer._(
      pieces,
      ids,
      scores,
      (model['unk_id'] as int?) ?? 0,
      model['byte_fallback'] == true,
      maxRunes,
      minScore - 10.0,
    );
  }

  int get vocabSize => _scores.length;

  /// The ids for [text], as `tokenizer.encode(text).ids` gives them.
  List<int> encode(String text) {
    if (text.isEmpty) return const [];
    final normalized = '$space$text'.replaceAll(' ', space);
    final out = <int>[];
    for (final word in _words(normalized)) {
      _encodeWord(word, out);
    }
    return out;
  }

  /// The text for [ids], as `tokenizer.decode(ids)` gives it: each ▁
  /// becomes a space and the first piece drops one leading space
  /// (Metaspace); runs of `<0xNN>` pieces join into UTF-8, each byte of
  /// an invalid run becoming U+FFFD (ByteFallback); then all are joined
  /// (Fuse).
  String decode(List<int> ids) {
    final out = StringBuffer();
    final bytes = <int>[];
    void flush() {
      if (bytes.isEmpty) return;
      try {
        out.write(utf8.decode(bytes));
      } on FormatException {
        out.write('\uFFFD' * bytes.length);
      }
      bytes.clear();
    }

    for (var i = 0; i < ids.length; i++) {
      final id = ids[i];
      var piece = id >= 0 && id < _pieces.length ? _pieces[id] : '';
      final byte = _bytePiece.firstMatch(piece);
      if (byte != null) {
        bytes.add(int.parse(byte[1]!, radix: 16));
        continue;
      }
      flush();
      piece = piece.replaceAll(space, ' ');
      if (i == 0 && piece.startsWith(' ')) piece = piece.substring(1);
      out.write(piece);
    }
    flush();
    return out.toString();
  }

  static final _bytePiece = RegExp(r'^<0x([0-9A-Fa-f]{2})>$');

  /// Metaspace with `split: true`: a new word starts at every ▁.
  static Iterable<List<int>> _words(String s) sync* {
    final runes = s.runes.toList();
    final mark = space.runes.single;
    var start = 0;
    for (var i = 1; i < runes.length; i++) {
      if (runes[i] == mark) {
        yield runes.sublist(start, i);
        start = i;
      }
    }
    yield runes.sublist(start);
  }

  void _encodeWord(List<int> cps, List<int> out) {
    final n = cps.length;
    final best = Float64List(n + 1)..fillRange(1, n + 1, double.negativeInfinity);
    final back = Int32List(n + 1);
    final pieceAt = Int32List(n + 1); // id, or -1 for an unknown char
    for (var start = 0; start < n; start++) {
      if (best[start] == double.negativeInfinity) continue;
      var single = false;
      final limit = start + _maxPieceRunes < n ? start + _maxPieceRunes : n;
      for (var end = start + 1; end <= limit; end++) {
        final id = _idByPiece[String.fromCharCodes(cps, start, end)];
        if (id == null) continue;
        if (end == start + 1) single = true;
        final total = best[start] + _scores[id];
        if (total > best[end]) {
          best[end] = total;
          back[end] = start;
          pieceAt[end] = id;
        }
      }
      if (!single) {
        final total = best[start] + _unkScore;
        if (total > best[start + 1]) {
          best[start + 1] = total;
          back[start + 1] = start;
          pieceAt[start + 1] = -1;
        }
      }
    }
    // Backtrace into (start, end, id) spans, then fuse unknown runs.
    final spans = <(int, int, int)>[];
    for (var pos = n; pos > 0; pos = back[pos]) {
      spans.add((back[pos], pos, pieceAt[pos]));
    }
    var i = spans.length - 1;
    while (i >= 0) {
      final (start, end, id) = spans[i];
      if (id >= 0) {
        out.add(id);
        i--;
        continue;
      }
      var runEnd = end;
      i--;
      while (i >= 0 && spans[i].$3 < 0) {
        runEnd = spans[i].$2;
        i--;
      }
      _unknown(String.fromCharCodes(cps, start, runEnd), out);
    }
  }

  void _unknown(String run, List<int> out) {
    if (byteFallback) {
      final bytes = utf8.encode(run);
      final ids = <int>[];
      for (final b in bytes) {
        final id = _idByPiece[
            '<0x${b.toRadixString(16).toUpperCase().padLeft(2, '0')}>'];
        if (id == null) break;
        ids.add(id);
      }
      if (ids.length == bytes.length) {
        out.addAll(ids);
        return;
      }
    }
    out.add(unkId);
  }
}
