import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/intake/document_intake.dart';
import 'package:trellis/features/intake/text_intake.dart';

/// Markdown and plain text files (owner, 1.6.x: "tried to open a markdown
/// file in Trellis and could not"): "Import a file" takes .md, .markdown
/// and .txt, and a Markdown file is read as Markdown.
void main() {
  late AppDatabase db;
  late int profileId;
  late Directory dir;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
    dir = Directory.systemTemp.createTempSync('trellis-text-intake');
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<(Work, List<(String, String)>)> import(String name, String text) async {
    final file = File('${dir.path}/$name')..writeAsStringSync(text);
    final id = await importDocumentFile(
        db: db, profileId: profileId, path: file.path, name: name);
    final work =
        (await db.spineDao.worksOf(profileId)).singleWhere((w) => w.id == id);
    return (
      work,
      [for (final s in await db.spineDao.segmentsOf(id)) (s.kind, s.body)]
    );
  }

  test('a Markdown file becomes a work whose headings are headings and '
      'whose markup is gone', () async {
    final (work, segments) = await import('Tide notes.md', '''
# The Harbour

It was **very** quiet. See the [tables](https://example.org/tides).

- a coat
- a hat

```
make all
```
''');

    expect(work.title, 'The Harbour');
    expect(work.persistence, 'work');
    expect(segments, [
      ('heading', 'The Harbour'),
      ('prose', 'It was very quiet. See the tables (https://example.org/tides).'),
      ('prose', '• a coat'),
      ('prose', '• a hat'),
      ('code', 'make all'),
    ]);
  });

  test('.markdown is Markdown too, in any case', () async {
    final (work, segments) = await import('NOTES.MARKDOWN', '## Part\n\nText.');

    expect(work.title, 'Part');
    expect(segments.first, ('heading', 'Part'));
  });

  test('a Markdown file with no heading is named for the file', () async {
    final (work, _) = await import('Tide notes.md', 'Just some words.');

    expect(work.title, 'Tide notes');
  });

  test('a .txt file is read as plain text, named for the file, with a '
      'hash left as the writer typed it', () async {
    final (work, segments) =
        await import('list.txt', 'Call #4 on the list.\n\nThen go home.');

    expect(work.title, 'list');
    expect(segments, [
      ('prose', 'Call #4 on the list.'),
      ('prose', 'Then go home.'),
    ]);
  });

  test('a text file too large to hold in memory is refused in words',
      () async {
    final file = File('${dir.path}/big.md')
      ..writeAsBytesSync(List.filled(maxTextFileBytes + 1, 0x61));

    await expectLater(
        importDocumentFile(
            db: db, profileId: profileId, path: file.path, name: 'big.md'),
        throwsA(isA<TextTooLargeException>()
            .having((e) => e.message, 'message', contains('too large'))));
    expect(await db.spineDao.worksOf(profileId), isEmpty);
  });

  test('a file with nothing in it is refused', () async {
    final file = File('${dir.path}/empty.md')..writeAsStringSync('  \n');

    await expectLater(
        importDocumentFile(
            db: db, profileId: profileId, path: file.path, name: 'empty.md'),
        throwsFormatException);
  });

  test('the picker offers them, and says so', () {
    expect(importableExtensions,
        ['epub', 'pdf', 'md', 'markdown', 'txt']);
    expect(importableKindsWords, 'EPUB, PDF, Markdown or text');
  });
}
