import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:intake_core/intake_core.dart';

import '../../db/database.dart';
import 'epub_flatten.dart';
import 'paste_intake.dart' show epochDayUtcNow;

/// Stores parsed EPUB bytes as one spine work (the testable seam — no
/// platform channel in sight). Returns the new work id.
///
/// Throws [FormatException] on a structurally invalid EPUB, exactly as
/// intake_core's parser does; callers surface that calmly.
Future<int> importEpubBytes(
    {required AppDatabase db,
    required int profileId,
    required List<int> bytes,
    String? sourceName}) async {
  final doc = parseEpub(bytes, sourceName: sourceName);
  final workId = await db.spineDao.insertWork(
      profileId: profileId,
      kind: 'book',
      title: doc.title,
      persistence: 'work',
      firstSeenEpochDay: epochDayUtcNow());
  await db.spineDao.insertSegments(workId, flattenEpub(doc));
  return workId;
}

/// The thin file_picker wrapper: pick one .epub, delegate to
/// [importEpubBytes]. Returns null when the picker is dismissed.
Future<int?> pickAndImportEpub(
    {required AppDatabase db, required int profileId}) async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['epub'],
    withData: true,
  );
  final file = result?.files.firstOrNull;
  if (file == null) return null;
  final bytes = file.bytes ?? await File(file.path!).readAsBytes();
  return importEpubBytes(
      db: db, profileId: profileId, bytes: bytes, sourceName: file.name);
}
