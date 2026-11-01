import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/feeds/background/feed_check_section.dart';
import 'package:trellis/features/feeds/background/feed_check_settings.dart';
import 'package:trellis/features/feeds/episode_download_coordinator.dart';
import 'package:trellis/features/player/play_fetch.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/transcribe/audio_fetcher.dart';

import '../support/fake_services.dart';
import 'feed_check_settings_test.dart' show FakeScheduler;

/// "Play on an episode that isn't downloaded" (1.6.0, user: "Play for
/// download then play"): the setting, and the pieces between the player
/// and the download coordinator. What the player does with them is in
/// player_test.dart.
void main() {
  late Directory dir;
  late AppDatabase db;
  late int profileId;
  const url = 'https://cast.test/1.mp3';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('trellis-play-fetch-glue');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<Work> seedEpisode() async {
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Episode one',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: url);
    return (await db.spineDao.worksOf(profileId)).firstWhere((w) => w.id == id);
  }

  group('the setting', () {
    test('Play streams until Download first is chosen; the choice is '
        'remembered and asks the scheduler nothing', () async {
      final s = FakeScheduler();
      final settings = FeedCheckSettings(db, s);
      await settings.load();
      expect(settings.downloadFirst, isFalse);
      expect(await FeedCheckSettings.downloadFirstOn(db), isFalse);

      await settings.setDownloadFirst(true);

      expect(settings.downloadFirst, isTrue);
      expect(await FeedCheckSettings.downloadFirstOn(db), isTrue);
      final again = FeedCheckSettings(db, FakeScheduler());
      await again.load();
      expect(again.downloadFirst, isTrue);
      expect(s.calls, isEmpty);

      await again.setDownloadFirst(false);
      expect(await FeedCheckSettings.downloadFirstOn(db), isFalse);
    });

    testWidgets('its switch sits under Downloads, off until chosen',
        (tester) async {
      final settings = FeedCheckSettings(db, FakeScheduler());
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(
                  child: FeedCheckSection(settings: settings)))));
      await tester.pumpAndSettle();

      final toggle = find.byKey(const Key('play-download-first'));
      expect(find.text('Download first, then play'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);

      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      expect(await FeedCheckSettings.downloadFirstOn(db), isTrue);
    });
  });

  group('the fetch a Play begins', () {
    EpisodeDownloadCoordinator coordinatorWith(AudioFetcher fetcher) =>
        EpisodeDownloadCoordinator(
            services: testServices(dir, audioFetcher: fetcher), db: db);

    test('where it must wait for Wi-Fi: nothing to wait on, nothing '
        'fetched, and the episode is left to the next Wi-Fi pass', () async {
      final fetcher = FakeAudioFetcher();
      final downloads = coordinatorWith(fetcher);
      var passes = 0;
      downloads.mustWaitForWifi = () async => true;
      downloads.requestWifiPass = () async => passes++;
      final work = await seedEpisode();

      expect(await downloads.waitsForWifi(work.id, url), isTrue);
      final landing = await beginEpisodeFetch(downloads, work, url);

      expect(landing, isNull);
      expect(fetcher.fetched, isEmpty);
      expect(downloads.stateOf(work.id).waitingForWifi, isTrue);
      expect(downloads.stateOf(work.id).title, 'Episode one');
      expect(passes, 1);
    });

    test('on Wi-Fi it downloads, and ends landed with the file on disk',
        () async {
      final fetcher = FakeAudioFetcher();
      final downloads = coordinatorWith(fetcher);
      downloads.mustWaitForWifi = () async => false;
      final work = await seedEpisode();

      expect(await downloads.waitsForWifi(work.id, url), isFalse);
      final landing = await beginEpisodeFetch(downloads, work, url);

      expect(await landing, FetchEnd.landed);
      expect(fetcher.fetched, [url]);
      expect(downloads.isDownloaded(work.id, url), isTrue);
    });

    test('a download already running is joined, not started twice, and '
        'is never made to wait', () async {
      final fetcher = ControllableAudioFetcher();
      final downloads = coordinatorWith(fetcher);
      final work = await seedEpisode();
      final byHand = downloads.start(workId: work.id, url: url, title: 'E');
      await pumpEventQueue();
      downloads.mustWaitForWifi = () async => true;

      expect(await downloads.waitsForWifi(work.id, url), isFalse);
      final landing = await beginEpisodeFetch(downloads, work, url);
      await pumpEventQueue();
      fetcher.completeDownload();

      expect(await landing, FetchEnd.landed);
      expect(await byHand, DownloadOutcome.done);
      expect(fetcher.fetched, [url]);
    });

    test('paused by the listener it ends paused; failed, failed', () async {
      final fetcher = ControllableAudioFetcher();
      final downloads = coordinatorWith(fetcher);
      final work = await seedEpisode();

      var landing = await beginEpisodeFetch(downloads, work, url);
      await pumpEventQueue();
      downloads.cancel(work.id);
      expect(await landing, FetchEnd.paused);

      landing = await beginEpisodeFetch(downloads, work, url);
      await pumpEventQueue();
      fetcher.failDownload(const FormatException('not audio'));
      expect(await landing, FetchEnd.failed);
    });
  });

  test('each thing the player reports has its own plain sentence', () {
    final words = {for (final n in PlayNotice.values) n: playNoticeWords(n)};

    expect(words.values.toSet(), hasLength(PlayNotice.values.length));
    expect(words[PlayNotice.downloadingFirst], contains('Downloading'));
    expect(words[PlayNotice.waitingForWifi], contains('Wi-Fi'));
    expect(words[PlayNotice.downloadFailed], contains('download'));
  });
}
