import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/bulk_episodes.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/search/search_store.dart';

/// Counts transactions, so "one bulk action is one transaction" is a
/// fact the suite checks rather than a comment.
class _Counter extends QueryInterceptor {
  int transactions = 0;

  @override
  TransactionExecutor beginTransaction(QueryExecutor parent) {
    transactions++;
    return super.beginTransaction(parent);
  }
}

/// ADR-0016 section 5: the clean-up's bulk writes, each one transaction,
/// each undone to the exact state before it.
void main() {
  late AppDatabase db;
  late _Counter counter;
  late int profileId;
  late int feedId;
  late BulkEpisodes bulk;

  setUp(() async {
    counter = _Counter();
    db = AppDatabase.forTesting(NativeDatabase.memory().interceptWith(counter));
    profileId = await db.profilesDao.create('Ada');
    feedId = await db.feedsDao.insertFeed(profileId: profileId, url: 'f');
    bulk = BulkEpisodes(db);
  });
  tearDown(() => db.close());

  Future<int> episode(String guid, {bool audio = true}) async {
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: guid,
        persistence: 'ephemeron',
        firstSeenEpochDay: 100);
    await db.feedsDao.insertEpisode(
        workId: id,
        feedId: feedId,
        guid: guid,
        enclosureUrl: audio ? 'https://x.test/$guid.mp3' : null,
        publishedAtMs: id);
    return id;
  }

  Future<Episode> ep(int id) async => (await db.feedsDao.episodeOf(id))!;

  group('mark played', () {
    test('fills only what was blank, and Undo puts back exactly that',
        () async {
      final fresh = await episode('a');
      final seen = await episode('b');
      final done = await episode('c');
      await db.feedsDao.setReadAt(seen, 5);
      await db.feedsDao.markPlayed(done, 7);

      final change =
          await bulk.markPlayed([fresh, seen, done], nowMs: 1000);
      expect(change.count, 2, reason: 'one was already played');
      expect((await ep(fresh)).finishedAtMs, 1000);
      expect((await ep(fresh)).readAtMs, 1000);
      expect((await ep(seen)).readAtMs, 5, reason: 'seen keeps its day');
      expect((await ep(done)).finishedAtMs, 7, reason: 'first finish wins');

      await change.undo();
      expect((await ep(fresh)).finishedAtMs, isNull);
      expect((await ep(fresh)).readAtMs, isNull);
      expect((await ep(seen)).finishedAtMs, isNull);
      expect((await ep(seen)).readAtMs, 5);
      expect((await ep(done)).finishedAtMs, 7);
      expect((await ep(done)).readAtMs, 7);
    });

    test('does not promote and does not reach History', () async {
      final a = await episode('a');
      await bulk.markPlayed([a], nowMs: 1000);
      final work = (await db.spineDao.worksOf(profileId)).single;
      expect(work.persistence, 'ephemeron');
      expect(work.finishedEpochDay, isNull);
      expect(await SearchStore(db).history(profileId), isEmpty);
    });

    test('5,000 episodes in one transaction', () async {
      final ids = <int>[];
      await db.transaction(() async {
        for (var i = 0; i < 5000; i++) {
          ids.add(await episode('g$i'));
        }
      });
      counter.transactions = 0;
      final change = await bulk.markPlayed(ids, nowMs: 1000);
      expect(counter.transactions, 1);
      expect(change.count, 5000);
      final unplayed = await (db.select(db.episodes)
            ..where((e) => e.finishedAtMs.isNull()))
          .get();
      expect(unplayed, isEmpty);

      counter.transactions = 0;
      await change.undo();
      expect(counter.transactions, 1);
      final played = await (db.select(db.episodes)
            ..where((e) => e.finishedAtMs.isNotNull()))
          .get();
      expect(played, isEmpty);
    });
  });

  test('mark unplayed forgets places, and Undo restores every one', () async {
    final a = await episode('a');
    final b = await episode('b');
    await db.feedsDao.markPlayed(a, 7);
    await db.spineDao.markFinished(a, 42);
    await db.feedsDao
        .savePlayerPosition(profileId: profileId, workId: a, tMs: 9000);
    await db.spineDao.savePosition(
        profileId: profileId,
        workId: b,
        segmentIdx: 3,
        wordIdx: 1,
        lastModality: 'listen');
    final before = await SearchStore(db).history(profileId);
    expect(before, hasLength(2));
    final playerBefore = await db.select(db.playerPositions).get();
    final placesBefore = await db.select(db.positions).get();

    final change = await bulk.markUnplayed([a, b], profileId: profileId);
    expect(counter.transactions, greaterThan(0));
    expect((await ep(a)).finishedAtMs, isNull);
    expect(await db.select(db.playerPositions).get(), isEmpty);
    expect(await db.select(db.positions).get(), isEmpty);

    await change.undo();
    expect((await ep(a)).finishedAtMs, 7);
    final work =
        (await db.spineDao.worksOf(profileId)).firstWhere((w) => w.id == a);
    expect(work.finishedEpochDay, 42);
    expect(await db.select(db.playerPositions).get(),
        unorderedEquals(playerBefore));
    expect(
        await db.select(db.positions).get(), unorderedEquals(placesBefore));
    final after = await SearchStore(db).history(profileId);
    expect([for (final h in after) (h.item.work.id, h.atMs)],
        [for (final h in before) (h.item.work.id, h.atMs)]);
  });

  test('mark unplayed on an unfinished, half-heard episode still counts '
      'and undoes', () async {
    final a = await episode('a');
    await db.feedsDao
        .savePlayerPosition(profileId: profileId, workId: a, tMs: 9000);
    final change = await bulk.markUnplayed([a], profileId: profileId);
    expect(change.count, 1);
    expect(change.changed, isTrue);
    expect(await db.select(db.playerPositions).get(), isEmpty);
    await change.undo();
    expect((await db.select(db.playerPositions).get()).single.tMs, 9000);
  });

  test('a finished row that only gains its seen day is still a change',
      () async {
    final a = await episode('a');
    await db.feedsDao.setFinished(a, 7);
    final change = await bulk.markPlayed([a], nowMs: 1000);
    expect(change.count, 0);
    expect(change.changed, isTrue);
    await change.undo();
    expect((await ep(a)).readAtMs, isNull);
  });

  test('Latest breaks a publish-time tie by id, newest id first',
      () async {
    final a = await episode('a');
    final b = await episode('b');
    await (db.update(db.episodes)..where((e) => e.workId.isIn([a, b])))
        .write(const EpisodesCompanion(publishedAtMs: Value(500)));
    final rows = await db.feedsDao.riverItems(profileId);
    expect([for (final r in rows) r.work.id], [b, a]);
  });

  test('let it pass marks seen, and Undo restores the old seen day',
      () async {
    final a = await episode('a', audio: false);
    final b = await episode('b');
    await db.feedsDao.setReadAt(b, 5);
    final change = await bulk.letPass([a, b], nowMs: 1000);
    expect(change.count, 1);
    expect((await ep(a)).readAtMs, 1000);
    expect((await ep(b)).readAtMs, 5);
    await change.undo();
    expect((await ep(a)).readAtMs, isNull);
    expect((await ep(b)).readAtMs, 5);
  });

  test('add to the queue appends the new ones; Undo removes only those',
      () async {
    final a = await episode('a');
    final b = await episode('b');
    final c = await episode('c');
    await db.queueDao.playLast(profileId: profileId, workId: b, nowMs: 1);
    final change =
        await bulk.addToQueue([a, b, c], profileId: profileId, nowMs: 2);
    expect(change.count, 2);
    expect([for (final r in await db.queueDao.queueOf(profileId)) r.workId],
        [b, a, c]);
    await change.undo();
    final rest = await db.queueDao.queueOf(profileId);
    expect([for (final r in rest) (r.workId, r.position)], [(b, 0)]);
  });
}
