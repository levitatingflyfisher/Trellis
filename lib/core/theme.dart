import 'package:flutter/material.dart';
import 'package:openhearth_design/openhearth_design.dart';

/// Warm OpenHearth palette, Material 3 — via the canonical design system.
///
/// Trellis was hearth-branded from day one (the old theme seeded
/// `ColorScheme.fromSeed` with the exact hearth500 literal); this graduates
/// it to the real grammar: [OhTheme.light] / [OhTheme.hearthDark] with no
/// `appAccent` override, because hearth IS the Trellis brand. Keeps the
/// `trellisTheme(Brightness)` signature so call sites don't churn.
ThemeData trellisTheme(Brightness brightness) =>
    brightness == Brightness.dark ? OhTheme.hearthDark() : OhTheme.light();
