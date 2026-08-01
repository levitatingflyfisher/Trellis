import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:trellis/db/database.dart';

/// The word ledger (schema v5): words the user's hand set aside while
/// reading or listening. Two laws under test here:
///
/// - Dedupe lives in the schema: (profileId, word) is unique with the word
///   column carrying COLLATE NOCASE, so "Saudade" and "saudade" are one row
///   no matter which code path inserts.
/// - A collected word outlives its source (ON DELETE SET NULL): works come
///   and go — ephemera decay, library removal — but the ledger is the
///   user's own collection (the promotion principle, ADR-0003 law 2), so
///   deleting a work degrades provenance to null instead of draining the
///   notebook the way CASCADE silently would.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<int> seedWork(int profileId, {String title = 'Fado Lyrics'}) =>
      db.spineDao.insertWork(
        profileId: profileId,
        kind: 'note',
        title: title,
        persistence: 'work',
        firstSeenEpochDay: 100,
        lang: 'pt',
      );

  group('LedgerDao', () {
    test('add, list newest-first, remove — per profile', () async {
      final ada = await db.profilesDao.create('Ada');
      final grace = await db.profilesDao.create('Grace');

      final id1 = await db.ledgerDao.add(
        profileId: ada,
        word: 'saudade',
        lang: 'pt',
        nowMs: 1000,
      );
      await db.ledgerDao.add(
        profileId: ada,
        word: 'hygge',
        lang: 'da',
        nowMs: 2000,
      );
      await db.ledgerDao.add(profileId: grace, word: 'sisu', nowMs: 3000);

      final adas = await db.ledgerDao.wordsOf(ada);
      expect(
        [for (final w in adas) w.word],
        ['hygge', 'saudade'],
        reason: 'newest first',
      );
      expect(adas.last.lang, 'pt');
      expect(
        [for (final w in await db.ledgerDao.wordsOf(grace)) w.word],
        ['sisu'],
        reason: 'ledgers are per profile',
      );

      await db.ledgerDao.remove(id1);
      expect(
        [for (final w in await db.ledgerDao.wordsOf(ada)) w.word],
        ['hygge'],
      );
    });

    test('dedupe is case-insensitive and idempotent, per profile', () async {
      final ada = await db.profilesDao.create('Ada');
      final grace = await db.profilesDao.create('Grace');

      final first = await db.ledgerDao.add(
        profileId: ada,
        word: 'Saudade',
        lang: 'pt',
        nowMs: 1000,
      );
      final again = await db.ledgerDao.add(
        profileId: ada,
        word: 'saudade',
        nowMs: 2000,
      );

      expect(again, first, reason: 'the existing row is the answer');
      final rows = await db.ledgerDao.wordsOf(ada);
      expect(rows, hasLength(1));
      expect(rows.single.word, 'Saudade', reason: 'first spelling kept');
      expect(rows.single.addedAtMs, 1000, reason: 'nothing rewritten');

      // Another profile may keep the same word.
      await db.ledgerDao.add(profileId: grace, word: 'SAUDADE', nowMs: 3000);
      expect(await db.ledgerDao.wordsOf(grace), hasLength(1));
      expect(await db.ledgerDao.wordsOf(ada), hasLength(1));
    });

    test(
      'deleting the source work keeps the word, provenance goes null',
      () async {
        final ada = await db.profilesDao.create('Ada');
        final workId = await seedWork(ada);
        await db.ledgerDao.add(
          profileId: ada,
          word: 'saudade',
          lang: 'pt',
          sourceWorkId: workId,
          nowMs: 1000,
        );

        await db.spineDao.deleteWork(workId);

        final row = (await db.ledgerDao.wordsOf(ada)).single;
        expect(
          row.word,
          'saudade',
          reason: 'the collection survives its source',
        );
        expect(row.sourceWorkId, isNull, reason: 'SET NULL, never CASCADE');
      },
    );
  });

  group('schema migration v4 → v5', () {
    test('a v4 database gains the word ledger and keeps its data', () async {
      final dir = Directory.systemTemp.createTempSync('trellis-migration-v5');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/v4.sqlite');

      // Build a real v4 file from drift's own DDL: create at the current
      // version, drop exactly what v5 added, stamp user_version 4. v5 is
      // purely additive, so what remains IS the v4 schema. `createTable`
      // migrations are idempotent so later tables surviving from the live
      // schema don't matter for correctness — but every `addColumn` since
      // (v7, v8, v9, v12, v13) is NOT, so those columns have to go too
      // (see household_db_test.dart's fuller note); `queue` is dropped
      // anyway for an honest v4 snapshot even though its own re-creation
      // would tolerate surviving.
      final seed = AppDatabase.forTesting(NativeDatabase(file));
      await seed.profilesDao.create('Ada');
      await seed.spineDao.insertWork(
        profileId: 1,
        kind: 'book',
        title: 'Kept Book',
        persistence: 'work',
        firstSeenEpochDay: 100,
      );
      await seed.close();
      final v4 = raw.sqlite3.open(file.path);
      v4.execute('''
        DROP TABLE word_ledger;
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
        ALTER TABLE feeds DROP COLUMN rules_json;
        ALTER TABLE episodes DROP COLUMN dedup_reason;
        ALTER TABLE episodes DROP COLUMN duplicate_of_work_id;
        ALTER TABLE feeds DROP COLUMN dsp_enabled;
        ALTER TABLE episodes DROP COLUMN dsp_original_duration_ms;
        ALTER TABLE episodes DROP COLUMN dsp_processed_duration_ms;
        ALTER TABLE profiles DROP COLUMN dsp_global_default;
        ALTER TABLE player_positions DROP COLUMN file_idx;
        PRAGMA user_version = 4;
      ''');
      v4.dispose();

      final migrated = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(migrated.close);

      // Old data survives…
      final work = (await migrated.spineDao.worksOf(1)).single;
      expect(work.title, 'Kept Book');

      // …and the new table works, SET NULL included — the migration's DDL
      // must carry the same referential action as a fresh create.
      await migrated.ledgerDao.add(
        profileId: 1,
        word: 'kept',
        sourceWorkId: work.id,
        nowMs: 1,
      );
      await migrated.spineDao.deleteWork(work.id);
      final row = (await migrated.ledgerDao.wordsOf(1)).single;
      expect(row.word, 'kept');
      expect(row.sourceWorkId, isNull);
    });
  });
}
