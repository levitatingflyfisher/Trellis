import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intake_core/intake_core.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/intake/epub_intake.dart';

List<int> _zip(Map<String, String> files) {
  final a = Archive();
  for (final e in files.entries) {
    final bytes = utf8.encode(e.value);
    a.addFile(ArchiveFile(e.key, bytes.length, bytes));
  }
  return ZipEncoder().encode(a);
}

List<int> _book(String body) => _zip({
      'mimetype': 'application/epub+zip',
      'META-INF/container.xml': '<?xml version="1.0"?><container '
          'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
          '<rootfiles><rootfile full-path="content.opf"/></rootfiles>'
          '</container>',
      'content.opf': '<?xml version="1.0"?><package '
          'xmlns="http://www.idpf.org/2007/opf" version="3.0">'
          '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
          '<dc:title>Small Book</dc:title></metadata><manifest>'
          '<item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>'
          '</manifest><spine><itemref idref="c1"/></spine></package>',
      'c1.xhtml': '<html xmlns="http://www.w3.org/1999/xhtml"><body>'
          '<h1>One</h1><p>$body</p></body></html>',
    });

/// EPUB intake runs its parse on another isolate (ADR-0017); what lands
/// in the database is the same either way.
void main() {
  late AppDatabase db;
  late int profileId;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
  });
  tearDown(() => db.close());

  test('bytes import as one book with its segments', () async {
    final id = await importEpubBytes(
        db: db, profileId: profileId, bytes: _book('Hello there, reader. ${'word ' * 80}'));
    final work = (await db.select(db.works).get()).single;
    expect(work.id, id);
    expect(work.title, 'Small Book');
    final segs = await (db.select(db.segments)
          ..where((s) => s.workId.equals(id)))
        .get();
    expect(segs.map((s) => s.body).join(' '), contains('Hello there'));
  });

  test('a file imports by path, the same as its bytes', () async {
    final dir = Directory.systemTemp.createTempSync('trellis-epub');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/b.epub')..writeAsBytesSync(_book('By path.'));
    await importEpubFile(db: db, profileId: profileId, path: f.path);
    expect((await db.select(db.works).get()).single.title, 'Small Book');
  });

  test('an invalid file is still a FormatException after the hop', () async {
    await expectLater(
        importEpubBytes(db: db, profileId: profileId, bytes: [1, 2, 3]),
        throwsA(isA<FormatException>()));
    expect(await db.select(db.works).get(), isEmpty);
  });

  test('a book that declares more than the cap is refused in plain words',
      () async {
    // A real 200 MB entry, cheap to compress: zeros deflate to ~200 kB.
    final a = Archive();
    final zeros = List<int>.filled(maxEpubUncompressedBytes + 1, 0);
    a.addFile(ArchiveFile('bomb.bin', zeros.length, zeros));
    final bomb = ZipEncoder().encode(a);
    await expectLater(
        importEpubBytes(db: db, profileId: profileId, bytes: bomb),
        throwsA(isA<EpubTooLargeException>()
            .having((e) => e.message, 'message', contains('200 MB'))));
  });
}
