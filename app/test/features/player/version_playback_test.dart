import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/player_controller.dart';

import '../../support/fake_player.dart';

/// A version plays as part of its episode's show (1.6.18): the show's art
/// and name, on the bar and the lock screen. Not the show's settings:
/// skipping its intro would cut the translation's first sentences.
void main() {
  late AppDatabase db;
  late Directory dir;
  late int profileId;
  late int feed;
  late int es;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    dir = Directory.systemTemp.createTempSync('trellis-version-play');
    profileId = await db.profilesDao.create('Ada');
    feed = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://cast.test/f', title: 'Harbour Show');
    await (db.update(db.feeds)..where((f) => f.id.equals(feed))).write(
        const FeedsCompanion(
            skipIntroSeconds: Value(30), speedOverride: Value(1.5)));
    final original = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Harbour',
        persistence: 'ephemeron',
        firstSeenEpochDay: 1,
        sourceUrl: 'https://cast.test/1.mp3');
    await db.feedsDao.insertEpisode(
        workId: original,
        feedId: feed,
        guid: 'g1',
        enclosureUrl: 'https://cast.test/1.mp3',
        publishedAtMs: 1);
    es = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'version',
        title: 'Harbour (Spanish)',
        persistence: 'ephemeron',
        firstSeenEpochDay: 1,
        sourceUrl: 'https://spoken.trellis.invalid/$original-es.ogg',
        lang: 'es');
    await db.versionsDao.put(workId: es, originalId: original, lang: 'es');
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  test('the show’s art and name, but none of the show’s settings', () async {
    final art = File('${dir.path}/art.jpg')..writeAsBytesSync([1]);
    final player = FakeEpisodePlayer();
    final c = PlayerController(
        db: db,
        profileId: profileId,
        createPlayer: () => player,
        artworkFileFor: (id) => id == feed ? art : File('${dir.path}/none.jpg'));
    addTearDown(c.dispose);

    await c.playWork((await db.spineDao.workById(es))!);

    expect(c.currentArtwork?.path, art.path);
    expect(player.loadedMediaItem?.album, 'Harbour Show');
    expect(player.loadedMediaItem?.title, 'Harbour (Spanish)');
    expect(c.currentFeed, isNull,
        reason: 'the show’s speed and intro skip are for its own audio');
    expect(player.log.where((e) => e.startsWith('seek:')), isEmpty);
  });
}
