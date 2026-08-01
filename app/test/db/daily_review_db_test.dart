import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:study_core/study_core.dart';
import 'package:trellis/db/database.dart';

/// The study crown, Phase 1: daily review. Zero-effort resurfacing for
/// extracts/vocab (the word ledger) and captures (Phase 2) — the gentle
/// on-ramp, not a replacement for the four-grade course flow, which this
/// file never touches: course items live in Cards/StudyDao, a completely
/// separate table this queue never queries.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<int> seedProfile() => db.profilesDao.create('Ada');

  String courseJson() => json.encode({
        'schemaVersion': '1.0',
        'id': 'c1',
        'title': 'Course One',
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

  group('two-button mapping (Soon -> again, Eventually -> good)', () {
    test('Soon maps to scheduleSm2\'s again (a lapse: due again today)',
        () async {
      final profileId = await seedProfile();
      final wordId = await db.ledgerDao
          .add(profileId: profileId, word: 'saudade', nowMs: 1);
      const today = 20000;

      final before = await db.dailyReviewDao.stateOf(
          profileId: profileId,
          sourceType: 'ledger',
          sourceId: wordId,
          todayEpochDay: today);
      final after = scheduleSm2(before, Grade.again, today);
      await db.dailyReviewDao.recordGrade(
          profileId: profileId,
          sourceType: 'ledger',
          sourceId: wordId,
          after: after);

      final stored = await db.dailyReviewDao.stateOf(
          profileId: profileId,
          sourceType: 'ledger',
          sourceId: wordId,
          todayEpochDay: today);
      expect(stored.intervalDays, 0);
      expect(stored.dueEpochDay, today,
          reason: 'Soon = again = due again today, the sealed scheduler\'s '
              'own lapse behavior, untouched');
    });

    test('Eventually maps to scheduleSm2\'s good (graduates, due later)',
        () async {
      final profileId = await seedProfile();
      final wordId = await db.ledgerDao
          .add(profileId: profileId, word: 'saudade', nowMs: 1);
      const today = 20000;

      final before = await db.dailyReviewDao.stateOf(
          profileId: profileId,
          sourceType: 'ledger',
          sourceId: wordId,
          todayEpochDay: today);
      final after = scheduleSm2(before, Grade.good, today);
      await db.dailyReviewDao.recordGrade(
          profileId: profileId,
          sourceType: 'ledger',
          sourceId: wordId,
          after: after);

      final stored = await db.dailyReviewDao.stateOf(
          profileId: profileId,
          sourceType: 'ledger',
          sourceId: wordId,
          todayEpochDay: today);
      expect(stored.dueEpochDay, greaterThan(today));
    });
  });

  group('queue composition — extracts only, course items excluded', () {
    test('a fresh ledger word and a fresh capture are both due immediately; '
        'a course card never appears, because this queue never queries '
        'Cards at all', () async {
      final profileId = await seedProfile();
      const today = 20000;

      final wordId = await db.ledgerDao
          .add(profileId: profileId, word: 'saudade', nowMs: 1);
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: 'Ep',
          persistence: 'ephemeron',
          firstSeenEpochDay: 100,
          sourceUrl: 'https://cast.test/1.mp3');
      final captureId = await db.capturesDao.capture(
          profileId: profileId, workId: workId, positionMs: 1000, nowMs: 1);

      final courseRowId = await db.studyDao
          .importCourse(profileId: profileId, raw: courseJson(), nowMs: 1);
      await db.studyDao.recordGrade(
          courseRowId: courseRowId,
          before: CardState.initial('i1', const SrsDefaults(), today),
          after: CardState.initial('i1', const SrsDefaults(), today),
          grade: Grade.good,
          tsMs: 1);

      final all = await db.dailyReviewDao.loadAll(profileId, today);
      final due = {
        for (final e in all.entries)
          if (e.value.isDue(today)) e.key: e.value
      };

      expect(due.keys, containsAll(['ledger:$wordId', 'capture:$captureId']));
      expect(due.keys.any((k) => k.contains('i1')), isFalse,
          reason: 'a course item id must never leak into this queue');
      expect(due.length, 2, reason: 'exactly the two extracts, nothing else');
    });

    test('grading Eventually removes an item from today\'s due set',
        () async {
      final profileId = await seedProfile();
      const today = 20000;
      final wordId = await db.ledgerDao
          .add(profileId: profileId, word: 'saudade', nowMs: 1);

      final before = await db.dailyReviewDao.stateOf(
          profileId: profileId,
          sourceType: 'ledger',
          sourceId: wordId,
          todayEpochDay: today);
      await db.dailyReviewDao.recordGrade(
          profileId: profileId,
          sourceType: 'ledger',
          sourceId: wordId,
          after: scheduleSm2(before, Grade.good, today));

      final all = await db.dailyReviewDao.loadAll(profileId, today);
      expect(all['ledger:$wordId']!.isDue(today), isFalse);
    });

    test('due count is per-profile', () async {
      final ada = await seedProfile();
      final bea = await db.profilesDao.create('Bea');
      await db.ledgerDao.add(profileId: ada, word: 'saudade', nowMs: 1);
      await db.ledgerDao.add(profileId: bea, word: 'hygge', nowMs: 1);

      expect(await db.dailyReviewDao.dueCount(ada, 20000), 1);
      expect(await db.dailyReviewDao.dueCount(bea, 20000), 1);
    });
  });

  group('malformed entries are skipped individually', () {
    test('a corrupt stateJson row is skipped, the rest of the queue survives',
        () async {
      final profileId = await seedProfile();
      final wordId = await db.ledgerDao
          .add(profileId: profileId, word: 'saudade', nowMs: 1);
      await db.into(db.dailyReviewCards).insert(DailyReviewCardsCompanion
          .insert(
              profileId: profileId,
              sourceType: 'ledger',
              sourceId: wordId,
              stateJson: '{not valid json'));
      final goodWordId =
          await db.ledgerDao.add(profileId: profileId, word: 'hygge', nowMs: 2);

      final all = await db.dailyReviewDao.loadAll(profileId, 20000);
      expect(all.containsKey('ledger:$wordId'), isFalse);
      expect(all.containsKey('ledger:$goodWordId'), isTrue);
    });
  });

  group('schema migration v10 → v11', () {
    test('a v10 database gains daily_review_cards and keeps its data',
        () async {
      final dir =
          Directory.systemTemp.createTempSync('trellis-migration-v11');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/v10.sqlite');

      final seed = AppDatabase.forTesting(NativeDatabase(file));
      final ada = await seed.profilesDao.create('Ada');
      await seed.ledgerDao.add(profileId: ada, word: 'kept', nowMs: 1);
      await seed.close();
      // v13 (ADR-0008's Babel translation toggle) arrived AFTER this test
      // was written, on `works` — that column is stripped here too, or a
      // database claiming to be v10 would silently already carry it and
      // v13's own `addColumn` would fail as a duplicate.
      final v10 = raw.sqlite3.open(file.path);
      // v12 (Campaign 1) landed on tables v10 already had, after this test
      // was written — those columns are stripped too, or a v10 snapshot
      // would silently carry them from the future.
      v10.execute('''
        ALTER TABLE feeds DROP COLUMN image_url;
        DROP TABLE daily_review_cards;
        ALTER TABLE profiles DROP COLUMN keep_finished_in_queue;
        ALTER TABLE feeds DROP COLUMN speed_override;
        ALTER TABLE feeds DROP COLUMN skip_intro_seconds;
        ALTER TABLE feeds DROP COLUMN skip_outro_seconds;
        ALTER TABLE feeds DROP COLUMN keep_latest_audio;
        ALTER TABLE episodes DROP COLUMN archived_at_ms;
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
        ALTER TABLE captures DROP COLUMN file_idx;
        ALTER TABLE profiles DROP COLUMN reader_prefs_json;
        DROP TABLE reading_days;
        PRAGMA user_version = 10;
      ''');
      v10.dispose();

      final migrated = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(migrated.close);

      expect((await migrated.ledgerDao.wordsOf(ada)).single.word, 'kept');
      expect(await migrated.dailyReviewDao.dueCount(ada, 20000), 1);
    });
  });
}
