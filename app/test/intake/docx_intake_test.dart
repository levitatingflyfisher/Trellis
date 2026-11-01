import 'dart:io';

import 'package:comms_core/comms_core.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/intake/document_intake.dart';
import 'package:trellis/features/intake/docx_intake.dart';
import 'package:trellis/features/intake/share_intake.dart';

import '../support/docx_fixture.dart';

void main() {
  late AppDatabase db;
  late int profileId;
  late Directory dir;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
    dir = Directory.systemTemp.createTempSync('trellis-docx-intake');
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> expectTheBook(int id, {String title = 'Iceland'}) async {
    final work = (await db.spineDao.workById(id))!;
    expect(work.title, title);
    expect(work.kind, 'book');
    expect(work.persistence, 'work');
    final segs = await db.spineDao.segmentsOf(id);
    expect([for (final s in segs) '${s.kind}: ${s.body}'], [
      'heading: Saga-Period Iceland',
      'prose: If you killed someone, his relatives sued you.¹',
      'heading: Notes',
      'prose: ¹ Njal’s saga.',
    ]);
    final links = await db.spineDao.linksOf(id);
    expect([for (final l in links) (l.segIdx, l.startChar, l.endChar, l.href)],
        [(1, 42, 45, 'https://example.org/iceland')]);
  }

  test('Import a file reads a .docx as a book, any case of the ending',
      () async {
    final file = File('${dir.path}/Iceland.DOCX')..writeAsBytesSync(tinyDocx());
    final id = await importDocumentFile(
        db: db, profileId: profileId, path: file.path, name: 'Iceland.DOCX');
    await expectTheBook(id);
    expect(importableExtensions, contains('docx'));
    expect(importableKindsWords, contains('Word'));
  });

  test('a .docx that is not one says so in words, and stores nothing',
      () async {
    final file = File('${dir.path}/old.docx')..writeAsStringSync('not a zip');
    await expectLater(
        importDocumentFile(
            db: db, profileId: profileId, path: file.path, name: 'old.docx'),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('Word document'))));
    expect(await db.spineDao.worksOf(profileId), isEmpty);
  });

  test('a .docx shared or opened with Trellis lands in the Library',
      () async {
    final file = File('${dir.path}/shared-copy')..writeAsBytesSync(tinyDocx());
    final out = await ShareIntake(
      db: db,
      profileId: profileId,
      fetcher: _NoNetwork(),
      discard: (_) {},
    ).take(SharedPayload(files: [
      SharedFile(path: file.path, name: 'Iceland.docx', mimeType: docxMimeType),
    ]));
    final saved = out as ShareSaved;
    expect(saved.inLatest, isFalse);
    await expectTheBook(saved.workId);
  });

  test('the name or the type alone says a file is a .docx', () {
    expect(isDocxName('a.docx'), isTrue);
    expect(isDocxName('download', mimeType: docxMimeType), isTrue);
    expect(isDocxName('a.doc'), isFalse);
  });
}

class _NoNetwork implements HttpFetcher {
  @override
  Future<FetchResponse> get(Uri url,
          {Map<String, String>? headers, Duration? timeout}) =>
      throw StateError('no fetch expected');
}
