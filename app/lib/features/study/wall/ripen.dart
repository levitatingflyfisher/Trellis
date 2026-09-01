import 'dart:ui';

import 'package:openhearth_design/openhearth_design.dart';

/// The ripening law (proposal-2 §12): a fruit's fill goes pale green →
/// blush → deep terracotta as mastery grows. All three stops are OhColors
/// tokens (theme law C1); everything between is a true lerp, so the map
/// shows *how far along* a concept is, not just started/done.
///
/// The stops are chosen so lightness falls at every step (audit visual-01:
/// the old sage500 → hearth300 → hearth500 ramp rose then fell, so 0% and
/// 78% were the same grey). Mastery therefore reads without hue, for a
/// colour-blind reader or in greyscale.
Color ripenColor(double mastery) {
  final t = mastery.clamp(0.0, 1.0);
  return t <= 0.5
      ? Color.lerp(OhColors.sage200, OhColors.hearth300, t * 2)!
      : Color.lerp(OhColors.hearth300, OhColors.hearth600, (t - 0.5) * 2)!;
}

/// The fruit's glyph colour: warm white on a ripe (dark) fruit, the
/// primary ink on an unripe (pale) one, whichever reads better, so the
/// glyph clears 3:1 at every ripeness.
Color ripenInk(double mastery) {
  final fill = ripenColor(mastery).computeLuminance();
  double contrast(Color c) {
    final l = c.computeLuminance();
    return (l > fill ? l + 0.05 : fill + 0.05) /
        (l > fill ? fill + 0.05 : l + 0.05);
  }

  return contrast(OhColors.linen50) >= contrast(OhColors.linen900)
      ? OhColors.linen50
      : OhColors.linen900;
}
