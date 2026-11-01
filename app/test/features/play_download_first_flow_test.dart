import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/feeds/background/feed_check_settings.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/fake_services.dart';
import '../support/pick_reader.dart';
import '../support/scripted_fetcher.dart';

/// "Play on an episode that isn't downloaded" (1.6.0, user: "Play for
/// download then play"), in the app: the row's Play, the line that says
/// what is happening, and the file playing once it has landed.
void main() {
  late Directory dir;
  late AppDatabase db;
  late FakeEpisodePlayer player;
  late ControllableAudioFetcher audio;
  late int profileId;
  const url = 'https://cast.test/1.mp3';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('trellis-play-first-flow');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    player = FakeEpisodePlayer();
    audio = ControllableAudioFetcher();
    profileId = await db.profilesDao.create('Ada');
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<int> seedEpisode() async {
    final feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://cast.test/feed', title: 'Show');
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Harbour episode',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: url);
    await db.feedsDao.insertEpisode(
        workId: id,
        feedId: feedId,
        guid: 'g1',
        enclosureUrl: url,
        publishedAtMs: 1000);
    return id;
  }

  Future<void> boot(WidgetTester tester) async {
    await tester.pumpWidget(TrellisApp(
        db: db,
        fetcher: ScriptedFetcher((u, h) => textResponse('')),
        createPlayer: () => player,
        services: testServices(dir, audioFetcher: audio)));
    await tester.pumpAndSettle();
    await pickReader(tester, 'Ada');
    await tester.tap(find.descendant(
        of: find.byType(NavigationBar), matching: find.text('Latest')));
    await tester.pumpAndSettle();
  }

  testWidgets('with Download first chosen, Play on a row says it is '
      'downloading, streams nothing, and plays the file once it has landed',
      (tester) async {
    final id = await seedEpisode();
    await FeedCheckSettings(db, const UnavailableFeedCheckScheduler())
        .setDownloadFirst(true);
    await boot(tester);

    await tester.tap(find.byKey(Key('play-$id')));
    // A download in flight keeps its progress turning, so the screen
    // never settles: pump a fixed while instead.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('Downloading first. It plays when it’s ready.'),
        findsOneWidget);
    expect(audio.fetched, [url]);
    expect(player.loadedUrl, isNull);
    expect(player.loadedFilePath, isNull);

    audio.completeDownload();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();

    expect(player.loadedFilePath, audio.target!.path);
    expect(player.loadedUrl, isNull);
    expect(player.playing, isTrue);
  });

  testWidgets('left on Stream, the same Play streams at once and downloads '
      'nothing', (tester) async {
    final id = await seedEpisode();
    await boot(tester);

    await tester.tap(find.byKey(Key('play-$id')));
    await tester.pumpAndSettle();

    expect(player.loadedUrl, url);
    expect(audio.fetched, isEmpty);
    expect(find.text('Downloading first. It plays when it’s ready.'),
        findsNothing);
  });
}
