import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jobs_core/jobs_core.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:trellis/db/database.dart';

/// The Drift adapter of jobs_core's `JobStore` (proposal-2 §9). The one law
/// an implementation MUST honor: `saveCheckpoint` merges exactly two fields
/// atomically and refuses to invent rows. The payload column is app-side
/// context (which work, which task) that the engine never touches.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Job job(
    String id, {
    JobState state = JobState.running,
    String? checkpoint,
    int totalUnits = 10,
    int doneUnits = 0,
  }) => Job(
    id: id,
    kind: 'transcribe',
    state: state,
    checkpoint: checkpoint,
    totalUnits: totalUnits,
    doneUnits: doneUnits,
    createdAtMs: 1234,
  );

  group('JobsDao as JobStore', () {
    test('save and load roundtrip every field', () async {
      await db.jobsDao.save(job('j1', checkpoint: '{"n":1}', doneUnits: 3));

      final loaded = await db.jobsDao.load('j1');
      expect(loaded, isNotNull);
      expect(loaded!.id, 'j1');
      expect(loaded.kind, 'transcribe');
      expect(loaded.state, JobState.running);
      expect(loaded.checkpoint, '{"n":1}');
      expect(loaded.totalUnits, 10);
      expect(loaded.doneUnits, 3);
      expect(loaded.createdAtMs, 1234);
    });

    test('load of an unknown id is null', () async {
      expect(await db.jobsDao.load('nope'), isNull);
    });

    test('save is a whole-row upsert', () async {
      await db.jobsDao.save(job('j1'));
      await db.jobsDao.save(job('j1', state: JobState.cancelled, doneUnits: 5));

      final loaded = await db.jobsDao.load('j1');
      expect(loaded!.state, JobState.cancelled);
      expect(loaded.doneUnits, 5);
    });

    test('saveCheckpoint merges exactly checkpoint and doneUnits', () async {
      await db.jobsDao.save(job('j1'));
      await db.jobsDao.saveCheckpoint('j1', '{"n":2}', 2);

      final loaded = await db.jobsDao.load('j1');
      expect(loaded!.checkpoint, '{"n":2}');
      expect(loaded.doneUnits, 2);
      expect(loaded.state, JobState.running, reason: 'state untouched');
      expect(loaded.createdAtMs, 1234, reason: 'creation time untouched');
    });

    test(
      'saveCheckpoint for an unknown id throws and writes nothing',
      () async {
        await expectLater(
          db.jobsDao.saveCheckpoint('ghost', 'c', 1),
          throwsA(isA<StateError>()),
        );
        expect(
          await db.jobsDao.load('ghost'),
          isNull,
          reason: 'a checkpoint may never invent a row',
        );
      },
    );

    test('delete abandons the row, checkpoint and all', () async {
      await db.jobsDao.save(job('j1', checkpoint: 'c'));
      // Through the engine-facing store, the face the runner actually holds.
      await db.jobsDao.store.delete('j1');
      expect(await db.jobsDao.load('j1'), isNull);
    });

    test('the store face honors the whole contract end to end', () async {
      final store = db.jobsDao.store;
      await store.save(job('j2'));
      await store.saveCheckpoint('j2', '{"n":9}', 9);
      final loaded = await store.load('j2');
      expect(loaded!.checkpoint, '{"n":9}');
      expect(loaded.doneUnits, 9);
    });
  });

  group('app-side job context', () {
    test('payload survives engine saves and checkpoints', () async {
      await db.jobsDao.save(job('j1'));
      await db.jobsDao.setPayload('j1', '{"workId":7}');

      // The engine's own writes must not clobber app context.
      await db.jobsDao.save(job('j1', doneUnits: 1));
      await db.jobsDao.saveCheckpoint('j1', 'c', 2);

      expect(await db.jobsDao.payloadOf('j1'), '{"workId":7}');
    });

    test(
      'unfinished lists resumable jobs, oldest first, never done ones',
      () async {
        await db.jobsDao.save(job('running'));
        await db.jobsDao.save(job('done', state: JobState.done, doneUnits: 10));
        await db.jobsDao.save(job('failed', state: JobState.failed));
        await db.jobsDao.save(job('cancelled', state: JobState.cancelled));

        final rows = await db.jobsDao.unfinished();
        expect([
          for (final r in rows) r.id,
        ], containsAll(['running', 'failed', 'cancelled']));
        expect([for (final r in rows) r.id], isNot(contains('done')));
      },
    );

    test(
      'setTotalUnits sizes a placeholder row once the plan is known',
      () async {
        await db.jobsDao.save(job('j1', totalUnits: 0));
        await db.jobsDao.setTotalUnits('j1', 42);
        expect((await db.jobsDao.load('j1'))!.totalUnits, 42);
      },
    );
  });

  group('schema migration v3 → v4', () {
    test('a v3 database gains the jobs table and keeps its data', () async {
      final dir = Directory.systemTemp.createTempSync('trellis-migration-v4');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/v3.sqlite');

      // Build a real v3 file from drift's own DDL: create at the current
      // version, drop exactly what v4 added, stamp user_version 3. v4 is
      // purely additive, so what remains IS the v3 schema. `createTable`
      // migrations are idempotent so later tables surviving from the live
      // schema don't matter — but every `addColumn` since (v7, v8, v9,
      // v12, v13) is NOT, so those columns have to go too (see
      // household_db_test.dart's fuller note); v3 is after feeds/episodes
      // (v2), so v8's and v12's columns on those two tables are in scope
      // here too.
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
      final v3 = raw.sqlite3.open(file.path);
      v3.execute('''
        DROP TABLE jobs;
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
        ALTER TABLE works DROP COLUMN show_translation_layer;
        ALTER TABLE feeds DROP COLUMN rules_json;
        ALTER TABLE episodes DROP COLUMN dedup_reason;
        ALTER TABLE episodes DROP COLUMN duplicate_of_work_id;
        ALTER TABLE feeds DROP COLUMN dsp_enabled;
        ALTER TABLE episodes DROP COLUMN dsp_original_duration_ms;
        ALTER TABLE episodes DROP COLUMN dsp_processed_duration_ms;
        ALTER TABLE profiles DROP COLUMN dsp_global_default;
        ALTER TABLE player_positions DROP COLUMN file_idx;
        PRAGMA user_version = 3;
      ''');
      v3.dispose();

      final migrated = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(migrated.close);

      // Old data survives…
      final work = (await migrated.spineDao.worksOf(1)).single;
      expect(work.title, 'Kept Book');

      // …and the new table exists and works.
      await migrated.jobsDao.save(job('j1'));
      await migrated.jobsDao.saveCheckpoint('j1', 'c', 1);
      expect((await migrated.jobsDao.load('j1'))!.doneUnits, 1);
    });
  });
}
