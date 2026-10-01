import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:intake_core/intake_core.dart';

import '../../db/database.dart';
import 'epub_flatten.dart';
import 'paste_intake.dart' show epochDayUtcNow;

typedef _ParsedEpub = ({String title, List<SegmentRow> segments});

/// Stores parsed EPUB bytes as one spine work (the testable seam — no
/// platform channel in sight). Returns the new work id.
///
/// Throws [FormatException] on a structurally invalid EPUB, exactly as
/// intake_core's parser does; callers surface that calmly. An
/// [EpubTooLargeException] (also a [FormatException]) carries words fit
/// to show as they are.
Future<int> importEpubBytes(
        {required AppDatabase db,
        required int profileId,
        required List<int> bytes,
        String? sourceName}) async =>
    _store(db, profileId,
        await compute(_parseBytes, (bytes: bytes, name: sourceName)));

/// [importEpubBytes] from a file on disk: only the path crosses to the
/// parsing isolate, so the book's bytes are never copied between isolates
/// or held twice.
Future<int> importEpubFile(
        {required AppDatabase db,
        required int profileId,
        required String path,
        String? sourceName}) async =>
    _store(db, profileId,
        await compute(_parseFile, (path: path, name: sourceName)));

Future<int> _store(AppDatabase db, int profileId, _ParsedEpub parsed) async {
  final workId = await db.spineDao.insertWork(
      profileId: profileId,
      kind: 'book',
      title: parsed.title,
      persistence: 'work',
      firstSeenEpochDay: epochDayUtcNow());
  await db.spineDao.insertSegments(workId, parsed.segments);
  return workId;
}

// Unzipping, parsing every chapter's HTML and flattening it is seconds of
// work for a big book; [compute] keeps it off the UI isolate natively and
// runs it inline on the web, which has no isolates. Top-level, so the
// message holds only data.
_ParsedEpub _parseBytes(({List<int> bytes, String? name}) m) {
  final doc = parseEpub(m.bytes, sourceName: m.name);
  return (title: doc.title, segments: flattenEpub(doc));
}

_ParsedEpub _parseFile(({String path, String? name}) m) =>
    _parseBytes((bytes: File(m.path).readAsBytesSync(), name: m.name));

/// The thin file_picker wrapper: pick one .epub, delegate to
/// [importEpubFile] (native) or [importEpubBytes] (web, where a picked
/// file has no path). Returns null when the picker is dismissed.
Future<int?> pickAndImportEpub(
    {required AppDatabase db, required int profileId}) async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['epub'],
    // Natively the bytes would cross the platform channel only to be read
    // again; the path is enough.
    withData: kIsWeb,
  );
  final file = result?.files.firstOrNull;
  if (file == null) return null;
  final path = kIsWeb ? null : file.path;
  if (path != null) {
    return importEpubFile(
        db: db, profileId: profileId, path: path, sourceName: file.name);
  }
  return importEpubBytes(
      db: db, profileId: profileId, bytes: file.bytes!, sourceName: file.name);
}
