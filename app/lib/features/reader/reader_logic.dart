/// The reader's pure projections — no widgets, no storage.
///
/// - [orpIndex]: the donor ORP pivot heuristic (ohPrimer `getORP`).
/// - [cursorAt] / [globalWordIndex]: the cursor law's two directions
///   (ADR-0002). A persisted [Position] is (segmentIdx, wordIdx); the word
///   stream a renderer paces through is a flat global index. These convert
///   between the two so every mode reads and writes the same row.
/// - [msPerWord]: punctuation dwell (donor `step`: 60000/wpm × pacing).
library;

import 'dart:math' as math;

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

/// Campaign 9 Phase 7 ("the reader follows the player"): an audio time →
/// this reader's own global word cursor, through the SAME
/// `Spine.positionAtAudioTime` mapping `karaoke_screen.dart` already uses.
/// [positionAtAudioTime] answers in the DATABASE's own segment idx — never
/// the [blocks] LIST position [cursorAt]/[globalWordIndex] work in
/// (`_load`'s own restore-a-saved-Position code performs the identical
/// `blocks.indexWhere` translation, not `blocks[idx]`) — so this repeats
/// that lookup rather than assuming the two coincide.
///
/// Null means there is nothing to follow onto: no alignments at all, an
/// empty document, or a projected segment [blocks] has no entry for (the
/// work's alignments outrun what this reader currently has tokenized —
/// should not happen in practice, but a caller must never crash on it).
int? wordIndexAtAudioTime({
  required Spine spine,
  required TokenizedDocument doc,
  required List<Segment> blocks,
  required int audioTimeMs,
}) {
  if (spine.alignments.isEmpty || doc.words.isEmpty) return null;
  final pos = spine.positionAtAudioTime(audioTimeMs);
  final blockPos = blocks.indexWhere((b) => b.idx == pos.segmentIdx);
  if (blockPos < 0) return null;
  return globalWordIndex(doc, blockPos, pos.wordIdx);
}

// ───── Campaign 4 Phase 2: the lost priming visuals ─────
//
// Donor: OpenHearth/ohPrimer index.html. Parafoveal mode is the donor's
// "ticker" mode (index.html:2674-2699); the app's own "ticker" test
// vocabulary already names the EXISTING RSVP mode, so the public name here
// is always Parafoveal, never ticker.

/// The donor's neighbor-fade curve (`gauss`, index.html:2439):
/// `exp(-(d*d)/(2*s*s))`. Distance is measured absolute — sign never
/// matters, only how far a neighbor sits from the focus word.
double _gauss(num d, double sigma) {
  final dist = d.abs();
  return math.exp(-(dist * dist) / (2 * sigma * sigma));
}

/// A parafoveal neighbor's opacity at [dist] words from the focus, floored
/// at the donor's 0.01 so nothing fully vanishes (`Math.max(0.01,
/// gauss(dist,sigma))`, index.html:2680). Default sigma 2.0 matches the
/// donor default; the settings slider (0.8-4.0 step 0.2) feeds this same
/// parameter live.
double gaussianOpacity(num dist, double sigma) =>
    math.max(0.01, _gauss(dist, sigma));

/// A parafoveal neighbor's scale at [dist] words from the focus (donor
/// `0.85 + 0.15*gauss(dist,sigma)`, index.html:2681): full size at the
/// focus, settling toward 0.85x for distant neighbors.
double gaussianScale(num dist, double sigma) =>
    0.85 + 0.15 * _gauss(dist, sigma);

/// A parafoveal neighbor's blur radius, px, at [dist] words from the focus
/// (donor `dist>sigma*1.5 ? min(2,(dist-sigma)*0.7) : 0`, index.html:2682):
/// neighbors close enough to read stay crisp; only the ones already faded
/// past readability blur, capped at 2px.
double gaussianBlurRadius(num dist, double sigma) {
  final d = dist.abs();
  if (d <= sigma * 1.5) return 0.0;
  return math.min(2.0, (d - sigma) * 0.7);
}

/// The classic-mode ORP anchor fix (donor index.html:2662-2666): the
/// before-pivot span reserves `charWidth * orp` px as a MINIMUM width
/// regardless of the actual glyphs it renders (`cw = fontSize*0.6` is the
/// donor's monospace-char-width estimate; this reader keeps its own body
/// face, so callers pass their own measured/estimated width). Two words
/// sharing an ORP bucket (see [orpIndex]) then reserve the identical
/// before-span width, removing the glyph-width jitter that used to move
/// the pivot when `_rsvpWord` simply centered the whole word. This is a
/// reservation, not a perfect 50%-anchor for every word: the AFTER span is
/// still free-width (as the donor's is too), so very different word
/// lengths can still shift the row's overall center slightly — the fix
/// removes the before-side jitter the donor's CSS targets, no more.
double orpBeforeReserve(String word, double charWidth) =>
    charWidth * orpIndex(word);

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

// ───── Campaign 4 Phase 4: session recaps ─────

/// The "Catch me up?" offer's own trigger, kept pure and separate from
/// wherever it gets read (epoch-day arithmetic, not `DateTime.difference`,
/// which follows local wall-clock rather than the fleet's UTC-day
/// convention `ReadingDays`/`firstSeenEpochDay` already use).
///
/// A null [lastTouchedEpochDay] (no [Position] row yet) and a finished
/// work (`progress >= 1.0` — nothing left to catch up on) both offer
/// nothing, same as barely-started progress.
bool shouldOfferRecap({
  required int? lastTouchedEpochDay,
  required int todayEpochDay,
  required double progress,
}) {
  if (lastTouchedEpochDay == null) return false;
  if (progress <= 0.10 || progress >= 1.0) return false;
  return todayEpochDay - lastTouchedEpochDay > 3;
}

/// The recap prompt's own privacy law, kept testable in isolation from the
/// Brain call that uses it: only segments strictly BEFORE
/// [currentSegmentIdx] (the DB segment idx a [Position] points at, same
/// units `_savePosition`'s `blocks[c.segment].idx` writes) are ever joined
/// into the source text — nothing at or after the reader's own cursor can
/// reach the model, so a recap can never spoil what's still unread. Blank
/// segments (headings with no body) are skipped rather than joined as
/// empty lines, matching `DistillScreen._run`'s own source-assembly rule.
String preCursorText(
    List<({int idx, String body})> segments, int currentSegmentIdx) {
  return [
    for (final s in segments)
      if (s.idx < currentSegmentIdx && s.body.trim().isNotEmpty) s.body
  ].join('\n\n');
}
