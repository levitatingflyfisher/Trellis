import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/reader/reader_prefs.dart';

/// Campaign 4 Phase 1: the per-profile reader-prefs JSON blob (one column,
/// [Profiles.readerPrefsJson]) — typography for the scroll/print reader.
/// RSVP and the ticker keep their own tuned displays and are untouched.
void main() {
  group('ReaderTypography round-trip', () {
    test('defaults match the reader\'s existing hardcoded print body', () {
      const t = ReaderTypography();
      expect(t.fontScale, 1.0);
      expect(t.lineHeight, 1.6);
      expect(t.maxTextWidth, 680);
      expect(t.paragraphSpacing, 8);
      expect(t.typeface, ReaderTypeface.lora);
      expect(t.justified, false);
    });

    test('every field round-trips through JSON', () {
      const t = ReaderTypography(
          fontScale: 1.25,
          lineHeight: 2.0,
          maxTextWidth: 560,
          paragraphSpacing: 16,
          typeface: ReaderTypeface.nunito,
          justified: true);
      final back = ReaderTypography.fromJson(t.toJson());
      expect(back.fontScale, 1.25);
      expect(back.lineHeight, 2.0);
      expect(back.maxTextWidth, 560);
      expect(back.paragraphSpacing, 16);
      expect(back.typeface, ReaderTypeface.nunito);
      expect(back.justified, true);
    });

    test('missing/corrupt JSON decodes to the honest defaults, never throws',
        () {
      expect(ReaderTypography.fromJson(null), const ReaderTypography());
      expect(ReaderTypography.fromJson(const {}), const ReaderTypography());
      expect(
          ReaderTypography.fromJson(const {'fontScale': 'not a number'}),
          const ReaderTypography());
      expect(
          ReaderTypography.fromJson(const {'typeface': 'comic-sans'}).typeface,
          ReaderTypeface.lora,
          reason: 'an unknown wire name falls back to the bundled default');
    });

    test('readerTypefaceFontFamily only ever names a bundled face', () {
      expect(readerTypefaceFontFamily(ReaderTypeface.lora), 'Lora');
      expect(readerTypefaceFontFamily(ReaderTypeface.nunito), 'Nunito');
    });
  });

  group('ReaderPrefs encode/decode (the Profiles.readerPrefsJson codec)', () {
    test('an empty/corrupt blob decodes to all-default prefs', () {
      expect(ReaderPrefs.decode('').typography, const ReaderTypography());
      expect(ReaderPrefs.decode('{}').typography, const ReaderTypography());
      expect(ReaderPrefs.decode('not json').typography,
          const ReaderTypography());
    });

    test('encode -> decode round-trips typography', () {
      const prefs = ReaderPrefs(
          typography: ReaderTypography(fontScale: 1.4, justified: true));
      final back = ReaderPrefs.decode(prefs.encode());
      expect(back.typography.fontScale, 1.4);
      expect(back.typography.justified, true);
    });

    test('copyWith replaces only the given field', () {
      const prefs = ReaderPrefs(typography: ReaderTypography(fontScale: 1.2));
      final next = prefs.copyWith(
          typography: const ReaderTypography(fontScale: 1.2, justified: true));
      expect(next.typography.fontScale, 1.2);
      expect(next.typography.justified, true);
    });
  });
}
