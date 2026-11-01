import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/intake/pdf_licenses.dart';

/// PDFium is a prebuilt binary, so Flutter's own licence gathering never
/// sees it: Trellis carries its licence texts and registers them itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PDFium and every library built into it are on the licence list',
      () async {
    registerPdfiumLicenses();

    final entries = await LicenseRegistry.licenses
        .where((e) => e.packages.contains('PDFium'))
        .toList();
    expect(entries, hasLength(1));
    final text = entries.single.paragraphs.map((p) => p.text).join('\n');
    for (final name in [
      'pdfium-binaries',
      'PDFium',
      'Abseil',
      'Anti-Grain Geometry',
      'Catapult',
      'cpu_features',
      'fast_float',
      'FreeType',
      'ICU',
      'Little CMS',
      'libjpeg-turbo',
      'OpenJPEG',
      'libpng',
      'libtiff',
      'libunwind',
      'LLVM libc',
      'zlib',
    ]) {
      expect(text, contains(name), reason: name);
    }
    expect(text, contains('The PDFium Authors'));
    expect(text, contains('Apache License'));
  });

  test('registering twice lists it once', () async {
    registerPdfiumLicenses();
    registerPdfiumLicenses();

    expect(
        await LicenseRegistry.licenses
            .where((e) => e.packages.contains('PDFium'))
            .length,
        1);
  });
}
