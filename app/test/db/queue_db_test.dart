import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';

/// The Up Next queue (schema v8, P4 mercy #3): a position-ordered,
/// per-profile list of works waiting to play next. Positions stay
/// contiguous from 0 — every mutating op renumbers rather than leaving
/// gaps — and "play next"/"play last" move an already-queued work instead
/// of duplicating it.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<int> seedProfile() => db.profilesDao.create('Ada');

  Future<int> seedWork(int profileId, String title) => db.spineDao.insertWork(
      profileId: profileId,
      kind: 'episode',
      title: title,
      persistence: 'ephemeron',
      firstSeenEpochDay: 100);

  group('playNext / playLast', () {
    test('playLast appends in call order', () async {
      final profileId = await seedProfile();
      final a = await seedWork(profileId, 'A');
      final b = await seedWork(profileId, 'B');

      await db.queueDao.playLast(profileId: profileId, workId: a, nowMs: 1);
      await db.queueDao.playLast(profileId: profileId, workId: b, nowMs: 2);

      final rows = await db.queueDao.queueOf(profileId);
      expect(rows.map((r) => r.workId), [a, b]);
      expect(rows.map((r) => r.position), [0, 1]);
    });

    test('playNext inserts at the head, pushing everything else down',
        () async {
      final profileId = await seedProfile();
      final a = await seedWork(profileId, 'A');
      final b = await seedWork(profileId, 'B');
      final c = await seedWork(profileId, 'C');
      await db.queueDao.playLast(profileId: profileId, workId: a, nowMs: 1);
      await db.queueDao.playLast(profileId: profileId, workId: b, nowMs: 2);

      await db.queueDao.playNext(profileId: profileId, workId: c, nowMs: 3);

      final rows = await db.queueDao.queueOf(profileId);
      expect(rows.map((r) => r.workId), [c, a, b]);
      expect(rows.map((r) => r.position), [0, 1, 2]);
    });

    test('queuing an already-queued work MOVES it, never duplicates',
        () async {
      final profileId = await seedProfile();
      final a = await seedWork(profileId, 'A');
      final b = await seedWork(profileId, 'B');
      await db.queueDao.playLast(profileId: profileId, workId: a, nowMs: 1);
      await db.queueDao.playLast(profileId: profileId, workId: b, nowMs: 2);

      await db.queueDao.playNext(profileId: profileId, workId: b, nowMs: 3);

      final rows = await db.queueDao.queueOf(profileId);
      expect(rows.map((r) => r.workId), [b, a]);
      expect(rows, hasLength(2), reason: 'moved, not duplicated');
    });

    test('the queue is per-profile', () async {
      final ada = await seedProfile();
      final blaise = await db.profilesDao.create('Blaise');
      final work = await seedWork(ada, 'A');
      await db.queueDao.playLast(profileId: ada, workId: work, nowMs: 1);

      expect(await db.queueDao.queueOf(ada), hasLength(1));
      expect(await db.queueDao.queueOf(blaise), isEmpty);
    });
  });

  group('remove', () {
    test('removing a middle item renumbers the rest contiguously',
        () async {
      final profileId = await seedProfile();
      final a = await seedWork(profileId, 'A');
      final b = await seedWork(profileId, 'B');
      final c = await seedWork(profileId, 'C');
      await db.queueDao.playLast(profileId: profileId, workId: a, nowMs: 1);
      await db.queueDao.playLast(profileId: profileId, workId: b, nowMs: 2);
      await db.queueDao.playLast(profileId: profileId, workId: c, nowMs: 3);

      await db.queueDao.remove(profileId: profileId, workId: b);

      final rows = await db.queueDao.queueOf(profileId);
      expect(rows.map((r) => r.workId), [a, c]);
      expect(rows.map((r) => r.position), [0, 1]);
    });

    test('removing a work not in the queue is a harmless no-op', () async {
      final profileId = await seedProfile();
      final a = await seedWork(profileId, 'A');
      await db.queueDao.playLast(profileId: profileId, workId: a, nowMs: 1);

      await db.queueDao.remove(profileId: profileId, workId: 9999);

      expect(await db.queueDao.queueOf(profileId), hasLength(1));
    });
  });

  group('reorder (drag in the queue view)', () {
    test('moving the tail item to the head reorders everyone', () async {
      final profileId = await seedProfile();
      final a = await seedWork(profileId, 'A');
      final b = await seedWork(profileId, 'B');
      final c = await seedWork(profileId, 'C');
      await db.queueDao.playLast(profileId: profileId, workId: a, nowMs: 1);
      await db.queueDao.playLast(profileId: profileId, workId: b, nowMs: 2);
      await db.queueDao.playLast(profileId: profileId, workId: c, nowMs: 3);

      await db.queueDao
          .reorder(profileId: profileId, workId: c, newPosition: 0);

      final rows = await db.queueDao.queueOf(profileId);
      expect(rows.map((r) => r.workId), [c, a, b]);
      expect(rows.map((r) => r.position), [0, 1, 2]);
    });
  });

  group('headOf', () {
    test('the head is the lowest position; null on an empty queue',
        () async {
      final profileId = await seedProfile();
      expect(await db.queueDao.headOf(profileId), isNull);

      final a = await seedWork(profileId, 'A');
      final b = await seedWork(profileId, 'B');
      await db.queueDao.playLast(profileId: profileId, workId: a, nowMs: 1);
      await db.queueDao.playLast(profileId: profileId, workId: b, nowMs: 2);

      expect((await db.queueDao.headOf(profileId))!.workId, a);
    });
  });

  group('cascades', () {
    test('deleteWork takes its queue row with it — a queued work can be '
        'swept or unfollowed without a foreign-key violation', () async {
      final profileId = await seedProfile();
      final work = await seedWork(profileId, 'A');
      await db.queueDao
          .playLast(profileId: profileId, workId: work, nowMs: 1);

      await db.spineDao.deleteWork(work);

      expect(await db.queueDao.queueOf(profileId), isEmpty);
    });
  });

  group('queueEntriesOf', () {
    test('joins the work so the queue view has titles without a second '
        'query per row', () async {
      final profileId = await seedProfile();
      final a = await seedWork(profileId, 'Aurora');
      await db.queueDao.playLast(profileId: profileId, workId: a, nowMs: 1);

      final entries = await db.queueDao.queueEntriesOf(profileId);
      expect(entries.single.work.title, 'Aurora');
      expect(entries.single.row.workId, a);
    });
  });
}
