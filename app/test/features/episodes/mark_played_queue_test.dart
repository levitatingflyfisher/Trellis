import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/bulk_episodes.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/episodes/episode_actions.dart';

/// Mark played takes an episode off the Queue, the same as hearing it to
/// the end (owner, 9 Nov: "It doesn't autoclear"), under the same setting.
void main() {
  late AppDatabase db;
  late int profileId;
  late int feedId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
    feedId = await db.feedsDao
        .insertFeed(profileId: profileId, url: 'https://a/f', title: 'Show');
  });
  tearDown(() => db.close());

  var seeded = 0;
  Future<int> queued(String title) async {
    final n = ++seeded;
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: title,
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://a/$n.mp3');
    await db.feedsDao.insertEpisode(
        workId: id,
        feedId: feedId,
        guid: 'g$n',
        enclosureUrl: 'https://a/$n.mp3',
        publishedAtMs: n);
    await db.queueDao.playLast(profileId: profileId, workId: id, nowMs: n);
    return id;
  }

  Future<List<int>> queue() async =>
      [for (final r in await db.queueDao.queueOf(profileId)) r.workId];

  EpisodeActions actions() => EpisodeActions(db: db, profileId: profileId);

  group('one episode, from its menu', () {
    test('leaves the Queue', () async {
      final a = await queued('A');
      final b = await queued('B');

      await actions().markPlayed(a);

      expect(await queue(), [b]);
      expect((await db.feedsDao.episodeOf(a))!.finishedAtMs, isNotNull);
    });

    test('stays when the household keeps finished episodes', () async {
      final a = await queued('A');
      await db.profilesDao.setKeepFinishedInQueue(profileId, true);

      await actions().markPlayed(a);

      expect(await queue(), [a]);
    });
  });

  group('many at once', () {
    test('leave the Queue; Undo puts them back where they were', () async {
      final a = await queued('A');
      final b = await queued('B');
      final c = await queued('C');

      final change = await BulkEpisodes(db)
          .markPlayed([a, c], nowMs: 1000, leaveQueueOf: profileId);

      expect(await queue(), [b]);
      await change.undo();
      expect(await queue(), [a, b, c]);
    });

    test('stay when the household keeps finished episodes', () async {
      final a = await queued('A');
      await db.profilesDao.setKeepFinishedInQueue(profileId, true);

      await BulkEpisodes(db)
          .markPlayed([a], nowMs: 1000, leaveQueueOf: profileId);

      expect(await queue(), [a]);
    });
  });
}
