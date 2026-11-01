/// PDFium's licences (1.6.0). PDFium arrives as a prebuilt binary, so
/// Flutter's own licence gathering, which reads Dart packages, never sees
/// it or the libraries built into it (FreeType, ICU, libjpeg-turbo and
/// the rest). Trellis carries their texts as an asset, exactly as the
/// binary's own package ships them, and adds them to the licence list.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

/// The asset: `assets/licenses/pdfium.txt`.
const pdfiumLicensesAsset = 'assets/licenses/pdfium.txt';

bool _registered = false;

/// Adds PDFium and what is built into it to Flutter's licence list. Safe
/// to call more than once. The text is read only when the list is shown.
void registerPdfiumLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
        const ['PDFium'], await rootBundle.loadString(pdfiumLicensesAsset));
  });
}
