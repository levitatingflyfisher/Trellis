/// Long text into the chunks Pocket TTS says one at a time: Kyutai's
/// `split_into_best_sentences` (pocket-tts 4.0.1,
/// pocket_tts/models/text_chunking.py), ported. The model was trained on
/// single sentences, so a long input is split at sentence ends, an
/// over-long sentence at commas, semicolons and colons, and the pieces
/// are regrouped into chunks of at most [pocketMaxTokensPerChunk]
/// tokens. Boundaries are found on token ids and the pieces decoded back
/// to text, as Kyutai does, so a decimal point ("3.14") never ends a
/// sentence.
library;

import 'package:ml_runtime/ml_runtime.dart' show UnigramTokenizer;

import 'pocket_text.dart';

/// `MAX_TOKEN_PER_CHUNK` (default_parameters.py).
const pocketMaxTokensPerChunk = 50;

List<String> splitPocketChunks(
    UnigramTokenizer tok, String text, PocketLanguage lang,
    {int maxTokens = pocketMaxTokensPerChunk}) {
  final prepared = preparePocketText(text, lang).text.trim();
  final tokens = tok.encode(prepared);
  final sentenceEnds = tok.encode('.!...?').skip(1).toSet();
  final sentences = _segments(
      tok, tokens, _boundaries(tok, tokens, sentenceEnds, skipDecimal: true));

  final weak = tok.encode(',;:').skip(1).toSet();
  final refined = <(int, String)>[];
  for (final (n, s) in sentences) {
    if (n <= maxTokens) {
      refined.add((n, s));
      continue;
    }
    final sub = tok.encode(s.trim());
    final parts = _segments(tok, sub, _boundaries(tok, sub, weak));
    refined.addAll(parts.length > 1 ? parts : [(n, s)]);
  }

  final chunks = <String>[];
  var current = '';
  var count = 0;
  for (final (n, s) in refined) {
    if (current.isEmpty) {
      current = s;
      count = n;
    } else if (count + n > maxTokens) {
      chunks.add(current.trim());
      current = s;
      count = n;
    } else {
      current += ' $s';
      count += n;
    }
  }
  if (current.isNotEmpty) chunks.add(current.trim());
  return chunks;
}

/// `_find_boundary_indices`: where each segment starts, plus the end.
List<int> _boundaries(UnigramTokenizer tok, List<int> tokens, Set<int> marks,
    {bool skipDecimal = false}) {
  final out = [0];
  var previousWasMark = false;
  for (var i = 0; i < tokens.length; i++) {
    if (marks.contains(tokens[i])) {
      previousWasMark = true;
      continue;
    }
    if (previousWasMark) {
      if (skipDecimal && _decimalPoint(tok, tokens, i)) {
        previousWasMark = false;
        continue;
      }
      out.add(i);
    }
    previousWasMark = false;
  }
  out.add(tokens.length);
  return out;
}

/// `_is_decimal_period_boundary`: a period between two digits.
bool _decimalPoint(UnigramTokenizer tok, List<int> tokens, int i) {
  final prefix = tok.decode(tokens.sublist(0, i));
  final suffix = tok.decode(tokens.sublist(i));
  return prefix.length >= 2 &&
      prefix[prefix.length - 1] == '.' &&
      _isDigit(prefix[prefix.length - 2]) &&
      suffix.isNotEmpty &&
      _isDigit(suffix[0]);
}

bool _isDigit(String c) => RegExp(r'^\p{Nd}$', unicode: true).hasMatch(c);

/// `_segments_from_boundaries`: (token count, decoded text) pairs.
List<(int, String)> _segments(
        UnigramTokenizer tok, List<int> tokens, List<int> bounds) =>
    [
      for (var i = 0; i + 1 < bounds.length; i++)
        (
          bounds[i + 1] - bounds[i],
          tok.decode(tokens.sublist(bounds[i], bounds[i + 1]))
        ),
    ];
