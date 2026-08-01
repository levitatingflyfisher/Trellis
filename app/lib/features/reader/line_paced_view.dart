/// Campaign 9 Phase 6 ("a third way to read"): line-paced reading. Groups
/// a block's own word stream into VISUAL LINES at its laid-out width, so a
/// highlight can move one line at a time instead of one word (RSVP) or
/// nothing at all (Scroll's plain paragraph). Pure geometry, no widgets
/// beyond the small painter this file also carries — [reader_screen.dart]
/// stays a caller, never a definer, of this math.
///
/// This does NOT run its own clock. The highlighted line is whichever one
/// contains the reader's existing global word cursor — the same `_wordIdx`
/// RSVP and Scroll's follow-along already advance via `_step()`
/// (`60000/wpm × pacing` per word, ADR-0002's cursor law). A line's honest
/// dwell time is therefore the SUM of its own words' `msPerWord` — never a
/// separate `wordCount / wpm` division, which would silently discard the
/// tokenizer's punctuation-dwell weights and invent a second timing
/// formula alongside the one RSVP already trusts. There is nothing to sum
/// at runtime, either: it falls out for free from the shared word-level
/// timer crossing this line's word range before the next one's.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// One visual line within a block: which words (by LOCAL index into the
/// block's own word list) fall on it, and its highlight rect relative to
/// the block's own top-left origin.
class LinePacedLine {
  const LinePacedLine({
    required this.firstWordIdx,
    required this.lastWordIdx,
    required this.rect,
  });

  /// Local (block-relative) index of this line's first word.
  final int firstWordIdx;

  /// Local (block-relative) index of this line's last word, inclusive.
  final int lastWordIdx;

  /// The line's highlight band: left edge at 0, full layout width (not
  /// just the text's own measured width on that line) so a ragged-right
  /// line still highlights as a clean full-width band, and top/bottom
  /// from the painter's own line metrics.
  final Rect rect;

  bool contains(int localWordIdx) =>
      localWordIdx >= firstWordIdx && localWordIdx <= lastWordIdx;
}

/// Lays [words] out as a single space-joined paragraph at [maxWidth]
/// under [style], then groups them by which visual line each word landed
/// on.
///
/// Uses [TextPainter.getBoxesForSelection] per word rather than probing a
/// pixel coordinate back to a character offset
/// (`getPositionForOffset`+`getLineBoundary`): a word's own selection box
/// already carries its `top`, so words sharing a `top` are on the same
/// line by construction — no boundary-affinity guessing at the join
/// between two lines. A word that itself wraps across lines (very long,
/// narrow width) is assigned to the line its FIRST box starts on.
List<LinePacedLine> computeLinePacedLines({
  required List<String> words,
  required TextStyle style,
  required double maxWidth,
  double textScaleFactor = 1.0,
}) {
  if (words.isEmpty) return const [];
  final text = words.join(' ');
  final wordRanges = <(int, int)>[];
  var cursor = 0;
  for (final w in words) {
    wordRanges.add((cursor, cursor + w.length));
    cursor += w.length + 1; // +1 for the joining space
  }

  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.linear(textScaleFactor),
  )..layout(maxWidth: maxWidth);

  final lines = <LinePacedLine>[];
  double? currentTop;
  int? firstIdx;
  int? lastIdx;
  double lineBottom = 0;

  void flush() {
    if (firstIdx == null) return;
    lines.add(LinePacedLine(
      firstWordIdx: firstIdx,
      lastWordIdx: lastIdx!,
      rect: Rect.fromLTRB(0, currentTop!, maxWidth, lineBottom),
    ));
  }

  for (var i = 0; i < words.length; i++) {
    final (start, end) = wordRanges[i];
    final boxes = painter.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: end));
    if (boxes.isEmpty) continue; // defensive; every real word measures
    final top = boxes.first.top;
    final bottom = boxes.map((b) => b.bottom).reduce(math.max);
    if (currentTop == null || (top - currentTop).abs() > 0.5) {
      flush();
      currentTop = top;
      firstIdx = i;
    }
    lastIdx = i;
    lineBottom = bottom;
  }
  flush();
  painter.dispose();
  return lines;
}

/// Renders one block's words as flowing text with the visual line
/// containing [currentLocalWordIdx] painted as a highlight band behind
/// it. [currentLocalWordIdx] is block-relative (`globalWordIdx -
/// blockStartWordIdx`, per ADR-0002's cursor law) — callers convert once
/// via [cursorAt]; this widget never touches the global stream.
///
/// A cursor outside every computed line's range (block not yet reached,
/// or already finished) highlights nothing — a quiet default, not an
/// error, since [ReaderScreen] always has a `_wordIdx` pointing SOMEWHERE
/// in the document even when it is not in THIS block.
class LinePacedBlock extends StatelessWidget {
  const LinePacedBlock({
    super.key,
    required this.words,
    required this.style,
    required this.currentLocalWordIdx,
    this.highlightColor,
  });

  final List<String> words;
  final TextStyle style;
  final int currentLocalWordIdx;
  final Color? highlightColor;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final highlight =
        highlightColor ?? Theme.of(context).colorScheme.primaryContainer;
    return LayoutBuilder(builder: (context, constraints) {
      final maxWidth =
          constraints.maxWidth.isFinite ? constraints.maxWidth : 680.0;
      // scaler.scale(1.0) collapses the device's TextScaler to a single
      // linear factor for the geometry pass below, while the Text.rich
      // painted underneath gets the full non-linear `scaler`. The two
      // agree for every TextScaler this app actually ships (a plain
      // linear system multiplier); they would disagree only for a
      // genuinely non-linear scaler, which nothing here constructs.
      final lines = computeLinePacedLines(
        words: words,
        style: style,
        maxWidth: maxWidth,
        textScaleFactor: scaler.scale(1.0),
      );
      final current = lines.where((l) => l.contains(currentLocalWordIdx));
      return Stack(
        children: [
          for (final line in current)
            Positioned.fromRect(
              key: const Key('line-paced-highlight'),
              rect: line.rect,
              child: DecoratedBox(
                  decoration: BoxDecoration(color: highlight)),
            ),
          Text.rich(
            TextSpan(text: words.join(' '), style: style),
            textScaler: scaler,
          ),
        ],
      );
    });
  }
}
