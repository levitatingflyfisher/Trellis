import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:study_core/study_core.dart';
import 'package:trellis/db/database.dart';

/// The study slice's storage contract (proposal-2 §6): a course row is the
/// verbatim `.ohcourse` text (study_core's strict parser is the single
/// authority — a file that doesn't parse leaves ZERO rows behind), a card row
/// is one item's SRS state, and the revlog is an append-only fold source —
/// the DAO exposes append and read, nothing that mutates or deletes.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<int> seedProfile() => db.profilesDao.create('Ada');

  String courseJson({String id = 'c1', String title = 'Course One'}) =>
      json.encode({
        'schemaVersion': '1.0',
        'id': id,
        'title': title,
        'nodes': [
          {
            'id': 'n1',
            'title': 'Node One',
            'intake': 'Read this.',
            'items': [
              {
                'id': 'i1',
                'type': 'cloze',
                'rung': 1,
                'text': 'The sky is {{c1::blue}}.',
                'answers': {'c1': 'blue'},
              },
            ],
          },
        ],
      });

  group('course import', () {
    test('a valid .ohcourse lands verbatim with title and timestamp',
        () async {
      final profileId = await seedProfile();
      final rawText = courseJson();
      final id = await db.studyDao
          .importCourse(profileId: profileId, raw: rawText, nowMs: 1234);

      final rows = await db.studyDao.coursesOf(profileId);
      final row = rows.single;
      expect(row.id, id);
      expect(row.courseId, 'c1');
      expect(row.title, 'Course One');
      expect(row.raw, rawText, reason: 'the stored text is the file, verbatim');
      expect(row.importedAtMs, 1234);
    });

    test('invalid JSON throws the parser error and imports NOTHING', () async {
      final profileId = await seedProfile();
      await expectLater(
          db.studyDao.importCourse(
              profileId: profileId, raw: 'not json at all', nowMs: 0),
          throwsFormatException);
      expect(await db.studyDao.coursesOf(profileId), isEmpty,
          reason: 'the parser law: never a half-import');
    });

    test('a structurally bad course (unknown item type) imports NOTHING',
        () async {
      final profileId = await seedProfile();
      final bad = json.encode({
        'schemaVersion': '1.0',
        'id': 'c-bad',
        'title': 'Bad',
        'nodes': [
          {
            'id': 'n1',
            'title': 'N',
            'intake': 'x',
            'items': [
              {'id': 'i1', 'type': 'essay', 'rung': 1},
            ],
          },
        ],
      });
      await expectLater(
          db.studyDao.importCourse(profileId: profileId, raw: bad, nowMs: 0),
          throwsFormatException);
      expect(await db.studyDao.coursesOf(profileId), isEmpty);
    });

    test('re-importing the same course id replaces the body, keeps the cards',
        () async {
      final profileId = await seedProfile();
      final id = await db.studyDao
          .importCourse(profileId: profileId, raw: courseJson(), nowMs: 1);
      await db.studyDao.recordGrade(
          courseRowId: id,
          before: CardState.initial('i1', const SrsDefaults(), 100),
          after: const CardState(
              itemId: 'i1',
              ease: 2.5,
              intervalDays: 1,
              dueEpochDay: 101,
              reps: 1,
              lapses: 0),
          grade: Grade.good,
          tsMs: 5);

      final again = await db.studyDao.importCourse(
          profileId: profileId,
          raw: courseJson(title: 'Course One, revised'),
          nowMs: 2);
      expect(again, id, reason: 'same course id, same row');

      final rows = await db.studyDao.coursesOf(profileId);
      expect(rows.single.title, 'Course One, revised');
      final cards = await db.studyDao.loadCardStates(id);
      expect(cards['i1']!.intervalDays, 1,
          reason: 'a re-import never wipes learning history');
    });

    test('two profiles import the same course independently', () async {
      final a = await seedProfile();
      final b = await db.profilesDao.create('Beatrix');
      final rowA =
          await db.studyDao.importCourse(profileId: a, raw: courseJson(), nowMs: 1);
      final rowB =
          await db.studyDao.importCourse(profileId: b, raw: courseJson(), nowMs: 2);
      expect(rowA, isNot(rowB));
      expect(await db.studyDao.coursesOf(a), hasLength(1));
      expect(await db.studyDao.coursesOf(b), hasLength(1));
    });
  });

  group('cards and revlog', () {
    test('card state round-trips through its JSON column', () async {
      final profileId = await seedProfile();
      final id = await db.studyDao
          .importCourse(profileId: profileId, raw: courseJson(), nowMs: 1);

      expect(await db.studyDao.loadCardStates(id), isEmpty);

      const after = CardState(
          itemId: 'i1',
          ease: 2.36,
          intervalDays: 6,
          dueEpochDay: 106,
          reps: 2,
          lapses: 1);
      await db.studyDao.recordGrade(
          courseRowId: id,
          before: CardState.initial('i1', const SrsDefaults(), 100),
          after: after,
          grade: Grade.hard,
          tsMs: 9);

      final loaded = (await db.studyDao.loadCardStates(id))['i1']!;
      expect(loaded.ease, after.ease);
      expect(loaded.intervalDays, after.intervalDays);
      expect(loaded.dueEpochDay, after.dueEpochDay);
      expect(loaded.reps, after.reps);
      expect(loaded.lapses, after.lapses);
    });

    test('every grade APPENDS one revlog row; the card row is upserted',
        () async {
      final profileId = await seedProfile();
      final id = await db.studyDao
          .importCourse(profileId: profileId, raw: courseJson(), nowMs: 1);

      var state = CardState.initial('i1', const SrsDefaults(), 100);
      var next = scheduleSm2(state, Grade.good, 100);
      await db.studyDao.recordGrade(
          courseRowId: id, before: state, after: next, grade: Grade.good, tsMs: 10);
      state = next;
      next = scheduleSm2(state, Grade.again, 100);
      await db.studyDao.recordGrade(
          courseRowId: id, before: state, after: next, grade: Grade.again, tsMs: 20);

      final log = await db.studyDao.revlogOf(id);
      expect(log, hasLength(2), reason: 'one row per grade, none replaced');
      expect(log[0].grade, 'good');
      expect(log[0].tsMs, 10);
      expect(log[0].intervalBeforeDays, 0);
      expect(log[0].intervalAfterDays, 1);
      expect(log[1].grade, 'again');
      expect(log[1].intervalBeforeDays, 1);
      expect(log[1].intervalAfterDays, 0, reason: 'a lapse resets the interval');

      final cards = await db.studyDao.loadCardStates(id);
      expect(cards, hasLength(1), reason: 'one card row per item, upserted');
      expect(cards['i1']!.lapses, 1);
    });

    test('the fold: replaying the revlog through scheduleSm2 lands on the card row',
        () async {
      final profileId = await seedProfile();
      final id = await db.studyDao
          .importCourse(profileId: profileId, raw: courseJson(), nowMs: 1);

      var state = CardState.initial('i1', const SrsDefaults(), 100);
      for (final (g, ts) in [(Grade.good, 1), (Grade.good, 2), (Grade.hard, 3)]) {
        final next = scheduleSm2(state, g, 100);
        await db.studyDao.recordGrade(
            courseRowId: id, before: state, after: next, grade: g, tsMs: ts);
        state = next;
      }

      // The stored card state is exactly the fold of the log — the revlog is
      // a source of truth the card row merely caches.
      var folded = CardState.initial('i1', const SrsDefaults(), 100);
      for (final entry in await db.studyDao.revlogOf(id)) {
        folded = scheduleSm2(
            folded, Grade.values.byName(entry.grade), 100);
      }
      final stored = (await db.studyDao.loadCardStates(id))['i1']!;
      expect(folded.intervalDays, stored.intervalDays);
      expect(folded.ease, stored.ease);
      expect(folded.reps, stored.reps);
      expect(folded.lapses, stored.lapses);
    });
  });

  group('schema migration v2 → v3', () {
    test('a v2 database gains the study tables and keeps its data', () async {
      final dir = Directory.systemTemp.createTempSync('trellis-migration-v3');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/v2.sqlite');

      // Build a real v2 file from drift's own DDL: create at the current
      // version, drop exactly what v3 added, stamp user_version 2. v3 is
      // purely additive, so what remains IS the v2 schema. `createTable`
      // migrations are idempotent (CREATE TABLE IF NOT EXISTS) so later
      // tables (jobs, word_ledger, household_pin) surviving from the live
      // schema don't matter here — but schema v7's `addColumn` is NOT
      // idempotent, so that one column has to go too, or a database
      // claiming to be v2 would silently already carry it.
      final seed = AppDatabase.forTesting(NativeDatabase(file));
      await seed.profilesDao.create('Ada');
      await seed.spineDao.insertWork(
          profileId: 1,
          kind: 'book',
          title: 'Kept Book',
          persistence: 'work',
          firstSeenEpochDay: 100);
      await seed.close();
      final v2 = raw.sqlite3.open(file.path);
      v2.execute('''
        DROP TABLE revlog;
        DROP TABLE cards;
        DROP TABLE courses;
        ALTER TABLE profiles DROP COLUMN prefer_system_voice;
        PRAGMA user_version = 2;
      ''');
      v2.dispose();

      final migrated = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(migrated.close);

      // Old data survives…
      final work = (await migrated.spineDao.worksOf(1)).single;
      expect(work.title, 'Kept Book');

      // …and the new tables exist and work.
      final id = await migrated.studyDao
          .importCourse(profileId: 1, raw: courseJson(), nowMs: 7);
      await migrated.studyDao.recordGrade(
          courseRowId: id,
          before: CardState.initial('i1', const SrsDefaults(), 100),
          after: scheduleSm2(
              CardState.initial('i1', const SrsDefaults(), 100),
              Grade.good,
              100),
          grade: Grade.good,
          tsMs: 8);
      expect(await migrated.studyDao.revlogOf(id), hasLength(1));
    });
  });
}
