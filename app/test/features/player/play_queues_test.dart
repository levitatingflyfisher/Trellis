import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/episodes/episode_actions.dart';
import 'package:trellis/features/player/player_controller.dart';

import '../../support/fake_player.dart';

/// Owner, 14 Nov 2026: tapping Play puts that episode at the head of the
/// queue, or moves it there, so the queue always matches what he hears;
/// it leaves when finished and the next starts.
void main() {
  late AppDatabase db;
  late PlayerController controller;
  late FakeEpisodePlayer player;
  late int profileId;
  late int feedId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
    feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://cast.test/f', title: 'Show');
    player = FakeEpisodePlayer();
    controller = PlayerController(
        db: db,
        profileId: profileId,
        createPlayer: () => player = FakeEpisodePlayer());
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
  });

  Future<Work> ep(String title) async {
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: title,
        persistence: 'ephemeron',
        firstSeenEpochDay: 1,
        sourceUrl: 'https://cast.test/$title.mp3');
    await db.feedsDao.insertEpisode(
        workId: id,
        feedId: feedId,
        guid: title,
        enclosureUrl: 'https://cast.test/$title.mp3',
        publishedAtMs: id);
    return (await db.spineDao.workById(id))!;
  }

  Future<List<String>> queue() async => [
        for (final r in await db.queueDao.queueOf(profileId))
          (await db.spineDao.workById(r.workId))!.title
      ];

  Future<void> last(Work w) =>
      db.queueDao.playLast(profileId: profileId, workId: w.id, nowMs: 1);

  test('Play on an episode not in the queue puts it at the head', () async {
    final a = await ep('A'), b = await ep('B'), c = await ep('C');
    await last(a);
    await last(b);
    await controller.playWork(c);
    expect(await queue(), ['C', 'A', 'B']);
  });

  test('Play on one already queued moves it to the head', () async {
    final a = await ep('A'), b = await ep('B'), c = await ep('C');
    for (final w in [a, b, c]) {
      await last(w);
    }
    await controller.playWork(c);
    expect(await queue(), ['C', 'A', 'B']);
  });

  test('finished, it leaves and the next starts', () async {
    final a = await ep('A'), b = await ep('B');
    await last(a);
    await controller.playWork(b);
    expect(await queue(), ['B', 'A']);
    player.emitCompleted();
    await pumpEventQueue();
    expect(await queue(), ['A']);
    expect(controller.current?.id, a.id);
  });

  test('Play next while one plays goes just after it, not before it',
      () async {
    final a = await ep('A'), b = await ep('B'), c = await ep('C');
    await last(a);
    await controller.playWork(b);
    final actions =
        EpisodeActions(db: db, profileId: profileId, player: controller);
    await actions.playNext(c.id);
    expect(await queue(), ['B', 'C', 'A']);
  });

  test('pause and play again does not move anything', () async {
    final a = await ep('A'), b = await ep('B');
    await controller.playWork(a);
    await last(b);
    await db.queueDao.reorder(profileId: profileId, workId: b.id, newPosition: 0);
    expect(await queue(), ['B', 'A']);
    await controller.playWork(a); // the same work: a pause
    await controller.playWork(a); // and play again
    expect(await queue(), ['B', 'A']);
  });
}
