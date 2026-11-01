/// "Import a file" (1.6.0): one door in the Library for every kind of
/// book or document Trellis reads, routed by the file's ending.
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../../db/database.dart';
import 'epub_intake.dart';
import 'pdf_intake.dart';
import 'pdf_reader.dart';
import 'text_intake.dart';

/// The file endings the picker offers. PDF only where PDFium can run.
const importableExtensions = [
  'epub',
  if (pdfReadingAvailable) 'pdf',
  'md',
  'markdown',
  'txt',
];

/// The same, as the words under "Import a file".
const importableKindsWords = pdfReadingAvailable
    ? 'EPUB, PDF, Markdown or text'
    : 'EPUB, Markdown or text';

String _endingOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

/// Imports the file at [path] as what its [name] says it is, and returns
/// the new work's id. Throws [FormatException] when it can't be read as
/// that; a [PdfUnreadableException], [EpubTooLargeException] or
/// [TextTooLargeException] carries
/// words fit to show as they are. [readPdf] stands in for PDFium in
/// tests.
Future<int> importDocumentFile(
    {required AppDatabase db,
    required int profileId,
    required String path,
    required String name,
    PdfReader? readPdf}) {
  if (_endingOf(name) == 'pdf') {
    return importPdfFile(
        db: db,
        profileId: profileId,
        path: path,
        sourceName: name,
        read: readPdf);
  }
  if (isTextFileName(name)) {
    return importTextFile(db: db, profileId: profileId, path: path, name: name);
  }
  return importEpubFile(
      db: db, profileId: profileId, path: path, sourceName: name);
}

/// The thin file_picker wrapper: pick one file of a kind Trellis reads
/// and import it. Returns null when the picker is dismissed.
Future<int?> pickAndImportDocument(
    {required AppDatabase db, required int profileId}) async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: importableExtensions,
    // Natively the bytes would cross the platform channel only to be read
    // again; the path is enough.
    withData: kIsWeb,
  );
  final file = result?.files.firstOrNull;
  if (file == null) return null;
  final path = kIsWeb ? null : file.path;
  if (path != null) {
    return importDocumentFile(
        db: db, profileId: profileId, path: path, name: file.name);
  }
  // The web tier: a picked file has no path, only its bytes.
  if (isTextFileName(file.name)) {
    return importTextBytes(
        db: db, profileId: profileId, bytes: file.bytes!, name: file.name);
  }
  return importEpubBytes(
      db: db, profileId: profileId, bytes: file.bytes!, sourceName: file.name);
}
