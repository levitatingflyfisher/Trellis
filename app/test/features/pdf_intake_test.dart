import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/intake/pdf_intake.dart';
import 'package:trellis/features/intake/pdf_reader.dart';

import '../support/pdf_pages.dart';

/// PDF intake (1.6.0, owner: "also read other formats like PDF please"):
/// a PDF with a text layer becomes a book in the Library, as an EPUB
/// does. PDFium itself is behind [PdfReader]; these tests hand pages in.
void main() {
  late AppDatabase db;
  late int profileId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
  });
  tearDown(() => db.close());

  Future<int> import(PdfRead read, {String? name = 'harbour.pdf'}) =>
      importPdfFile(
          db: db,
          profileId: profileId,
          path: '/nowhere/$name',
          sourceName: name,
          read: (_) => read);

  test('a PDF with text becomes a book: its headings and paragraphs are '
      'the work’s segments, in order', () async {
    final id = await import((
      pages: [
        pdfProsePage('The Harbour', [
          'The harbour was quiet that',
          'morning, and the boats lay',
          'still on the water.',
        ]),
      ],
      metaTitle: null,
    ));

    final work =
        (await db.spineDao.worksOf(profileId)).singleWhere((w) => w.id == id);
    expect(work.kind, 'book');
    expect(work.title, 'The Harbour');
    expect(work.persistence, 'work');
    final segments = await db.spineDao.segmentsOf(id);
    expect([for (final s in segments) (s.idx, s.kind, s.body)], [
      (0, 'heading', 'The Harbour'),
      (
        1,
        'prose',
        'The harbour was quiet that morning, and the boats lay still on '
            'the water.'
      ),
    ]);
    expect(await db.feedsDao.notesOf(id), isNull,
        reason: 'nothing to say about a clean file');
  });

  test('a file that is pictures of pages is refused in plain words, and '
      'nothing is stored', () async {
    await expectLater(
        import((pages: [pdfPage([]), pdfPage([])], metaTitle: 'Scan')),
        throwsA(isA<PdfUnreadableException>().having((e) => e.message,
            'message',
            'This PDF is pictures of pages, with no text Trellis can read.')));

    expect(await db.spineDao.worksOf(profileId), isEmpty);
  });

  test('what the reader could not open is said as the reader said it, and '
      'nothing is stored', () async {
    await expectLater(
        importPdfFile(
            db: db,
            profileId: profileId,
            path: '/nowhere/x.pdf',
            read: (_) => throw const PdfUnreadableException(
                'That PDF is locked with a password, so Trellis can’t open '
                'it.')),
        throwsA(isA<PdfUnreadableException>()
            .having((e) => e.message, 'message', contains('password'))));

    expect(await db.spineDao.worksOf(profileId), isEmpty);
  });

  test('pages that are pictures, and pages whose order is the file’s own, '
      'are named on the work’s page', () async {
    final id = await import((
      pages: [
        pdfProsePage('Tide Tables', ['Words of the body here.', 'And more.']),
        pdfPage([]),
        pdfPage([]),
        pdfPage([
          pdfLine(40, 700, 'One one one.'),
          pdfLine(230, 700, 'Two two two.'),
          pdfLine(420, 700, 'Three three.'),
          pdfLine(40, 660, 'Four four.'),
          pdfLine(230, 660, 'Five five.'),
          pdfLine(420, 660, 'Six six six.'),
        ]),
      ],
      metaTitle: null,
    ));

    final notes = await db.feedsDao.notesOf(id);
    expect(notes!.plain, contains('From a PDF of 4 pages.'));
    expect(
        notes.plain,
        contains('Pages 2–3 are pictures, with no text Trellis can read.'));
    expect(
        notes.plain,
        contains('The layout of page 4 couldn’t be worked out, so it is in '
            'the order the file gives.'));
    expect(notes.html, contains('<p>'));
  });

  test('pages are named in ranges, plainly', () {
    expect(pagesPhrase([3]), 'page 3');
    expect(pagesPhrase([3, 7]), 'pages 3 and 7');
    expect(pagesPhrase([3, 4, 5, 9, 11, 12]), 'pages 3–5, 9 and 11–12');
  });
}
