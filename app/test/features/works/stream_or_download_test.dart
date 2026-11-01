import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/episodes/episode_actions.dart';
import 'package:trellis/features/feeds/episode_download_coordinator.dart';
import 'package:trellis/features/player/play_fetch.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/reader/reader_doors.dart';
import 'package:trellis/features/transcribe/transcribe_coordinator.dart';
import 'package:trellis/features/works/work_open.dart';
import 'package:trellis/features/works/work_row.dart';
import 'package:trellis/services/device_services.dart';

import '../../support/fake_player.dart';
import '../../support/fake_services.dart';

/// Stream or download, chosen per episode (owner, 23 Oct: "I like
/// antennapod's 'stream vs play vs download' features if you want to make
/// that more explicit"; 9 Nov: "Play for download then play ... all
/// missing"). The setting stays the default; the episode's page and a
/// row's ⋮ offer the other choice for this play, and a download under
/// way shows where Play is.
void main() {
  late AppDatabase db;
  late int profileId;
  late int episode;
  late Directory dir;
  late DeviceServices services;
  late ControllableAudioFetcher fetcher;
  late EpisodeDownloadCoordinator downloads;
  late FakeEpisodePlayer fake;
  late PlayerController controller;
  late bool downloadFirst;
  const url = 'https://x.test/aurora.mp3';

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
    final feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://x.test/f', title: 'Night Sky');
    episode = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Aurora season',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: url);
    await db.feedsDao.insertEpisode(
        workId: episode,
        feedId: feedId,
        guid: 'aurora',
        enclosureUrl: url,
        durationMs: 60 * 60000,
        publishedAtMs: 1000);
    dir = Directory.systemTemp.createTempSync('trellis-stream-or-download');
    fetcher = ControllableAudioFetcher();
    services = testServices(dir, audioFetcher: fetcher);
    downloads = EpisodeDownloadCoordinator(services: services, db: db);
    fake = FakeEpisodePlayer();
    downloadFirst = false;
    controller = PlayerController(
        db: db,
        profileId: profileId,
        createPlayer: () => fake,
        localAudioFileFor: services.audioFileFor,
        downloadFirst: () async => downloadFirst,
        beginFetch: (work, u) => beginEpisodeFetch(downloads, work, u));
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
    dir.deleteSync(recursive: true);
  });

  EpisodeActions actions() => EpisodeActions(
      db: db,
      profileId: profileId,
      player: controller,
      downloader: downloads,
      transcriber: TranscribeCoordinator(db: db, services: services),
      services: services,
      transcribeRate: () => 1 / 12);

  Future<EpisodeEntry> entry() async => (
        work: (await db.spineDao.workById(episode))!,
        episode: (await db.feedsDao.episodeOf(episode))!,
      );

  Future<void> pumpPage(WidgetTester tester) async {
    final a = actions();
    final doors = WorkDoors(
        db: db,
        profileId: profileId,
        readerDoors: ReaderDoors(player: controller),
        actions: a,
        transcribeRate: () => 1 / 12);
    final e = await tester.runAsync(entry);
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: Center(
                    child: TextButton(
                        onPressed: () => doors.open(context, e!),
                        child: const Text('open')))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  // The other way to play is in the page's ⋮ (board-0161: the page had
  // too many buttons), as in every row's.
  Future<Finder> other(WidgetTester tester, String value) async {
    await tester.tap(find.byKey(const Key('work-page-menu')));
    await tester.pumpAndSettle();
    return find.byKey(Key('$value-$episode'));
  }

  testWidgets('set to Stream, the page’s ⋮ offers Download, then play; it '
      'downloads, shows how far where Play is, then plays the file',
      (tester) async {
    await pumpPage(tester);
    final item = await other(tester, 'download-play');
    expect(find.descendant(of: item, matching: find.text('Download, then play')),
        findsOneWidget);
    expect(tester.getSize(item).height, greaterThanOrEqualTo(48));

    await tester.tap(item);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(fetcher.fetched, [url]);
    expect(fake.loadedUrl, isNull, reason: 'nothing streams meanwhile');

    fetcher.emitProgress(400, 1000);
    await tester.pump();
    expect(
        tester.widget<Text>(find.byKey(const Key('page-play-caption'))).data,
        'Downloading, 40%');

    await tester.runAsync(() async {
      fetcher.completeDownload();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(fake.loadedFilePath, services.audioFileFor(episode, url).path);
  });

  testWidgets('set to Download first, the page’s ⋮ offers Stream now, and '
      'it streams at once', (tester) async {
    downloadFirst = true;
    await pumpPage(tester);
    final item = await other(tester, 'stream-now');
    expect(find.descendant(of: item, matching: find.text('Stream now')),
        findsOneWidget);

    await tester.tap(item);
    await tester.pumpAndSettle();
    expect(fake.loadedUrl, url);
    expect(fetcher.fetched, isEmpty);
  });

  testWidgets('a row’s ⋮ offers both, and each plays its way', (tester) async {
    final a = actions();
    final e = (await tester.runAsync(entry))!;
    final values = [
      for (final i in a.sharedMenuItems(e))
        if (i is PopupMenuItem<String>) i.value
    ];
    expect(values, containsAll(['stream-now', 'download-play']));

    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    })));
    downloadFirst = true;
    await tester.runAsync(() => a.handleShared(ctx, 'stream-now', e));
    expect(fake.loadedUrl, url);
    expect(fetcher.fetched, isEmpty);
  });

  testWidgets('a row shows a download under way where Play is',
      (tester) async {
    final e = (await tester.runAsync(entry))!;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: WorkRow(
                work: e.work,
                episode: e.episode,
                facts: const WorkRowFacts(audio: true),
                onPlay: () {},
                player: controller,
                downloads: downloads))));
    expect(find.text('Play'), findsOneWidget);

    downloads.start(workId: episode, url: url);
    await tester.runAsync(() async {
      while (fetcher.target == null) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await tester.pump();
    expect(
        find.descendant(
            of: find.byKey(Key('play-$episode')),
            matching: find.textContaining('Downloading')),
        findsOneWidget);
    fetcher.emitProgress(250, 1000);
    await tester.pump();
    expect(
        find.descendant(
            of: find.byKey(Key('play-$episode')),
            matching: find.text('Downloading, 25%')),
        findsOneWidget);
    await tester.runAsync(() async {
      fetcher.completeDownload();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
  });
}
