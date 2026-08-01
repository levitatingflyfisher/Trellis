import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:trellis/db/database.dart';

/// The speak-voice preference (ADR-0006's settings escape): a profile-scoped
/// bool, false by default — the same "on-device state the reader already
/// persists" surface as Positions, never a second prefs mechanism.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test(
    'a fresh profile defaults to false — neural whenever one is on-device',
    () async {
      final profileId = await db.profilesDao.create('Ada');
      expect(await db.profilesDao.preferSystemVoice(profileId), isFalse);
    },
  );

  test(
    'setting it true persists across reads, scoped to this profile only',
    () async {
      final ada = await db.profilesDao.create('Ada');
      final bea = await db.profilesDao.create('Bea');

      await db.profilesDao.setPreferSystemVoice(ada, true);

      expect(await db.profilesDao.preferSystemVoice(ada), isTrue);
      expect(
        await db.profilesDao.preferSystemVoice(bea),
        isFalse,
        reason: 'the preference is per-profile, never global',
      );
    },
  );

  test('flipping it back to false persists too', () async {
    final profileId = await db.profilesDao.create('Ada');
    await db.profilesDao.setPreferSystemVoice(profileId, true);
    await db.profilesDao.setPreferSystemVoice(profileId, false);
    expect(await db.profilesDao.preferSystemVoice(profileId), isFalse);
  });

  group('scheduler (study crown: Classic | FSRS, per profile)', () {
    test('a fresh profile defaults to classic', () async {
      final profileId = await db.profilesDao.create('Ada');
      expect(await db.profilesDao.scheduler(profileId), 'classic');
    });

    test('setting it to fsrs persists, scoped to this profile only', () async {
      final ada = await db.profilesDao.create('Ada');
      final bea = await db.profilesDao.create('Bea');

      await db.profilesDao.setScheduler(ada, 'fsrs');

      expect(await db.profilesDao.scheduler(ada), 'fsrs');
      expect(
        await db.profilesDao.scheduler(bea),
        'classic',
        reason: 'the scheduler choice is per-profile, never global',
      );
    });

    test('switching back to classic persists too', () async {
      final profileId = await db.profilesDao.create('Ada');
      await db.profilesDao.setScheduler(profileId, 'fsrs');
      await db.profilesDao.setScheduler(profileId, 'classic');
      expect(await db.profilesDao.scheduler(profileId), 'classic');
    });
  });

  group('dspGlobalDefault (Campaign 6: the offline DSP household default)', () {
    test('a fresh profile defaults to false — processing is opt-in', () async {
      final profileId = await db.profilesDao.create('Ada');
      expect(await db.profilesDao.dspGlobalDefault(profileId), isFalse);
    });

    test('setting it true persists, scoped to this profile only', () async {
      final ada = await db.profilesDao.create('Ada');
      final bea = await db.profilesDao.create('Bea');

      await db.profilesDao.setDspGlobalDefault(ada, true);

      expect(await db.profilesDao.dspGlobalDefault(ada), isTrue);
      expect(
        await db.profilesDao.dspGlobalDefault(bea),
        isFalse,
        reason: 'the household default is per-profile, never fleet-wide',
      );
    });

    test('flipping it back to false persists too', () async {
      final profileId = await db.profilesDao.create('Ada');
      await db.profilesDao.setDspGlobalDefault(profileId, true);
      await db.profilesDao.setDspGlobalDefault(profileId, false);
      expect(await db.profilesDao.dspGlobalDefault(profileId), isFalse);
    });
  });

  group('schema migration v8 → v9', () {
    test('a v8 database gains profiles.scheduler, defaulted to classic, '
        'and keeps its data', () async {
      final dir = Directory.systemTemp.createTempSync('trellis-migration-v9');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/v8.sqlite');

      // Build a real v8 file from drift's own DDL: create at the current
      // version, drop exactly what v9 added, stamp user_version 8. v9 is
      // purely additive (one addColumn), so what remains IS the v8 schema
      // — except every later campaign hop (v12 through v18) also landed
      // columns on tables v8 already had, all after this test was written;
      // those columns are stripped too, or a v8 snapshot would silently
      // carry them from the future.
      final seed = AppDatabase.forTesting(NativeDatabase(file));
      final adaId = await seed.profilesDao.create('Ada');
      await seed.close();
      final v8 = raw.sqlite3.open(file.path);
      v8.execute('''
        ALTER TABLE profiles DROP COLUMN scheduler;
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
        ALTER TABLE profiles DROP COLUMN reader_prefs_json;
        DROP TABLE reading_days;
        PRAGMA user_version = 8;
      ''');
      v8.dispose();

      final migrated = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(migrated.close);

      // Old data survives…
      final profiles = await migrated.profilesDao.all();
      expect(profiles.single.name, 'Ada');
      // …and the new column reads its default rather than throwing.
      expect(await migrated.profilesDao.scheduler(adaId), 'classic');
    });
  });
}
