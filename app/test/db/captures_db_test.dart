import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:trellis/db/database.dart';

/// The study crown, Phase 2: captures. A capture is episode id + playback
/// position + created-at, saved with one tap during listening. Snipd's
/// known complaint is wrong clip boundaries from a raw ±15s guess — the
/// quality bar here is sentence-snapped binding via the SAME alignments
/// the karaoke view and the read<->listen handoff already use, never a
/// fabricated window. When a work has no transcript yet, a capture is
/// still saved (position stays honest, segmentIdx null) and
/// [CapturesDao.backfillForWork] binds it once transcription completes.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<(int, int)> seedWork({bool withAlignments = true}) async {
    final profileId = await db.profilesDao.create('Ada');
    final workId = await db.spineDao.insertWork(
      profileId: profileId,
      kind: 'episode',
      title: 'Ep 1',
      persistence: 'ephemeron',
      firstSeenEpochDay: 100,
      sourceUrl: 'https://cast.test/1.mp3',
    );
    if (withAlignments) {
      await db.spineDao.insertSegments(workId, const [
        (idx: 0, kind: 'prose', text: 'First sentence.'),
        (idx: 1, kind: 'prose', text: 'Second sentence.'),
        (idx: 2, kind: 'prose', text: 'Third sentence.'),
      ]);
      await db.spineDao.insertAlignments(workId, const [
        (segmentIdx: 0, tStartMs: 0, tEndMs: 5000),
        (segmentIdx: 1, tStartMs: 5000, tEndMs: 10000),
        (segmentIdx: 2, tStartMs: 10000, tEndMs: 15000),
      ]);
    }
    return (profileId, workId);
  }

  group('CapturesDao — save', () {
    test(
      'a work with a transcript already: binds the sentence immediately',
      () async {
        final (profileId, workId) = await seedWork();
        final id = await db.capturesDao.capture(
          profileId: profileId,
          workId: workId,
          positionMs: 6200,
          nowMs: 1,
        );

        final saved = (await db.capturesDao.capturesOf(workId)).single;
        expect(saved.id, id);
        expect(saved.positionMs, 6200);
        expect(saved.segmentIdx, 1, reason: '6200ms falls in segment 1');
        expect(saved.createdAtMs, 1);
      },
    );

    test('boundary positions: exactly on a segment start binds forward, '
        'exactly on the last segment end clamps to the last segment', () async {
      final (profileId, workId) = await seedWork();
      final atStart = await db.capturesDao.capture(
        profileId: profileId,
        workId: workId,
        positionMs: 5000,
        nowMs: 1,
      );
      final pastEnd = await db.capturesDao.capture(
        profileId: profileId,
        workId: workId,
        positionMs: 99999,
        nowMs: 2,
      );

      final rows = {
        for (final c in await db.capturesDao.capturesOf(workId)) c.id: c,
      };
      expect(rows[atStart]!.segmentIdx, 1);
      expect(rows[pastEnd]!.segmentIdx, 2);
    });

    test('a work with no transcript yet: saves the raw position, leaves '
        'segmentIdx unbound rather than guessing', () async {
      final (profileId, workId) = await seedWork(withAlignments: false);
      await db.capturesDao.capture(
        profileId: profileId,
        workId: workId,
        positionMs: 4200,
        nowMs: 1,
      );

      final saved = (await db.capturesDao.capturesOf(workId)).single;
      expect(saved.positionMs, 4200);
      expect(saved.segmentIdx, isNull);
    });
  });

  group('CapturesDao — backfillForWork', () {
    test('binds every unbound capture once the transcript lands, in one '
        'pass, and never touches an already-bound one', () async {
      final (profileId, workId) = await seedWork(withAlignments: false);
      final first = await db.capturesDao.capture(
        profileId: profileId,
        workId: workId,
        positionMs: 1000,
        nowMs: 1,
      );
      final second = await db.capturesDao.capture(
        profileId: profileId,
        workId: workId,
        positionMs: 12000,
        nowMs: 2,
      );

      // Transcription completes: alignments arrive.
      await db.spineDao.insertSegments(workId, const [
        (idx: 0, kind: 'prose', text: 'First sentence.'),
        (idx: 1, kind: 'prose', text: 'Second sentence.'),
        (idx: 2, kind: 'prose', text: 'Third sentence.'),
      ]);
      await db.spineDao.insertAlignments(workId, const [
        (segmentIdx: 0, tStartMs: 0, tEndMs: 5000),
        (segmentIdx: 1, tStartMs: 5000, tEndMs: 10000),
        (segmentIdx: 2, tStartMs: 10000, tEndMs: 15000),
      ]);

      final bound = await db.capturesDao.backfillForWork(workId);
      expect(bound, 2);

      final rows = {
        for (final c in await db.capturesDao.capturesOf(workId)) c.id: c,
      };
      expect(rows[first]!.segmentIdx, 0);
      expect(rows[second]!.segmentIdx, 2);
    });

    test('a work still without alignments: backfill is a no-op, never '
        'throws', () async {
      final (profileId, workId) = await seedWork(withAlignments: false);
      await db.capturesDao.capture(
        profileId: profileId,
        workId: workId,
        positionMs: 1000,
        nowMs: 1,
      );

      expect(await db.capturesDao.backfillForWork(workId), 0);
    });

    test('an already-bound capture is left exactly as it was — backfill '
        'only touches segmentIdx: null rows', () async {
      final (profileId, workId) = await seedWork();
      final id = await db.capturesDao.capture(
        profileId: profileId,
        workId: workId,
        positionMs: 6000,
        nowMs: 1,
      );

      await db.capturesDao.backfillForWork(workId);

      final saved = (await db.capturesDao.capturesOf(workId)).single;
      expect(saved.id, id);
      expect(saved.segmentIdx, 1);
    });
  });

  group('CapturesDao — deleting a work', () {
    test('deleteWork removes its captures too (no orphaned FK row left '
        'behind for an already-gone work)', () async {
      final (profileId, workId) = await seedWork();
      await db.capturesDao.capture(
        profileId: profileId,
        workId: workId,
        positionMs: 1000,
        nowMs: 1,
      );

      await db.spineDao.deleteWork(workId);

      expect(await db.capturesDao.capturesOf(workId), isEmpty);
    });
  });

  group('schema migration v9 → v10', () {
    test('a v9 database gains the captures table and keeps its data', () async {
      final dir = Directory.systemTemp.createTempSync('trellis-migration-v10');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/v9.sqlite');

      final seed = AppDatabase.forTesting(NativeDatabase(file));
      await seed.profilesDao.create('Ada');
      await seed.spineDao.insertWork(
        profileId: 1,
        kind: 'episode',
        title: 'Kept Episode',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
      );
      await seed.close();
      // v13 (ADR-0008's Babel translation toggle) arrived AFTER this test
      // was written, on `works` — that column is stripped here too, or a
      // database claiming to be v9 would silently already carry it and
      // v13's own `addColumn` would fail as a duplicate.
      final v9 = raw.sqlite3.open(file.path);
      // v12 (Campaign 1) landed on tables v9 already had, after this test
      // was written — those columns are stripped too, or a v9 snapshot
      // would silently carry them from the future.
      v9.execute('''
        DROP TABLE captures;
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
        PRAGMA user_version = 9;
      ''');
      v9.dispose();

      final migrated = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(migrated.close);

      final work = (await migrated.spineDao.worksOf(1)).single;
      expect(work.title, 'Kept Episode');

      await migrated.capturesDao.capture(
        profileId: 1,
        workId: work.id,
        positionMs: 500,
        nowMs: 1,
      );
      expect(await migrated.capturesDao.capturesOf(work.id), hasLength(1));
    });
  });
}
