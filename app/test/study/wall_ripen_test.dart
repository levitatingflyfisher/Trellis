import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhearth_design/openhearth_design.dart';
import 'package:trellis/features/study/wall/ripen.dart';

/// The ripening law of the course map (proposal-2 §12): a fruit's fill
/// goes from pale green (unripe) through blush to deep terracotta with
/// mastery. Every stop is an OhColors token (theme law C1). Audit
/// visual-01: the old ramp (sage500 → hearth300 → hearth500) rose then
/// fell in lightness, so 0% and 78% looked the same in grey; the ramp must
/// darken steadily, so mastery reads without hue.
void main() {
  test('an unstarted concept is a pale green fruit (sage200)', () {
    expect(ripenColor(0.0), OhColors.sage200);
  });

  test('half mastery is the blush midpoint (hearth300)', () {
    expect(ripenColor(0.5), OhColors.hearth300);
  });

  test('full mastery is deep ripe terracotta (hearth600)', () {
    expect(ripenColor(1.0), OhColors.hearth600);
  });

  test('darker at every step: lightness falls monotonically, with a '
      'visible step between tenths and 3:1 end to end', () {
    double contrast(Color a, Color b) {
      final la = a.computeLuminance(), lb = b.computeLuminance();
      return (la > lb ? la + 0.05 : lb + 0.05) / (la > lb ? lb + 0.05 : la + 0.05);
    }

    for (var i = 1; i <= 10; i++) {
      final prev = ripenColor((i - 1) / 10), next = ripenColor(i / 10);
      expect(next.computeLuminance(), lessThan(prev.computeLuminance()),
          reason: 'step ${i - 1}0% → ${i}0% must darken');
      expect(contrast(prev, next), greaterThan(1.05),
          reason: 'step ${i - 1}0% → ${i}0% must be visibly different');
    }
    expect(contrast(ripenColor(0), ripenColor(1)), greaterThanOrEqualTo(3.0));
  });

  test('mastery outside [0,1] clamps instead of extrapolating', () {
    expect(ripenColor(-3.0), OhColors.sage200);
    expect(ripenColor(2.5), OhColors.hearth600);
  });

  test('the glyph on the fruit reads at every ripeness (3:1)', () {
    for (var i = 0; i <= 10; i++) {
      final fill = ripenColor(i / 10).computeLuminance();
      final ink = ripenInk(i / 10).computeLuminance();
      final hi = fill > ink ? fill : ink, lo = fill > ink ? ink : fill;
      expect((hi + 0.05) / (lo + 0.05), greaterThanOrEqualTo(3.0),
          reason: 'at ${i}0%');
    }
  });
}
