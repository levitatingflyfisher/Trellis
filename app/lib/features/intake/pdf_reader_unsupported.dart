/// The web tier's PDF reader: there is none. PDFium is a native library,
/// so PDF intake is offered only where it can run.
library;

import 'pdf_reader.dart';

/// Whether this build can read PDFs at all; the picker and the share
/// sheet offer PDF only where it is true.
const pdfReadingAvailable = false;

PdfRead readPdfWithPdfium(String path) => throw const PdfUnreadableException(
    'PDFs can be opened in the Android app, not in the browser.');
