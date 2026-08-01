import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/river/river_triage.dart';

/// Phase 1 triage verbs (Campaign 5, "the river gets hands"): Keep promotes
/// a river item into the library — the existing library-add path
/// ([SpineDao.promoteWork]) — and marks it read, since it has left the
/// river's unread flow. Let it pass is the explicit dismissal: marks read,
/// nothing more. Both are undoable to the EXACT prior state (Peckish's
/// verbatim-restore idiom), not merely "the opposite" — a swipe on an
/// already-read item must undo back to read, not to unread.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<int> seedItem(
      {required int profileId,
      required int feedId,
      String persistence = 'ephemeron',
      int? readAtMs}) async {
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'article',
        title: 'An item',
        persistence: persistence,
        firstSeenEpochDay: 100);
    await db.feedsDao.insertEpisode(
        workId: workId,
        feedId: feedId,
        guid: 'g-$workId',
        enclosureUrl: null,
        publishedAtMs: 1000);
    if (readAtMs != null) await db.feedsDao.setReadAt(workId, readAtMs);
    return workId;
  }

  group('keep', () {
    test('promotes the work to the library and marks it read', () async {
      final profileId = await db.profilesDao.create('Ada');
      final feedId =
          await db.feedsDao.insertFeed(profileId: profileId, url: 'https://a/f');
      final workId = await seedItem(profileId: profileId, feedId: feedId);

      await RiverTriage(db).keep(workId, nowMs: 5000);

      final work = await db.spineDao.workById(workId);
      expect(work!.persistence, 'work',
          reason: 'kept things live in the library — the whole law');
      final episode =
          (await db.feedsDao.episodesOfFeed(feedId)).single.episode;
      expect(episode.readAtMs, 5000);
    });
  });

  group('letItPass', () {
    test('marks read without promoting', () async {
      final profileId = await db.profilesDao.create('Ada');
      final feedId =
          await db.feedsDao.insertFeed(profileId: profileId, url: 'https://a/f');
      final workId = await seedItem(profileId: profileId, feedId: feedId);

      await RiverTriage(db).letItPass(workId, nowMs: 5000);

      final work = await db.spineDao.workById(workId);
      expect(work!.persistence, 'ephemeron',
          reason: 'let it pass never promotes — decay still handles aging');
      final episode =
          (await db.feedsDao.episodesOfFeed(feedId)).single.episode;
      expect(episode.readAtMs, 5000);
    });
  });

  group('undo', () {
    test('restores an unread ephemeron exactly after Keep', () async {
      final profileId = await db.profilesDao.create('Ada');
      final feedId =
          await db.feedsDao.insertFeed(profileId: profileId, url: 'https://a/f');
      final workId = await seedItem(profileId: profileId, feedId: feedId);
      final triage = RiverTriage(db);
      final prior = triage.priorStateOf(
          persistence: 'ephemeron', readAtMs: null);

      await triage.keep(workId, nowMs: 5000);
      await triage.undo(workId, prior);

      final work = await db.spineDao.workById(workId);
      final episode =
          (await db.feedsDao.episodesOfFeed(feedId)).single.episode;
      expect(work!.persistence, 'ephemeron');
      expect(episode.readAtMs, isNull);
    });

    test('restores an already-read item to read, not to unread — verbatim, '
        'not "the opposite"', () async {
      final profileId = await db.profilesDao.create('Ada');
      final feedId =
          await db.feedsDao.insertFeed(profileId: profileId, url: 'https://a/f');
      final workId = await seedItem(
          profileId: profileId, feedId: feedId, readAtMs: 999);
      final triage = RiverTriage(db);
      final prior =
          triage.priorStateOf(persistence: 'ephemeron', readAtMs: 999);

      await triage.letItPass(workId, nowMs: 5000);
      await triage.undo(workId, prior);

      final episode =
          (await db.feedsDao.episodesOfFeed(feedId)).single.episode;
      expect(episode.readAtMs, 999);
    });

    test('restores a work already promoted before Keep — pin then Keep then '
        'Undo leaves it promoted, not demoted', () async {
      final profileId = await db.profilesDao.create('Ada');
      final feedId =
          await db.feedsDao.insertFeed(profileId: profileId, url: 'https://a/f');
      final workId = await seedItem(
          profileId: profileId, feedId: feedId, persistence: 'work');
      final triage = RiverTriage(db);
      final prior = triage.priorStateOf(persistence: 'work', readAtMs: null);

      await triage.keep(workId, nowMs: 5000);
      await triage.undo(workId, prior);

      final work = await db.spineDao.workById(workId);
      expect(work!.persistence, 'work',
          reason: 'it was already in the library before this Keep — undo '
              'must not evict it');
    });
  });
}
