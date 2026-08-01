/// The plain-text/markdown structure parser, ported from ohPrimer
/// rebuild/src/scripts/20-parsers.js (`parseTextFile`).
///
/// Raw pasted/imported text → typed spine [Segment]s: paragraphs
/// ([SegmentKind.prose]), chapter headings ([SegmentKind.heading]), indented
/// code blocks ([SegmentKind.code]), pipe tables ([SegmentKind.table]).
/// Divider / ASCII-art runs are dropped but still separate the paragraphs on
/// either side (donor fix M9). The donor JS is the spec; every heuristic and
/// threshold is preserved verbatim.
///
/// "Markdown" support is exactly what the donor had: none of these rules are
/// markdown-specific (no `#` headings, no fenced code) — markdown text simply
/// flows through the same plain-text heuristics.
library;

import 'dart:math' as math;

import 'spine.dart';

final _invisibleRe = RegExp(r'[\uFEFF\u200B\u200C\u200D\u2060\u00AD]');
final _lineBreakRe = RegExp(r'\r?\n');
final _chapterRe =
    RegExp(r'^\s*(chapter|part|book)\s+[ivxlcdm\d]+', caseSensitive: false);
final _dividerCharsRe = RegExp(r'[=\-_*~]');
final _indentRe = RegExp(r'^(    |\t)');
final _pipeRe = RegExp(r'\|');
final _whitespaceRe = RegExp(r'\s+');

/// A parsed source (donor `Document {title, blocks}`): its title and the
/// ordered typed segments, ready for `tokenizeDocument`.
class ParsedText {
  final String title;
  final List<Segment> segments;
  const ParsedText({required this.title, required this.segments});
}

/// Parses plain text into typed segments (donor `parseTextFile`).
///
/// A null or empty [title] falls back to `'Text'` (JS `title||"Text"`).
ParsedText parseTextFile(String text, [String? title]) {
  final segments = <Segment>[];
  final lines = text.replaceAll(_invisibleRe, '').split(_lineBreakRe);
  var i = 0;
  var proseBuffer = <String>[];

  void addSegment(SegmentKind kind, String text) {
    segments.add(Segment(idx: segments.length, kind: kind, text: text));
  }

  void flushProse() {
    if (proseBuffer.isNotEmpty) {
      addSegment(SegmentKind.prose,
          proseBuffer.join(' ').replaceAll(_whitespaceRe, ' ').trim());
      proseBuffer = <String>[];
    }
  }

  while (i < lines.length) {
    final line = lines[i];
    final trim = line.trim();

    // Chapter heading heuristic.
    if (_chapterRe.hasMatch(trim) && trim.length < 80) {
      flushProse();
      addSegment(SegmentKind.heading, trim);
      i++;
      continue;
    }

    // Divider / ASCII art run (high ratio of =/-/_): separates paragraphs —
    // flush the current one so the prose on either side doesn't get glued
    // together (M9), then drop the divider itself.
    if (trim.length > 3 &&
        trim.replaceAll(_dividerCharsRe, '').length <=
            math.max(2.0, trim.length * 0.2)) {
      flushProse();
      i++;
      continue;
    }

    // Indented code block (3+ consecutive lines with 4+ leading spaces or
    // tab; interior blank lines allowed). Donor quirks kept: only ONE level
    // of leading indent is stripped, and interior whitespace-only lines
    // survive the non-empty filter.
    if (_indentRe.hasMatch(line)) {
      var end = i;
      while (end < lines.length &&
          (_indentRe.hasMatch(lines[end]) || lines[end].trim() == '')) {
        end++;
      }
      final codeLines =
          lines.sublist(i, end).where((l) => l.isNotEmpty).toList();
      if (codeLines.length >= 3) {
        flushProse();
        addSegment(SegmentKind.code,
            codeLines.map((l) => l.replaceFirst(_indentRe, '')).join('\n'));
        i = end;
        continue;
      }
    }

    // Table heuristic: 3+ consecutive lines each with 2+ | chars.
    if (_pipeRe.allMatches(trim).length >= 2) {
      var end = i;
      while (
          end < lines.length && _pipeRe.allMatches(lines[end]).length >= 2) {
        end++;
      }
      if (end - i >= 3) {
        flushProse();
        addSegment(SegmentKind.table, lines.sublist(i, end).join('\n'));
        i = end;
        continue;
      }
    }

    // Blank line → paragraph break.
    if (trim == '') {
      flushProse();
      i++;
      continue;
    }

    proseBuffer.add(trim);
    i++;
  }
  flushProse();

  return ParsedText(
    title: (title == null || title.isEmpty) ? 'Text' : title,
    segments: segments,
  );
}
