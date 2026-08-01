import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/reader/line_paced_view.dart';

/// A [LinePacedBlock]'s bare [Stack] sizes to its largest child, and
/// [Positioned] children (the highlight band) don't contribute to that
/// sizing — this pins the highlight layer NEVER distorting the block's
/// own layout height away from what the identical words as plain
/// [Text.rich] would occupy. Deliberately NOT compared against Scroll
/// mode's own block height: that Wrap adds its own `runSpacing` between
/// wrapped lines and a taller drop-cap on the first word — a real visual
/// difference between the two modes, not a bug in this one.
Future<double> _pumpAndMeasure(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: SizedBox(width: 200, child: child)),
  ));
  await tester.pumpAndSettle();
  return tester.getSize(find.byKey(const Key('measured'))).height;
}

/// Campaign 9 Phase 6 ("a third way to read"): the pure line-grouping
/// geometry underneath the new Lines mode — given a block's words and a
/// layout width, which words land on which visual line. Real fonts load
/// for every test (test/flutter_test_config.dart), so widths here are
/// chosen with a comfortable margin rather than pinned to an exact glyph
/// count, the same caution the accessibility-overflow sweeps already use
/// for font-metric-dependent assertions.
void main() {
  const style = TextStyle(fontSize: 16);

  test('every word is covered by exactly one line, in order', () {
    final words =
        'the quick brown fox jumps over the lazy dog again and again'
            .split(' ');
    final lines =
        computeLinePacedLines(words: words, style: style, maxWidth: 200);

    expect(lines, isNotEmpty);
    expect(lines.first.firstWordIdx, 0);
    expect(lines.last.lastWordIdx, words.length - 1);
    for (var i = 0; i < lines.length; i++) {
      expect(
          lines[i].lastWordIdx, greaterThanOrEqualTo(lines[i].firstWordIdx));
      if (i > 0) {
        expect(lines[i].firstWordIdx, lines[i - 1].lastWordIdx + 1);
      }
    }
  });

  test('a wide layout fits everything on one line', () {
    final words = 'a short sentence'.split(' ');
    final lines =
        computeLinePacedLines(words: words, style: style, maxWidth: 2000);
    expect(lines, hasLength(1));
    expect(lines.single.firstWordIdx, 0);
    expect(lines.single.lastWordIdx, words.length - 1);
  });

  test('a narrow layout wraps the same words onto more than one line', () {
    final words = 'the quick brown fox jumps over the lazy dog'.split(' ');
    final wide =
        computeLinePacedLines(words: words, style: style, maxWidth: 2000);
    final narrow =
        computeLinePacedLines(words: words, style: style, maxWidth: 80);
    expect(wide, hasLength(1));
    expect(narrow.length, greaterThan(1));
  });

  test('each line rect spans the full width and stacks top to bottom', () {
    final words = 'the quick brown fox jumps over the lazy dog'.split(' ');
    final lines =
        computeLinePacedLines(words: words, style: style, maxWidth: 80);
    expect(lines.length, greaterThan(1));
    for (final line in lines) {
      expect(line.rect.left, 0);
      expect(line.rect.width, 80);
    }
    for (var i = 1; i < lines.length; i++) {
      expect(lines[i].rect.top,
          greaterThanOrEqualTo(lines[i - 1].rect.bottom - 0.01));
    }
  });

  test('an empty word list yields no lines', () {
    expect(
        computeLinePacedLines(words: const [], style: style, maxWidth: 200),
        isEmpty);
  });

  test(
      'a textScaleFactor above 1 can push a line count up, never down, '
      'for the same width', () {
    final words = 'the quick brown fox jumps over the lazy dog'.split(' ');
    final normal =
        computeLinePacedLines(words: words, style: style, maxWidth: 150);
    final scaled = computeLinePacedLines(
        words: words, style: style, maxWidth: 150, textScaleFactor: 2.0);
    expect(scaled.length, greaterThanOrEqualTo(normal.length));
  });

  testWidgets(
      'the highlight Stack sizes to the text it wraps — Positioned '
      'children never distort a bare Stack away from its content height',
      (tester) async {
    const words = [
      'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', //
      'nine', 'ten',
    ];
    const textStyle = TextStyle(fontSize: 16, height: 1.6);

    final blockHeight = await _pumpAndMeasure(
        tester,
        LinePacedBlock(
          key: const Key('measured'),
          words: words,
          style: textStyle,
          currentLocalWordIdx: 3,
        ));
    final plainHeight = await _pumpAndMeasure(
        tester,
        Text.rich(
          key: const Key('measured'),
          TextSpan(text: words.join(' '), style: textStyle),
        ));

    expect(blockHeight, closeTo(plainHeight, 0.5));
  });
}
