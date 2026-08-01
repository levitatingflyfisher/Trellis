import 'dart:ui';

import 'package:openhearth_design/openhearth_design.dart';

/// The ripening law (proposal-2 §12): a fruit's fill lerps green → blush →
/// terracotta as mastery grows. All three stops are OhColors tokens (theme
/// law C1); everything between is a true lerp, so the wall shows *how far
/// along* a concept is, not just started/done.
Color ripenColor(double mastery) {
  final t = mastery.clamp(0.0, 1.0);
  return t <= 0.5
      ? Color.lerp(OhColors.sage500, OhColors.hearth300, t * 2)!
      : Color.lerp(OhColors.hearth300, OhColors.hearth500, (t - 0.5) * 2)!;
}
