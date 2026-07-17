import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhearth_design/openhearth_design.dart';
import 'package:trellis/core/theme.dart';

/// TIER-F graduation: Trellis was already hearth-branded by literal (the old
/// theme seeded ColorScheme.fromSeed with the canonical hearth500). These
/// tests pin the real grammar — the canonical OhTheme surfaces and bundled
/// Lora/Nunito type — instead of whatever fromSeed derives from the literal.
void main() {
  group('TrellisTheme(Brightness.light) is the canonical OhTheme.light', () {
    final theme = TrellisTheme(Brightness.light);

    test('linen surfaces', () {
      expect(theme.colorScheme.surface, OhColors.linen100);
      expect(theme.scaffoldBackgroundColor, OhColors.linen50);
    });

    test('hearth primary (hearth IS the Trellis brand — no appAccent)', () {
      expect(theme.colorScheme.primary, OhColors.hearth500);
    });

    test('design-system type: Lora display, Nunito body', () {
      expect(theme.textTheme.displayLarge?.fontFamily, 'Lora');
      expect(theme.textTheme.bodyMedium?.fontFamily, 'Nunito');
    });
  });

  group('TrellisTheme(Brightness.dark) is the canonical OhTheme.hearthDark',
      () {
    final theme = TrellisTheme(Brightness.dark);

    test('hearth-dark surfaces', () {
      expect(theme.colorScheme.surface, OhColors.darkSurfaceCard);
      expect(theme.scaffoldBackgroundColor, OhColors.darkSurfaceBase);
    });

    test('hearth-400 primary', () {
      expect(theme.colorScheme.primary, OhColors.hearth400);
    });
  });
}
