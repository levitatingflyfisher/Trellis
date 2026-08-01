/// The reader's pure projections — no widgets, no storage.
///
/// - [orpIndex]: the donor ORP pivot heuristic (ohPrimer `getORP`).
/// - [cursorAt] / [globalWordIndex]: the cursor law's two directions
///   (ADR-0002). A persisted [Position] is (segmentIdx, wordIdx); the word
///   stream a renderer paces through is a flat global index. These convert
///   between the two so every mode reads and writes the same row.
/// - [msPerWord]: punctuation dwell (donor `step`: 60000/wpm × pacing).
library;

import 'package:loom_core/loom_core.dart';

/// Optimal-recognition-point pivot for RSVP (donor `getORP`,
/// index.html:2438): `n<=1?0 : n<=5?1 : n<=9?2 : 3`.
int orpIndex(String word) {
  final n = word.length;
  return n <= 1
      ? 0
      : n <= 5
          ? 1
          : n <= 9
              ? 2
              : 3;
}

/// Global word index → (segment block position, word offset within it).
///
/// Word ranges `[blockStart, nextBlockStart)` partition the stream, so
/// exactly one block owns each word — never a heading (headings emit no
/// words). Out-of-range indices clamp to the stream.
({int segment, int word}) cursorAt(TokenizedDocument doc, int globalWordIdx) {
  assert(doc.words.isNotEmpty, 'cursorAt needs a non-empty word stream');
  final starts = doc.blockStartWordIdx;
  final w = globalWordIdx.clamp(0, doc.words.length - 1);
  for (var bi = 0; bi < starts.length; bi++) {
    final start = starts[bi];
    final end = bi + 1 < starts.length ? starts[bi + 1] : doc.words.length;
    if (w >= start && w < end) return (segment: bi, word: w - start);
  }
  // Unreachable while the ranges partition the stream; be safe anyway.
  return (segment: starts.length - 1, word: 0);
}

/// (segmentIdx, wordIdx) → global word index; the inverse of [cursorAt].
///
/// A stale wordIdx clamps inside its segment; a word-less segment (heading)
/// falls forward to the first word at or after its start, so a restored
/// position never strands the reader on nothing.
int globalWordIndex(TokenizedDocument doc, int segment, int word) {
  if (doc.words.isEmpty) return 0;
  final starts = doc.blockStartWordIdx;
  final bi = segment.clamp(0, starts.length - 1);
  final start = starts[bi];
  final end = bi + 1 < starts.length ? starts[bi + 1] : doc.words.length;
  if (end <= start) return start.clamp(0, doc.words.length - 1);
  return (start + word).clamp(start, end - 1);
}

/// Display time for one word (donor `step`): base 60000/wpm ms scaled by the
/// tokenizer's per-word pacing weight (sentence end 1.7, clause 1.2, …).
int msPerWord(double wpm, double pacing) => (60000 / wpm * pacing).round();

final _edgePunctuationRe =
    RegExp(r'^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$', unicode: true);

/// What the word ledger stores for a long-pressed display token: edge
/// punctuation and quotes stripped, insides kept (don't, mother-in-law) —
/// the ledger holds words, not typography. Null when nothing wordy remains
/// (the tokenizer's `…` placeholder, bare punctuation), so callers add
/// nothing rather than junk.
String? ledgerWord(String token) {
  final w = token.replaceAll(_edgePunctuationRe, '');
  return w.isEmpty ? null : w;
}
