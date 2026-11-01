import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_core/study_core.dart' as study;
import 'package:trellis/db/database.dart';
import 'package:trellis/features/study/course_map_screen.dart';

/// The export affordance on the course map: one tap builds a real `.apkg`
/// and hands it to the save seam — widget tests fake the destination (a
/// temp dir), never a real picker (platform channels stay behind seams).
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  String courseJson({String? image}) => json.encode({
        'schemaVersion': '1.0',
        'id': 'anki-c',
        'title': 'My Course',
        'nodes': [
          {
            'id': 'n1',
            'title': 'Node One',
            'intake': 'Read.',
            'items': [
              {
                'id': 'z1',
                'type': 'cloze',
                'rung': 1,
                'text': 'The sky is {{c1::blue}}.',
                'answers': {'c1': 'blue'},
                'image': ?image,
              },
            ],
          },
        ],
      });

  testWidgets('the export button writes a valid .apkg through the seam',
      (tester) async {
    await db.profilesDao.create('Ada');
    final rowId =
        await db.studyDao.importCourse(profileId: 1, raw: courseJson(), nowMs: 1);
    final row = (await db.studyDao.coursesOf(1)).single;
    expect(row.id, rowId);

    // Sync IO only inside the fake-async zone: a real-async temp-dir future
    // would never complete here (the fake_async landmine, again).
    final dir = Directory.systemTemp.createTempSync('apkg_seam');
    addTearDown(() => dir.deleteSync(recursive: true));
    final savedNames = <String>[];
    Future<bool> saveToTemp(String fileName, Uint8List bytes) async {
      savedNames.add(fileName);
      File('${dir.path}/$fileName').writeAsBytesSync(bytes);
      return true;
    }

    await tester.pumpWidget(MaterialApp(
        home: CourseMapScreen(
            db: db,
            courseRow: row,
            course: study.parseCourseString(courseJson()),
            saveApkg: saveToTemp)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('export-anki')), findsOneWidget);
    // Real bytes are built inside the tap handler (file IO + sqlite): tap in
    // the fake zone, then grant the real event loop time in runAsync slices
    // (guarded APIs like tap must never run INSIDE runAsync — deadlock).
    await tester.tap(find.byKey(const Key('export-anki')));
    await tester.pump();
    for (var i = 0; i < 30 && !tester.any(find.byType(SnackBar)); i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }

    expect(savedNames, ['anki-c.apkg']);
    final bytes = File('${dir.path}/anki-c.apkg').readAsBytesSync();
    final zip = ZipDecoder().decodeBytes(bytes);
    expect(zip.findFile('collection.anki2'), isNotNull);
    expect(zip.findFile('media'), isNotNull);
    expect(find.textContaining('anki-c.apkg'), findsOneWidget,
        reason: 'a calm confirmation names the file that was written');
  });

  testWidgets('a cancelled save stays silent', (tester) async {
    await db.profilesDao.create('Ada');
    await db.studyDao.importCourse(profileId: 1, raw: courseJson(), nowMs: 1);
    final row = (await db.studyDao.coursesOf(1)).single;

    await tester.pumpWidget(MaterialApp(
        home: CourseMapScreen(
            db: db,
            courseRow: row,
            course: study.parseCourseString(courseJson()),
            saveApkg: (name, bytes) async => false)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('export-anki')));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }

    expect(find.byType(SnackBar), findsNothing,
        reason: 'the user said no — nothing to celebrate, nothing to nag');
  });

  testWidgets('a card’s picture goes into the .apkg as Anki media',
      (tester) async {
    final sky = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2]);
    late CourseRow row;
    await tester.runAsync(() async {
      await db.profilesDao.create('Ada');
      await db.studyDao.putCardImage('sky.png', sky);
      await db.studyDao.importCourse(
          profileId: 1, raw: courseJson(image: 'sky.png'), nowMs: 1);
      row = (await db.studyDao.coursesOf(1)).single;
    });
    Uint8List? saved;
    await tester.pumpWidget(MaterialApp(
        home: CourseMapScreen(
            db: db,
            courseRow: row,
            course: study.parseCourseString(row.raw),
            saveApkg: (name, bytes) async {
              saved = bytes;
              return true;
            })));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('export-anki')));
    await tester.pump();
    for (var i = 0; i < 30 && saved == null; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    final zip = ZipDecoder().decodeBytes(saved!);
    expect(
        jsonDecode(utf8.decode(zip.findFile('media')!.content as List<int>)),
        {'0': 'sky.png'});
    expect(zip.findFile('0')!.content, sky);
  });
}

