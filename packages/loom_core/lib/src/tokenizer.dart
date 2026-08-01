/// The RSVP tokenizer, ported from ohPrimer rebuild/src/scripts/15-tokenizer.js.
///
/// Spine segments → the word stream a speed reader paces through: parallel
/// words/originals/pacing lists, a word-index map for non-prose segments
/// (their sentinel token stands in the stream), chapter marks, and each
/// block's start index. The donor JS is the spec; its heuristics — and its
/// known limitations — are preserved verbatim.
///
/// Donor block types map onto [SegmentKind]: `text`→[SegmentKind.prose]
/// (tokenized), `chapter`→[SegmentKind.heading] (a [ChapterMark], no word),
/// `segment`→[SegmentKind.code]/[SegmentKind.table]/[SegmentKind.figure]
/// (one `[kind]` sentinel word).
///
/// KNOWN DONOR LIMITATION M8 (kept, regression-marked in tests): the
/// [maxTokenChars] long-token skip mangles space-less scripts (CJK/Thai) —
/// a long run collapses to a single `…` placeholder.
library;

import 'dart:math' as math;

import 'spine.dart';

/// Tokens longer than this collapse to a `…` placeholder (donor
/// `MAX_TOKEN_CHARS`). Measured in UTF-16 code units, matching JS
/// `String.length`.
const int maxTokenChars = 30;

final _urlRe = RegExp(r'^https?://', caseSensitive: false);
final _emEnDashRe = RegExp(r'[–—]');

/// Invisible Unicode chars (zero-width spaces, joiners, soft hyphens, BOM)
/// that survive web copy-paste and break word splitting.
final _invisibleRe = RegExp(r'[\u200B\u200C\u200D\u2060\u00AD\uFEFF]');
final _whitespaceRe = RegExp(r'\s+');

/// Per-token pacing weight from trailing punctuation (donor
/// `getPunctuationDelay`): sentence end 1.7, semicolon/colon 1.2, comma 1.0,
/// trailing dash 1.0, then long words (>10 chars) 1.1, else 1.0.
double getPunctuationDelay(String w) {
  if (RegExp(r'[.!?]$').hasMatch(w)) return 1.7;
  if (RegExp(r'[;:]$').hasMatch(w)) return 1.2;
  if (RegExp(r',$').hasMatch(w)) return 1.0;
  if (RegExp(r'[-–—]$').hasMatch(w)) return 1.0;
  return w.length > 10 ? 1.1 : 1.0;
}

/// Shortens a URL for display (donor `abbreviateUrl`): `host`, `host/seg`,
/// or `host/…/last`; an unparseable URL falls back to plain truncation at
/// [maxTokenChars].
String abbreviateUrl(String url) {
  try {
    final u = Uri.parse(url);
    // JS `new URL` throws on a missing host; Dart's lenient Uri.parse does
    // not, so an empty host is routed to the same fallback by hand.
    if (u.host.isEmpty) throw const FormatException('no host');
    final host = u.host.replaceFirst(RegExp(r'^www\.'), '');
    final segs = u.path.split('/').where((s) => s.isNotEmpty).toList();
    if (segs.isEmpty) return host;
    if (segs.length == 1) return '$host/${segs.first}';
    return '$host/…/${segs.last}';
  } on FormatException {
    return url.length > maxTokenChars
        ? '${url.substring(0, maxTokenChars - 1)}…'
        : url;
  }
}

/// A chapter boundary in the word stream: the word index at which the
/// chapter begins, and its title. Headings emit no word of their own.
class ChapterMark {
  final int idx;
  final String title;
  const ChapterMark({required this.idx, required this.title});
}

/// The tokenizer's output (donor `st`): parallel lists plus the maps a
/// renderer needs to pace, display originals on tap, and navigate.
class TokenizedDocument {
  /// Display tokens, in reading order. Non-prose segments appear as one
  /// `[kind]` sentinel; over-long tokens as `…`; URLs abbreviated.
  final List<String> words;

  /// The source token behind each word (parallel to [words]) — the full URL
  /// behind an abbreviation, the whole compound behind each hyphen part.
  final List<String> originals;

  /// Per-word pacing weight (parallel to [words]).
  final List<double> pacing;

  /// Word index of each non-prose sentinel → its source [Segment].
  final Map<int, Segment> segments;

  /// Chapter marks, in order.
  final List<ChapterMark> chapters;

  /// Count of over-long tokens replaced by the `…` placeholder.
  final int skipped;

  /// For each input block (by list position), the word index at which it
  /// starts.
  final List<int> blockStartWordIdx;

  const TokenizedDocument({
    required this.words,
    required this.originals,
    required this.pacing,
    required this.segments,
    required this.chapters,
    required this.skipped,
    required this.blockStartWordIdx,
  });
}

class _TokenizerState {
  final words = <String>[];
  final originals = <String>[];
  final pacing = <double>[];
  final segments = <int, Segment>{};
  final chapters = <ChapterMark>[];
  int skipped = 0;
  final List<int> blockStartWordIdx;
  _TokenizerState(int blockCount)
      : blockStartWordIdx = List<int>.filled(blockCount, 0);
}

void _emitToken(String raw, _TokenizerState st) {
  // URL abbreviation (checked before the length skip, so a long URL is
  // abbreviated rather than dropped — donor order).
  if (_urlRe.hasMatch(raw)) {
    st.words.add(abbreviateUrl(raw));
    st.originals.add(raw);
    st.pacing.add(1.0);
    return;
  }
  // Long-token skip.
  if (raw.length > maxTokenChars) {
    st.words.add('…');
    st.originals.add(raw);
    st.pacing.add(1.0);
    st.skipped++;
    return;
  }
  // Hyphenated compound split (hyphen only, not em/en dash).
  if (raw.length > 6 && raw.contains('-') && !_emEnDashRe.hasMatch(raw)) {
    final parts = raw.split('-').where((p) => p.isNotEmpty).toList();
    if (parts.length > 1) {
      for (var i = 0; i < parts.length; i++) {
        st.words.add(parts[i]);
        st.originals.add(raw);
        st.pacing
            .add(i < parts.length - 1 ? 0.8 : getPunctuationDelay(parts[i]));
      }
      return;
    }
  }
  st.words.add(raw);
  st.originals.add(raw);
  st.pacing.add(getPunctuationDelay(raw));
}

void _tokenizeText(String text, _TokenizerState st) {
  final clean = text.replaceAll(_invisibleRe, '');
  for (final w in clean.split(_whitespaceRe)) {
    if (w.isNotEmpty) _emitToken(w, st);
  }
}

/// Tokenizes an ordered list of spine segments (donor `tokenizeDocument`
/// over `Document.blocks`).
TokenizedDocument tokenizeDocument(List<Segment> blocks) {
  final st = _TokenizerState(blocks.length);
  for (var bi = 0; bi < blocks.length; bi++) {
    st.blockStartWordIdx[bi] = st.words.length;
    final block = blocks[bi];
    switch (block.kind) {
      case SegmentKind.heading:
        st.chapters.add(ChapterMark(idx: st.words.length, title: block.text));
      case SegmentKind.code:
      case SegmentKind.table:
      case SegmentKind.figure:
        st.segments[st.words.length] = block;
        st.words.add('[${block.kind.name}]');
        st.originals.add('[${block.kind.name}]');
        st.pacing.add(1.5);
      case SegmentKind.prose:
        if (block.text.isNotEmpty) {
          _tokenizeText(block.text, st);
          // Paragraph break — a real pause benefits readability, added as a
          // "paragraph ghost" through pacing. Donor quirk kept: this bumps
          // the LAST pacing entry overall, so a prose block that tokenizes
          // to zero words (whitespace-only text) still bumps the previous
          // block's final word.
          if (st.pacing.isNotEmpty) {
            st.pacing[st.pacing.length - 1] = math.max(st.pacing.last, 1.5);
          }
        }
    }
  }
  return TokenizedDocument(
    words: st.words,
    originals: st.originals,
    pacing: st.pacing,
    segments: st.segments,
    chapters: st.chapters,
    skipped: st.skipped,
    blockStartWordIdx: st.blockStartWordIdx,
  );
}
