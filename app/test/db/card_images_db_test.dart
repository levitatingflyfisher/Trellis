import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:trellis/db/database.dart';

import '../support/schema_strip.dart';

/// Pictures on cards (owner, 28 Oct) are kept in the database, named in
/// their course's text. A picture no course names any more goes when a
/// course is written or removed, so nothing piles up unseen.
void main() {
  late AppDatabase db;
  late int profileId;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
  });
  tearDown(() => db.close());

  String course(String id, {String? image}) => json.encode({
        'schemaVersion': '1.0',
        'id': id,
        'title': id,
        'nodes': [
          {
            'id': 'n1',
            'title': 'Step',
            'intake': '',
            'items': [
              {
                'id': 'i1',
                'type': 'qa',
                'rung': 3,
                'prompt': 'What is this?',
                'answer': 'A heron.',
                'image': ?image,
              },
            ],
          },
        ],
      });

  final heron = Uint8List.fromList([1, 2, 3]);
  final marsh = Uint8List.fromList([4, 5, 6]);

  test('a picture is kept once by name, and read back', () async {
    await db.studyDao.putCardImage('heron.png', heron);
    await db.studyDao.putCardImage('heron.png', heron);
    expect(await db.studyDao.cardImage('heron.png'), heron);
    expect(await db.studyDao.cardImage('none.png'), isNull);
    expect(await db.studyDao.cardImagesNamed(['heron.png', 'none.png']),
        {'heron.png': heron});
  });

  test('writing a course lets go of pictures no course names', () async {
    final row = await db.studyDao.importCourse(
        profileId: profileId, raw: course('c1', image: 'heron.png'), nowMs: 1);
    await db.studyDao.putCardImage('heron.png', heron);
    await db.studyDao.putCardImage('marsh.png', marsh);
    // A picture picked in the editor waits for the save that names it.
    await db.studyDao
        .saveCourseRaw(row, course('c1', image: 'marsh.png'));
    expect(await db.studyDao.cardImage('marsh.png'), marsh);
    expect(await db.studyDao.cardImage('heron.png'), isNull);
  });

  test('a picture two courses name stays until neither does', () async {
    final a = await db.studyDao.importCourse(
        profileId: profileId, raw: course('a', image: 'heron.png'), nowMs: 1);
    await db.studyDao.importCourse(
        profileId: profileId, raw: course('b', image: 'heron.png'), nowMs: 1);
    await db.studyDao.putCardImage('heron.png', heron);
    await db.studyDao.deleteCourse(a);
    expect(await db.studyDao.cardImage('heron.png'), heron);
    final b = (await db.studyDao.courseRowOf(profileId, 'b'))!.id;
    await db.studyDao.deleteCourse(b);
    expect(await db.studyDao.cardImage('heron.png'), isNull);
  });

  test('schema migration v33 -> v34 adds the pictures table, keeping every '
      'course', () async {
    final dir = Directory.systemTemp.createTempSync('trellis-migration-v34');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/v33.sqlite');
    final seed = AppDatabase.forTesting(NativeDatabase(file));
    final p = await seed.profilesDao.create('Ada');
    await seed.studyDao.importCourse(profileId: p, raw: course('c1'), nowMs: 1);
    await seed.close();

    final v33 = raw.sqlite3.open(file.path);
    v33.execute('$stripV34\nPRAGMA user_version = 33;');
    v33.dispose();

    final migrated = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(migrated.close);
    expect((await migrated.studyDao.coursesOf(p)).single.courseId, 'c1');
    await migrated.studyDao.putCardImage('heron.png', heron);
    expect(await migrated.studyDao.cardImage('heron.png'), heron);
  });
}
