import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/episodes/episode_actions.dart';
import 'package:trellis/features/feeds/background/feed_check_section.dart';
import 'package:trellis/features/feeds/background/feed_check_settings.dart';
import 'package:trellis/features/feeds/episode_download_coordinator.dart';
import 'package:trellis/features/jobs/jobs_screen.dart';

import '../support/fake_services.dart';
import 'feed_check_settings_test.dart' show FakeScheduler;

/// "Download only on Wi-Fi" (1.6.0, user: "download on WiFi or not" was
/// missing), as the listener meets it: the switch, the line where they
/// tapped Download, and the waiting row with its one way past.
void main() {
  late Directory dir;
  late AppDatabase db;
  late int profileId;
  const url = 'https://cast.test/1.mp3';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('trellis-wifi-ui');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  testWidgets('the switch sits with the feed-check switches, off until '
      'chosen, and remembers', (tester) async {
    final settings = FeedCheckSettings(db, FakeScheduler());
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: FeedCheckSection(settings: settings)))));
    await tester.pumpAndSettle();

    final toggle = find.byKey(const Key('downloads-wifi-only'));
    expect(find.text('Download only on Wi-Fi'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    expect(await FeedCheckSettings.downloadsWifiOnlyOn(db), isTrue);
  });

  testWidgets('Download on mobile data says it is waiting for Wi-Fi, and '
      'fetches nothing', (tester) async {
    final feedId = await db.feedsDao
        .insertFeed(profileId: profileId, url: 'https://cast.test/feed');
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Episode one',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: url);
    await db.feedsDao.insertEpisode(
        workId: workId,
        feedId: feedId,
        guid: 'g1',
        enclosureUrl: url,
        publishedAtMs: 1000);
    final fetcher = FakeAudioFetcher();
    final services = testServices(dir, audioFetcher: fetcher);
    final downloads = EpisodeDownloadCoordinator(services: services, db: db)
      ..mustWaitForWifi = () async => true;
    final actions = EpisodeActions(
        db: db,
        profileId: profileId,
        downloader: downloads,
        services: services,
        useDefaultShare: false);
    final entry = (
      work: (await db.spineDao.workById(workId))!,
      episode: (await db.feedsDao.episodeOf(workId))!,
    );
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () => actions.download(context, entry),
                    child: const Text('go'))))));

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('consent-accept')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Waiting for Wi-Fi'), findsOneWidget);
    expect(fetcher.fetched, isEmpty);
    expect(downloads.stateOf(workId).waitingForWifi, isTrue);
  });

  testWidgets('a waiting download’s card says so and offers Download now, '
      'which fetches it', (tester) async {
    final fetcher = FakeAudioFetcher();
    final services = testServices(dir, audioFetcher: fetcher);
    final downloads = EpisodeDownloadCoordinator(services: services, db: db)
      ..mustWaitForWifi = () async => true;
    await downloads.startByHand(workId: 1, url: url, title: 'Episode one');

    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ListenableBuilder(
                listenable: downloads,
                builder: (_, _) => downloads.entries.isEmpty
                    ? const Text('done')
                    : DownloadJobCard(
                        coordinator: downloads,
                        workId: 1,
                        state: downloads.stateOf(1))))));
    await tester.pumpAndSettle();

    expect(find.text('Waiting for Wi-Fi'), findsOneWidget);
    expect(find.text('Resume'), findsNothing);
    await tester.tap(find.byKey(const Key('download-now-1')));
    await tester.pumpAndSettle();

    expect(fetcher.fetched, [url]);
    expect(find.text('done'), findsOneWidget);
  });
}
