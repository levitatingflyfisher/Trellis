import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:study_core/study_core.dart' as study;
import 'package:trellis/db/database.dart';

/// The household layer (schema v6, P5): one optional parent-PIN row (salt +
/// digest, never the PIN itself), profile rename/delete, and the parent
/// dashboard's per-profile LIFETIME BUILT stats. Laws under test:
///
/// - Existing installs upgrade losslessly (migration test first, fleet law).
/// - Deleting a reader removes every trace of that reader and nothing of
///   anyone else's.
/// - The stats are additive lifetime totals of what was BUILT (ADR-0003
///   law 5) — counts of works kept/finished, cards mastered, words
///   collected, listening reached — computed from existing tables only.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  String ladderCourse({String id = 'ladder', String title = 'A Ladder of Two'}) =>
      json.encode({
        'schemaVersion': '1.0',
        'id': id,
        'title': title,
        'nodes': [
          {
            'id': 'a',
            'title': 'Foundation Concept',
            'intake': 'Water is wet — remember it.',
            'items': [
              {
                'id': 'i-a',
                'type': 'cloze',
                'rung': 1,
                'text': 'Water is {{c1::wet}}.',
                'answers': {'c1': 'wet'},
              },
            ],
          },
          {
            'id': 'b',
            'title': 'Dependent Concept',
            'prereqs': ['a'],
            'intake': 'Built on the foundation.',
            'items': [
              {
                'id': 'i-b',
                'type': 'qa',
                'rung': 3,
                'prompt': 'Why?',
                'answer': 'Because.',
              },
            ],
          },
        ],
      });

  study.CardState cardState(String itemId, {required int intervalDays}) =>
      study.CardState(
          itemId: itemId,
          ease: 2.5,
          intervalDays: intervalDays,
          dueEpochDay: 100 + intervalDays,
          reps: 1,
          lapses: 0);

  group('schema migration v5 → v6', () {
    test('a v5 database gains the household pin table and keeps its data',
        () async {
      final dir = Directory.systemTemp.createTempSync('trellis-migration-v6');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/v5.sqlite');

      // Build a real v5 file from drift's own DDL: create at the current
      // version, drop exactly what v6 added, stamp user_version 5. v6 is
      // purely additive, so what remains IS the v5 schema. Every column/
      // table a LATER version added onto a table v5 already had must be
      // stripped here too, or a database claiming to be v5 would silently
      // carry columns from the future: v7 (ADR-0006's speak-voice
      // preference), v8 (RFC 5005's `Feeds.nextPageUrl`), v9 (the study
      // crown's `Profiles.scheduler`), v12 (Campaign 1: per-podcast
      // settings, the queue, audio eviction), and v13 (ADR-0008's Babel
      // translation toggle) all land on tables v5 already had. v10/v11
      // (`captures`/`daily_review_cards`) are new TABLES, not columns —
      // `createTable` is idempotent, so leaving them out here is safe,
      // unlike an omitted column.
      final seed = AppDatabase.forTesting(NativeDatabase(file));
      await seed.profilesDao.create('Ada');
      await seed.spineDao.insertWork(
          profileId: 1,
          kind: 'book',
          title: 'Kept Book',
          persistence: 'work',
          firstSeenEpochDay: 100);
      await seed.ledgerDao.add(profileId: 1, word: 'kept', nowMs: 1);
      await seed.close();
      final v5 = raw.sqlite3.open(file.path);
      v5.execute('''
        ALTER TABLE feeds DROP COLUMN image_url;
        DROP TABLE household_pin;
        ALTER TABLE profiles DROP COLUMN prefer_system_voice;
        ALTER TABLE profiles DROP COLUMN scheduler;
        ALTER TABLE profiles DROP COLUMN reader_prefs_json;
        DROP TABLE reading_days;
        ALTER TABLE feeds DROP COLUMN next_page_url;
        ALTER TABLE profiles DROP COLUMN keep_finished_in_queue;
        ALTER TABLE feeds DROP COLUMN speed_override;
        ALTER TABLE feeds DROP COLUMN skip_intro_seconds;
        ALTER TABLE feeds DROP COLUMN skip_outro_seconds;
        ALTER TABLE feeds DROP COLUMN keep_latest_audio;
        ALTER TABLE episodes DROP COLUMN archived_at_ms;
        DROP TABLE queue;
        ALTER TABLE works DROP COLUMN show_translation_layer;
        ALTER TABLE works DROP COLUMN active_translation_lang;
        ALTER TABLE feeds DROP COLUMN rules_json;
        ALTER TABLE episodes DROP COLUMN dedup_reason;
        ALTER TABLE episodes DROP COLUMN duplicate_of_work_id;
        ALTER TABLE feeds DROP COLUMN dsp_enabled;
        ALTER TABLE episodes DROP COLUMN dsp_original_duration_ms;
        ALTER TABLE episodes DROP COLUMN dsp_processed_duration_ms;
        ALTER TABLE profiles DROP COLUMN dsp_global_default;
        ALTER TABLE player_positions DROP COLUMN file_idx;
        PRAGMA user_version = 5;
      ''');
      v5.dispose();

      final migrated = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(migrated.close);

      // Old data survives…
      final work = (await migrated.spineDao.worksOf(1)).single;
      expect(work.title, 'Kept Book');
      expect((await migrated.ledgerDao.wordsOf(1)).single.word, 'kept');

      // …no PIN exists yet…
      expect(await migrated.householdDao.readPin(), isNull);

      // …and the new table works.
      await migrated.householdDao.writePin(salt: 'aa', hash: 'bb');
      final row = await migrated.householdDao.readPin();
      expect(row!.salt, 'aa');
      expect(row.hash, 'bb');
    });
  });

  group('HouseholdDao pin row', () {
    test('write, read, overwrite, clear — one row, never more', () async {
      expect(await db.householdDao.readPin(), isNull);

      await db.householdDao.writePin(salt: 's1', hash: 'h1');
      expect((await db.householdDao.readPin())!.hash, 'h1');

      // A second write replaces the row (change-PIN), never adds one.
      await db.householdDao.writePin(salt: 's2', hash: 'h2');
      final row = await db.householdDao.readPin();
      expect(row!.salt, 's2');
      expect(row.hash, 'h2');

      await db.householdDao.clearPin();
      expect(await db.householdDao.readPin(), isNull);
    });
  });

  group('profile rename and delete', () {
    test('renameProfile renames exactly one reader', () async {
      final ada = await db.profilesDao.create('Ada');
      await db.profilesDao.create('Grace');

      await db.householdDao.renameProfile(ada, 'Ada Lovelace');

      final names = [for (final p in await db.profilesDao.all()) p.name];
      expect(names, ['Ada Lovelace', 'Grace']);
    });

    test('deleteProfileCascade removes every trace of the reader and nothing '
        'of anyone else', () async {
      final ada = await db.profilesDao.create('Ada');
      final grace = await db.profilesDao.create('Grace');

      Future<void> seedReader(int profileId) async {
        // A kept work with segments, a position, and a raw player position.
        final workId = await db.spineDao.insertWork(
            profileId: profileId,
            kind: 'book',
            title: 'Book $profileId',
            persistence: 'work',
            firstSeenEpochDay: 100);
        await db.spineDao.insertSegments(
            workId, [(idx: 0, kind: 'para', text: 'Hello.')]);
        await db.spineDao.savePosition(
            profileId: profileId,
            workId: workId,
            segmentIdx: 0,
            wordIdx: 0,
            lastModality: 'read');
        await db.feedsDao.savePlayerPosition(
            profileId: profileId, workId: workId, tMs: 1000);
        // A feed with one (ephemeral) episode.
        final feedId = await db.feedsDao.insertFeed(
            profileId: profileId, url: 'https://example.org/$profileId.xml');
        final epWork = await db.spineDao.insertWork(
            profileId: profileId,
            kind: 'episode',
            title: 'Episode $profileId',
            persistence: 'ephemeron',
            firstSeenEpochDay: 100);
        await db.feedsDao.insertEpisode(
            workId: epWork,
            feedId: feedId,
            guid: 'g-$profileId',
            publishedAtMs: 1);
        // A course with one graded card (and so a revlog row).
        final courseRowId = await db.studyDao.importCourse(
            profileId: profileId, raw: ladderCourse(), nowMs: 1);
        await db.studyDao.recordGrade(
            courseRowId: courseRowId,
            before: cardState('i-a', intervalDays: 1),
            after: cardState('i-a', intervalDays: 3),
            grade: study.Grade.good,
            tsMs: 2);
        // A collected word.
        await db.ledgerDao
            .add(profileId: profileId, word: 'word$profileId', nowMs: 3);
        // Campaign 4 Phase 5: a recorded reading day.
        await db.profilesDao.recordReadingDay(profileId, 100);
      }

      await seedReader(ada);
      await seedReader(grace);

      await db.householdDao.deleteProfileCascade(ada);

      // Ada is gone — profile, works, feeds, courses, cards, revlog, words.
      expect([for (final p in await db.profilesDao.all()) p.id], [grace]);
      expect(await db.spineDao.worksOf(ada), isEmpty);
      expect(await db.feedsDao.feedsOf(ada), isEmpty);
      expect(await db.studyDao.coursesOf(ada), isEmpty);
      expect(await db.ledgerDao.wordsOf(ada), isEmpty);
      expect(await db.spineDao.allPositions(), hasLength(1));
      expect(await db.feedsDao.allPlayerPositions(), hasLength(1));
      expect(
          await (db.select(db.readingDays)
                ..where((t) => t.profileId.equals(ada)))
              .get(),
          isEmpty,
          reason: 'Campaign 4 Phase 5: no orphan ReadingDays rows left '
              'behind for a deleted profile');

      // Grace is untouched.
      expect(await db.spineDao.worksOf(grace), hasLength(2));
      expect(await db.feedsDao.feedsOf(grace), hasLength(1));
      final graceCourse = (await db.studyDao.coursesOf(grace)).single;
      expect(await db.studyDao.loadCardStates(graceCourse.id), hasLength(1));
      expect(await db.studyDao.revlogOf(graceCourse.id), hasLength(1));
      expect((await db.ledgerDao.wordsOf(grace)).single.word, 'word2');
      expect(
          await (db.select(db.readingDays)
                ..where((t) => t.profileId.equals(grace)))
              .get(),
          hasLength(1));
    });
  });

  group('lifetimeBuiltOf — the parent dashboard query', () {
    test('counts what the reader has built, from existing tables only',
        () async {
      final ada = await db.profilesDao.create('Ada');
      final grace = await db.profilesDao.create('Grace');

      // Two kept works (one finished), one passing ephemeron.
      final w1 = await db.spineDao.insertWork(
          profileId: ada,
          kind: 'book',
          title: 'Kept',
          persistence: 'work',
          firstSeenEpochDay: 100);
      final w2 = await db.spineDao.insertWork(
          profileId: ada,
          kind: 'book',
          title: 'Finished',
          persistence: 'work',
          firstSeenEpochDay: 100);
      await db.spineDao.markFinished(w2, 120);
      final w3 = await db.spineDao.insertWork(
          profileId: ada,
          kind: 'episode',
          title: 'Passing',
          persistence: 'ephemeron',
          firstSeenEpochDay: 100);

      // Listening reached: w3 raw player position (2 min); w2 aligned —
      // position at segment 1 reaches tEndMs 180000 (3 min). A stale raw
      // row on w2 must NOT be added on top: per work the reached time is
      // the max of the two, never the sum.
      await db.feedsDao
          .savePlayerPosition(profileId: ada, workId: w3, tMs: 120000);
      await db.spineDao.insertAlignments(w2, [
        (segmentIdx: 0, tStartMs: 0, tEndMs: 60000),
        (segmentIdx: 1, tStartMs: 60000, tEndMs: 180000),
      ]);
      await db.spineDao.savePosition(
          profileId: ada,
          workId: w2,
          segmentIdx: 1,
          wordIdx: 0,
          lastModality: 'listen');
      await db.feedsDao
          .savePlayerPosition(profileId: ada, workId: w2, tMs: 30000);
      // A read position must not count as listening.
      await db.spineDao.savePosition(
          profileId: ada,
          workId: w1,
          segmentIdx: 0,
          wordIdx: 0,
          lastModality: 'read');

      // Courses: an older one, then the current one with 1 of 2 mastered
      // (interval at the 7-day mastery threshold) and 1 still growing.
      await db.studyDao.importCourse(
          profileId: ada,
          raw: ladderCourse(id: 'older', title: 'Older Course'),
          nowMs: 1000);
      final current = await db.studyDao.importCourse(
          profileId: ada, raw: ladderCourse(), nowMs: 2000);
      await db.studyDao.recordGrade(
          courseRowId: current,
          before: cardState('i-a', intervalDays: 3),
          after: cardState('i-a', intervalDays: 7),
          grade: study.Grade.good,
          tsMs: 3000);
      await db.studyDao.recordGrade(
          courseRowId: current,
          before: cardState('i-b', intervalDays: 0),
          after: cardState('i-b', intervalDays: 1),
          grade: study.Grade.good,
          tsMs: 4000);

      // Two collected words.
      await db.ledgerDao.add(profileId: ada, word: 'saudade', nowMs: 1);
      await db.ledgerDao.add(profileId: ada, word: 'hygge', nowMs: 2);

      // Campaign 4 Phase 5: three distinct reading days, one replayed.
      await db.profilesDao.recordReadingDay(ada, 100);
      await db.profilesDao.recordReadingDay(ada, 101);
      await db.profilesDao.recordReadingDay(ada, 101);
      await db.profilesDao.recordReadingDay(ada, 103);

      // Grace's data must not leak into Ada's card.
      await db.spineDao.insertWork(
          profileId: grace,
          kind: 'book',
          title: 'Not Ada\'s',
          persistence: 'work',
          firstSeenEpochDay: 100);
      await db.ledgerDao.add(profileId: grace, word: 'sisu', nowMs: 3);
      await db.profilesDao.recordReadingDay(grace, 100);

      final built = await db.householdDao.lifetimeBuiltOf(ada);
      expect(built.worksKept, 2);
      expect(built.worksFinished, 1);
      expect(built.cardsMastered, 1, reason: '7-day interval = mastered');
      expect(built.wordsCollected, 2);
      expect(built.listeningMs, 120000 + 180000,
          reason: 'max per work (w2: aligned 180000 beats raw 30000), '
              'summed across works');
      expect(built.activeReadingDays, 3,
          reason: 'a replayed day (101 twice) still counts once');
      expect(built.currentCourse, isNotNull);
      expect(built.currentCourse!.title, 'A Ladder of Two',
          reason: 'the latest import is the current course');
      expect(built.currentCourse!.mastered, 1);
      expect(built.currentCourse!.total, 2);
    });

    test('a brand-new reader has honest zeros and no current course',
        () async {
      final ada = await db.profilesDao.create('Ada');
      final built = await db.householdDao.lifetimeBuiltOf(ada);
      expect(built.worksKept, 0);
      expect(built.worksFinished, 0);
      expect(built.cardsMastered, 0);
      expect(built.wordsCollected, 0);
      expect(built.listeningMs, 0);
      expect(built.activeReadingDays, 0);
      expect(built.currentCourse, isNull);
    });
  });
}
