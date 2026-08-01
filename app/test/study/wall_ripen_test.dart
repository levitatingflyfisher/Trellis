import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhearth_design/openhearth_design.dart';
import 'package:trellis/features/study/wall/ripen.dart';

/// The ripening law of the Espalier Wall (proposal-2 §12): a fruit's fill
/// lerps green → blush → terracotta with mastery. Every stop is an OhColors
/// token (theme law C1) — never a retyped hex.
void main() {
  test('an unstarted concept is a green fruit (sage)', () {
    expect(ripenColor(0.0), OhColors.sage500);
  });

  test('half mastery is the blush midpoint (hearth300)', () {
    expect(ripenColor(0.5), OhColors.hearth300);
  });

  test('full mastery is ripe terracotta (hearth500)', () {
    expect(ripenColor(1.0), OhColors.hearth500);
  });

  test('the quarter points are true lerps between the stops', () {
    expect(ripenColor(0.25), Color.lerp(OhColors.sage500, OhColors.hearth300, 0.5));
    expect(ripenColor(0.75), Color.lerp(OhColors.hearth300, OhColors.hearth500, 0.5));
  });

  test('mastery outside [0,1] clamps instead of extrapolating', () {
    expect(ripenColor(-3.0), OhColors.sage500);
    expect(ripenColor(2.5), OhColors.hearth500);
  });
}
