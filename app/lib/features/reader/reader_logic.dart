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
/// this reader's own global word cursor, through `Spine
/// .positionAtAudioTime` for the segment and, within it (1.5.8, the
/// transcript view's word-by-word motion), [localWordAtAudioTime] over
/// that segment's [wordTimings] — `[word, t0, t1]` rows keyed by DB
/// segment idx. [wordLevel] false keeps the cursor at the segment's start:
/// a translation shown in place has no word timings of its own.
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
  Map<int, List<List<Object>>> wordTimings = const {},
  bool wordLevel = true,
}) {
  if (spine.alignments.isEmpty || doc.words.isEmpty) return null;
  final pos = spine.positionAtAudioTime(audioTimeMs);
  final blockPos = blocks.indexWhere((b) => b.idx == pos.segmentIdx);
  if (blockPos < 0) return null;
  if (!wordLevel) return globalWordIndex(doc, blockPos, 0);
  final starts = doc.blockStartWordIdx;
  final end =
      blockPos + 1 < starts.length ? starts[blockPos + 1] : doc.words.length;
  final aligned =
      spine.alignments.firstWhere((a) => a.segmentIdx == pos.segmentIdx);
  final local = localWordAtAudioTime(
      audioTimeMs: audioTimeMs,
      segStartMs: aligned.tStartMs,
      segEndMs: aligned.tEndMs,
      stamps: wordTimings[pos.segmentIdx] ?? const [],
      tokens: doc.words.sublist(starts[blockPos], end));
  return globalWordIndex(doc, blockPos, local);
}

/// The inverse of [wordIndexAtAudioTime], for a tapped word: the time
/// [tokenStartTimes] gives it, or the segment's start for a translation
/// shown in place. Null when the word's segment has no alignment.
int? audioTimeOfWord({
  required Spine spine,
  required TokenizedDocument doc,
  required List<Segment> blocks,
  required int globalIdx,
  Map<int, List<List<Object>>> wordTimings = const {},
  bool wordLevel = true,
}) {
  if (doc.words.isEmpty) return null;
  final c = cursorAt(doc, globalIdx.clamp(0, doc.words.length - 1));
  final segIdx = blocks[c.segment].idx;
  Alignment? aligned;
  for (final a in spine.alignments) {
    if (a.segmentIdx == segIdx) aligned = a;
  }
  if (aligned == null) return null;
  if (!wordLevel) return aligned.tStartMs;
  final starts = doc.blockStartWordIdx;
  final end = c.segment + 1 < starts.length
      ? starts[c.segment + 1]
      : doc.words.length;
  final times = tokenStartTimes(
      tokens: doc.words.sublist(starts[c.segment], end),
      segStartMs: aligned.tStartMs,
      segEndMs: aligned.tEndMs,
      stamps: wordTimings[segIdx] ?? const []);
  return times[c.word.clamp(0, times.length - 1)];
}

/// Which of a segment's display [tokens] the playhead is on: the last one
/// started by [tokenStartTimes], as the old transcript view lit whisper's
/// words.
int localWordAtAudioTime({
  required int audioTimeMs,
  required int segStartMs,
  required int? segEndMs,
  required List<List<Object>> stamps,
  required List<String> tokens,
}) {
  if (tokens.length <= 1) return 0;
  final times = tokenStartTimes(
      tokens: tokens,
      segStartMs: segStartMs,
      segEndMs: segEndMs,
      stamps: stamps);
  // Tokens that share a start (no end to spread over, or a stamp whisper
  // gave no length) light the first of them, never jump to the last.
  var lit = 0;
  for (var i = 1; i < times.length; i++) {
    if (times[i] <= audioTimeMs && times[i] > times[lit]) lit = i;
  }
  return lit;
}

final _notSpoken = RegExp(r'[^\p{L}\p{N}]', unicode: true);

/// The letters and digits of [word]: what is said aloud.
int _spokenLength(String word) => word.replaceAll(_notSpoken, '').length;

/// When each of a segment's display [tokens] starts, ms, never going back.
///
/// With whisper's word [stamps] (`[word, t0, t1]` rows), tokens and stamps
/// are matched by their letters, not by counting words: whisper and the
/// page's tokenizer split differently ("well-known." is one whisper word
/// and two tokens; whisper may split "cannot"). A token takes the time of
/// the point in whisper's words where its first letter falls, read
/// between that word's start and end.
///
/// Without stamps only the segment's own start and end are known. The
/// segment's time is then spread over its tokens by their length (letters
/// and digits, plus one for the gap): a long word takes longer to say
/// than a short one. That is an estimate inside the segment; the segment's
/// bounds stay exact. With no end, nothing moves.
List<int> tokenStartTimes({
  required List<String> tokens,
  required int segStartMs,
  required int? segEndMs,
  required List<List<Object>> stamps,
}) {
  final n = tokens.length;
  if (n == 0) return const [];
  final lengths = [for (final t in tokens) _spokenLength(t)];
  final tokenLetters = lengths.fold(0, (a, b) => a + b);
  final stampLengths = [for (final s in stamps) _spokenLength(s[0] as String)];
  final stampLetters = stampLengths.fold(0, (a, b) => a + b);
  final out = <int>[];

  if (stamps.isNotEmpty && tokenLetters > 0 && stampLetters > 0) {
    // The two texts are normally the same letters; where they are not (a
    // shortened link), each token's place is scaled onto whisper's.
    final scale = stampLetters / tokenLetters;
    final stampFrom = <int>[];
    var sum = 0;
    for (final l in stampLengths) {
      stampFrom.add(sum);
      sum += l;
    }
    var at = 0;
    for (var i = 0; i < n; i++) {
      final point = at * scale;
      // The last spoken stamp starting at or before this point.
      var k = stampLengths.indexWhere((l) => l > 0);
      for (var j = k + 1; j < stamps.length; j++) {
        if (stampLengths[j] > 0 && stampFrom[j] <= point) k = j;
      }
      final t0 = stamps[k][1] as int, t1 = stamps[k][2] as int;
      final within =
          ((point - stampFrom[k]) / stampLengths[k]).clamp(0.0, 1.0);
      out.add(t0 + ((t1 - t0) * within).round());
      at += lengths[i];
    }
  } else {
    final end = segEndMs;
    if (end == null || end <= segStartMs) {
      return List.filled(n, segStartMs);
    }
    final weights = [for (final l in lengths) l + 1];
    final total = weights.fold(0, (a, b) => a + b);
    var used = 0;
    for (var i = 0; i < n; i++) {
      out.add(segStartMs + ((end - segStartMs) * used / total).round());
      used += weights[i];
    }
  }
  for (var i = 1; i < n; i++) {
    if (out[i] < out[i - 1]) out[i] = out[i - 1];
  }
  return out;
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

final _linkStart = RegExp(r'^https?://', caseSensitive: false);
final _linkTail = RegExp(r'[.,;:!?)\]”’\x22\x27]+$');

/// The web address a word of the text stands for, or null when the word
/// is not a link. [original] is the token as written (the tokenizer
/// keeps the full address behind the shortened word it shows); the
/// punctuation that ends a sentence is not part of the address.
String? linkOfToken(String original) {
  if (!_linkStart.hasMatch(original)) return null;
  final href = original.replaceFirst(_linkTail, '');
  final uri = Uri.tryParse(href);
  return uri == null || uri.host.isEmpty ? null : href;
}

/// The words of one block that sit inside its links (frozen references):
/// global word index to href. [originals] are the tokenizer's originals
/// for the block, from its first word on (words past the block are never
/// matched: a search that fails stops there), [firstWordIdx] the global
/// index of its first word, and [links] the block's (start, end, href)
/// character ranges in [text]. A word is in a link when their ranges
/// overlap; every part of a split compound shares the compound's range.
Map<int, String> linkedWordsOf({
  required String text,
  required List<String> originals,
  required int firstWordIdx,
  required List<(int, int, String)> links,
}) {
  if (links.isEmpty) return const {};
  final out = <int, String>{};
  var cursor = 0;
  var partsLeft = 0;
  var range = (0, 0);
  for (var i = 0; i < originals.length; i++) {
    final original = originals[i];
    if (partsLeft > 0) {
      partsLeft--;
    } else {
      final at = text.indexOf(original, cursor);
      if (at < 0) break;
      range = (at, at + original.length);
      cursor = range.$2;
      // A compound the tokenizer split shows as one word per part.
      partsLeft = original.length > 6 && original.contains('-')
          ? original.split('-').where((p) => p.isNotEmpty).length - 1
          : 0;
      if (partsLeft < 0) partsLeft = 0;
      if (partsLeft > 0 &&
          (i + partsLeft >= originals.length ||
              originals[i + partsLeft] != original)) {
        partsLeft = 0;
      }
    }
    for (final (s, e, href) in links) {
      if (range.$1 < e && s < range.$2) {
        out[firstWordIdx + i] = href;
        break;
      }
    }
  }
  return out;
}
