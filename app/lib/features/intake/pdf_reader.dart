/// Reading a PDF's pages (1.6.0): the seam between the app and PDFium.
///
/// The native tiers read with PDFium through dart:ffi
/// (`pdf_reader_native.dart`); the web tier has no PDFium and says so
/// (`pdf_reader_unsupported.dart`), so its dart2js build never sees a
/// Pointer. The real file stays the DEFAULT branch, as whisper_ffi's
/// does: the analyzer only resolves defaults.
library;

import 'package:intake_core/intake_core.dart' show PdfPageChars;

export 'pdf_reader_native.dart'
    if (dart.library.js_interop) 'pdf_reader_unsupported.dart';

/// What a PDF holds: every page's characters, and the file's own Title
/// field when it has one.
typedef PdfRead = ({List<PdfPageChars> pages, String? metaTitle});

/// Reads the PDF at a path, whole. Runs to completion on the isolate it
/// is called on, so callers keep it off the UI isolate.
typedef PdfReader = PdfRead Function(String path);

/// A PDF that could not be turned into a work. [message] is a sentence
/// fit to show as it is.
class PdfUnreadableException extends FormatException {
  const PdfUnreadableException(super.message);
}

/// The longest PDF read: its characters are all held at once while the
/// reading order is worked out.
const maxPdfPages = 3000;
