/// PDFium behind the [PdfReader] seam (1.6.0), over dart:ffi as whisper
/// is. Only text is read here: each page's characters with their boxes
/// and font sizes, which intake_core's `pdfToBlocks` rebuilds into
/// reading order. Nothing is rendered and nothing in the file is run:
/// PDFium is built without JavaScript or XFA.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:intake_core/intake_core.dart' show PdfPageChars;
import 'package:pdfium_flutter/pdfium_flutter.dart'
    show FPDF_DOCUMENT, PDFium;

import 'pdf_reader.dart';

/// Whether this build can read PDFs at all; the picker and the share
/// sheet offer PDF only where it is true.
const pdfReadingAvailable = true;

/// Where PDFium lives: the APK's jniLibs resolve the bare soname;
/// desktops may point `TRELLIS_PDFIUM_LIB` at a build.
String pdfiumLibraryPath() {
  final env = Platform.environment['TRELLIS_PDFIUM_LIB'];
  if (env != null && env.isNotEmpty) return env;
  return 'libpdfium.so';
}

PDFium? _pdfium;

PDFium _bindings() {
  final existing = _pdfium;
  if (existing != null) return existing;
  final PDFium lib;
  try {
    lib = PDFium(DynamicLibrary.open(pdfiumLibraryPath()));
  } on ArgumentError {
    throw const PdfUnreadableException(
        'This build of Trellis can’t open PDFs.');
  }
  // Process-wide and safe to repeat: PDFium ignores a second call.
  lib.FPDF_InitLibrary();
  return _pdfium = lib;
}

/// PDFium's FPDF_ERR_PASSWORD.
const _errPassword = 4;

/// Reads the PDF at [path] with PDFium. Throws [PdfUnreadableException]
/// for a file that is not a PDF, is locked with a password, or is longer
/// than [maxPdfPages].
PdfRead readPdfWithPdfium(String path) {
  final pdfium = _bindings();
  final pathPtr = path.toNativeUtf8();
  final doc = pdfium.FPDF_LoadDocument(pathPtr.cast(), nullptr);
  calloc.free(pathPtr);
  if (doc == nullptr) {
    throw PdfUnreadableException(pdfium.FPDF_GetLastError() == _errPassword
        ? 'That PDF is locked with a password, so Trellis can’t open it.'
        : 'That file couldn’t be read as a PDF.');
  }
  final box = calloc<Double>(4);
  try {
    final count = pdfium.FPDF_GetPageCount(doc);
    if (count > maxPdfPages) {
      throw PdfUnreadableException(
          'That PDF has $count pages. Trellis reads PDFs of up to '
          '$maxPdfPages pages.');
    }
    final pages = <PdfPageChars>[
      for (var i = 0; i < count; i++) _readPage(pdfium, doc, i, box),
    ];
    return (pages: pages, metaTitle: _metaTitle(pdfium, doc));
  } finally {
    calloc.free(box);
    pdfium.FPDF_CloseDocument(doc);
  }
}

PdfPageChars _empty(double w, double h) => PdfPageChars(
    width: w, height: h, text: '', boxes: Float32List(0), sizes: Float32List(0));

PdfPageChars _readPage(
    PDFium pdfium, FPDF_DOCUMENT doc, int index, Pointer<Double> box) {
  final page = pdfium.FPDF_LoadPage(doc, index);
  if (page == nullptr) return _empty(612, 792);
  try {
    final width = pdfium.FPDF_GetPageWidthF(page);
    final height = pdfium.FPDF_GetPageHeightF(page);
    final rotation = pdfium.FPDFPage_GetRotation(page);
    final text = pdfium.FPDFText_LoadPage(page);
    if (text == nullptr) return _empty(width, height);
    try {
      final n = pdfium.FPDFText_CountChars(text);
      final units = <int>[];
      final boxes = <double>[];
      final sizes = <double>[];
      for (var i = 0; i < n; i++) {
        final code = pdfium.FPDFText_GetUnicode(text, i);
        var l = 0.0, b = 0.0, r = 0.0, t = 0.0;
        if (pdfium.FPDFText_GetCharBox(text, i, box, box + 1, box + 2, box + 3) !=
            0) {
          // PDFium's order is left, right, bottom, top.
          (l, b, r, t) = _turned(
              box[0], box[2], box[1], box[3], rotation, width, height);
        }
        final size = pdfium.FPDFText_GetFontSize(text, i);
        void put(int unit) {
          units.add(unit);
          boxes..add(l)..add(b)..add(r)..add(t);
          sizes.add(size);
        }

        if (code > 0xFFFF && code <= 0x10FFFF) {
          final v = code - 0x10000;
          put(0xD800 + (v >> 10));
          put(0xDC00 + (v & 0x3FF));
        } else {
          put(code & 0xFFFF);
        }
      }
      return PdfPageChars(
          width: width,
          height: height,
          text: String.fromCharCodes(units),
          boxes: Float32List.fromList(boxes),
          sizes: Float32List.fromList(sizes));
    } finally {
      pdfium.FPDFText_ClosePage(text);
    }
  } finally {
    pdfium.FPDF_ClosePage(page);
  }
}

/// A character box as the reader sees it. PDFium gives boxes in the
/// page's own space, before its /Rotate is applied; [width] and [height]
/// are the page as shown.
(double, double, double, double) _turned(double l, double b, double r,
    double t, int rotation, double width, double height) {
  switch (rotation) {
    case 1: // a quarter turn clockwise
      return (b, height - r, t, height - l);
    case 2:
      return (width - r, height - t, width - l, height - b);
    case 3: // a quarter turn anticlockwise
      return (width - t, l, width - b, r);
    default:
      return (l, b, r, t);
  }
}

String? _metaTitle(PDFium pdfium, FPDF_DOCUMENT doc) {
  final tag = 'Title'.toNativeUtf8();
  try {
    final bytes = pdfium.FPDF_GetMetaText(doc, tag.cast(), nullptr, 0);
    if (bytes <= 2 || bytes > 4096) return null;
    final buffer = calloc<Uint8>(bytes);
    try {
      pdfium.FPDF_GetMetaText(doc, tag.cast(), buffer.cast(), bytes);
      // UTF-16LE with a closing zero.
      final units = buffer.cast<Uint16>().asTypedList(bytes ~/ 2 - 1);
      final title = String.fromCharCodes(units).trim();
      return title.isEmpty ? null : title;
    } finally {
      calloc.free(buffer);
    }
  } finally {
    calloc.free(tag);
  }
}
