/// Merged transcript chunks → sentence-ish [TimedSegment]s.
///
/// The splitting law, chosen for multilingual speech-to-text (not a full
/// sentence tokenizer — "sentence-ish" is the contract):
///
///  * ASCII enders `.` `!` `?` end a sentence when followed — after any
///    closing quotes/brackets — by whitespace or end of text. That single
///    whitespace requirement keeps `3.14` whole.
///  * Fullwidth enders `。` `！` `？` end a sentence unconditionally: CJK
///    text puts no space after them.
///  * Ellipses — `…`, or a run of two-plus `.` — continue the thought and
///    never split. (`Yes... maybe.` is one sentence.)
///  * Openers such as `¿` `¡` need no rule: they are not enders, so they
///    start the sentence they belong to.
///
/// Length bounds keep segments RSVP-friendly: sentences shorter than
/// [minChars] merge forward (a short tail merges backward); anything longer
/// than [maxChars] splits at the last whitespace inside the bound, hard-cut
/// when there is none. Max wins over min: a hard-cut tail may be short.
///
/// Times interpolate linearly by character position inside each source
/// chunk's span, then clamp monotonic — segments tile in ascending,
/// non-overlapping order, ready to become `loom_core` Alignments.
library;

import 'package:ml_runtime/ml_runtime.dart' show TranscriptChunk;

/// One sentence-ish span of the transcript with its audio time range.
class TimedSegment {
  final String text;
  final int tStartMs;
  final int tEndMs;

  const TimedSegment(
      {required this.text, required this.tStartMs, required this.tEndMs});

  @override
  bool operator ==(Object other) =>
      other is TimedSegment &&
      other.text == text &&
      other.tStartMs == tStartMs &&
      other.tEndMs == tEndMs;

  @override
  int get hashCode => Object.hash(text, tStartMs, tEndMs);

  @override
  String toString() => 'TimedSegment("$text", $tStartMs..$tEndMs)';
}

const _asciiEnders = {'.', '!', '?'};
const _hardEnders = {'。', '！', '？'};
const _ellipsis = '…';
const _closers = {'"', "'", '”', '’', '»', ')', ']', '」', '』'};

bool _isEnder(String c) =>
    _asciiEnders.contains(c) || _hardEnders.contains(c) || c == _ellipsis;

bool _isWhitespace(String c) => c.trim().isEmpty;

/// A contiguous run of one source chunk's (trimmed) text inside the
/// concatenated transcript, carrying its time range.
class _Piece {
  final int charStart;
  final int charEnd;
  final int t0;
  final int t1;
  _Piece(this.charStart, this.charEnd, this.t0, this.t1);
}

List<TimedSegment> segmentize(
  List<TranscriptChunk> chunks, {
  int minChars = 8,
  int maxChars = 240,
}) {
  if (minChars < 1) {
    throw ArgumentError.value(minChars, 'minChars', 'must be at least 1');
  }
  if (maxChars < 1) {
    throw ArgumentError.value(maxChars, 'maxChars', 'must be at least 1');
  }
  if (minChars > maxChars) {
    throw ArgumentError.value(
        minChars, 'minChars', 'must not exceed maxChars ($maxChars)');
  }

  // 1. Concatenate trimmed chunk texts, single-space joined, remembering
  //    which chunk (and so which time range) every character came from.
  final buffer = StringBuffer();
  final pieces = <_Piece>[];
  for (final c in chunks) {
    final text = c.text.trim();
    if (text.isEmpty) continue;
    if (buffer.isNotEmpty) buffer.write(' ');
    final start = buffer.length;
    buffer.write(text);
    pieces.add(_Piece(start, buffer.length, c.tStartMs, c.tEndMs));
  }
  final s = buffer.toString();
  if (s.isEmpty) return const [];

  // 2. Raw sentence spans.
  final raw = _splitSentences(s);

  // 3. Min bound: merge forward; a short tail merges backward.
  final grouped = _mergeShort(s, raw, minChars);

  // 4. Max bound: split over-long groups at whitespace, hard-cut otherwise.
  final bounded = <(int, int)>[];
  for (final span in grouped) {
    bounded.addAll(_splitLong(s, span, maxChars));
  }

  // 5. Times: interpolate by character position, clamp monotonic.
  final out = <TimedSegment>[];
  var prevEnd = 0;
  for (final (a, b) in bounded) {
    var t0 = _timeAt(pieces, a);
    if (t0 < prevEnd) t0 = prevEnd;
    var t1 = _timeAt(pieces, b);
    if (t1 < t0) t1 = t0;
    out.add(TimedSegment(text: s.substring(a, b), tStartMs: t0, tEndMs: t1));
    prevEnd = t1;
  }
  return out;
}

/// Trimmed [start, end) spans of raw sentences in [s].
List<(int, int)> _splitSentences(String s) {
  final spans = <(int, int)>[];
  var sentenceStart = 0;
  var i = 0;

  void close(int end) {
    final span = _trimSpan(s, sentenceStart, end);
    if (span != null) spans.add(span);
    sentenceStart = end;
  }

  while (i < s.length) {
    if (!_isEnder(s[i])) {
      i++;
      continue;
    }
    // The whole run of enders ("?!", "...", "。").
    var j = i;
    while (j + 1 < s.length && _isEnder(s[j + 1])) {
      j++;
    }
    // An ellipsis continues the thought, never ends it.
    final run = s.substring(i, j + 1);
    final isEllipsis = run.contains(_ellipsis) ||
        (run.length >= 2 && run.split('').every((c) => c == '.'));
    if (isEllipsis) {
      i = j + 1;
      continue;
    }
    // Closing quotes/brackets belong to the sentence they close.
    var k = j;
    while (k + 1 < s.length && _closers.contains(s[k + 1])) {
      k++;
    }
    final hard = run.split('').any(_hardEnders.contains);
    final atEnd = k + 1 >= s.length;
    if (hard || atEnd || _isWhitespace(s[k + 1])) {
      close(k + 1);
      i = k + 1;
    } else {
      i = j + 1; // "3.14" — an ender glued to more text is not a boundary
    }
  }
  if (sentenceStart < s.length) close(s.length);
  return spans;
}

/// Merge spans forward until each group reaches [minChars]; a final short
/// group merges backward into its predecessor when one exists.
List<(int, int)> _mergeShort(String s, List<(int, int)> spans, int minChars) {
  final groups = <(int, int)>[];
  int? openStart;
  for (final (a, b) in spans) {
    openStart ??= a;
    if (b - openStart >= minChars) {
      groups.add((openStart, b));
      openStart = null;
    }
  }
  if (openStart != null) {
    final last = spans.last;
    if (groups.isEmpty) {
      groups.add((openStart, last.$2));
    } else {
      final prev = groups.removeLast();
      groups.add((prev.$1, last.$2));
    }
  }
  return groups;
}

/// Split one span into pieces of at most [maxChars], preferring the last
/// whitespace inside the bound; hard-cut when the run has none.
List<(int, int)> _splitLong(String s, (int, int) span, int maxChars) {
  final out = <(int, int)>[];
  var (a, b) = span;
  while (b - a > maxChars) {
    var cut = -1;
    for (var p = a + maxChars; p > a; p--) {
      if (_isWhitespace(s[p])) {
        cut = p;
        break;
      }
    }
    if (cut == -1) cut = a + maxChars;
    final piece = _trimSpan(s, a, cut);
    if (piece != null) out.add(piece);
    a = cut;
    while (a < b && _isWhitespace(s[a])) {
      a++;
    }
  }
  final tail = _trimSpan(s, a, b);
  if (tail != null) out.add(tail);
  return out;
}

/// [start, end) with surrounding whitespace shaved; null when nothing is
/// left.
(int, int)? _trimSpan(String s, int start, int end) {
  var a = start;
  var b = end;
  while (a < b && _isWhitespace(s[a])) {
    a++;
  }
  while (b > a && _isWhitespace(s[b - 1])) {
    b--;
  }
  return a == b ? null : (a, b);
}

/// The audio time at character position [pos]: linear inside a piece's
/// span, the previous piece's end time inside a joiner gap.
int _timeAt(List<_Piece> pieces, int pos) {
  var before = 0;
  for (final p in pieces) {
    if (pos < p.charStart) return before;
    if (pos < p.charEnd) {
      final len = p.charEnd - p.charStart;
      return p.t0 + ((p.t1 - p.t0) * (pos - p.charStart)) ~/ len;
    }
    before = p.t1;
  }
  return before;
}
