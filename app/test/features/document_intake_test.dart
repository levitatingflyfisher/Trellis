import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/intake/document_intake.dart';

import '../support/pdf_pages.dart';

/// "Import a file" (1.6.0): one door in the Library for every kind of
/// book or document Trellis reads, routed by the file's ending.
void main() {
  late AppDatabase db;
  late int profileId;
  late Directory dir;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
    dir = Directory.systemTemp.createTempSync('trellis-document-intake');
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  test('a file ending in .pdf, in any case, is read as a PDF', () async {
    final id = await importDocumentFile(
        db: db,
        profileId: profileId,
        path: '${dir.path}/Tides.PDF',
        name: 'Tides.PDF',
        readPdf: (_) => (
              pages: [
                pdfProsePage('Tide Tables', ['Words of the body here.']),
              ],
              metaTitle: null,
            ));

    final work = (await db.spineDao.worksOf(profileId)).single;
    expect(work.id, id);
    expect(work.title, 'Tide Tables');
  });

  test('anything else is read as an EPUB, and one that isn’t says so',
      () async {
    final file = File('${dir.path}/book.epub')..writeAsStringSync('not a zip');

    await expectLater(
        importDocumentFile(
            db: db, profileId: profileId, path: file.path, name: 'book.epub'),
        throwsFormatException);
    expect(await db.spineDao.worksOf(profileId), isEmpty);
  });

  test('the picker offers PDF beside EPUB, and says so', () {
    expect(importableExtensions, containsAll(['epub', 'pdf']));
    expect(importableKindsWords, contains('PDF'));
  });
}
