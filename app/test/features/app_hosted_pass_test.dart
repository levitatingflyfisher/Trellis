// A pass the worker hands to the app runs on the app's coordinator,
// wired by the same factory both engines use (ADR-0018). These tests stop
// one the way the system does and check the picks are not lost.
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/feeds/auto_download.dart';
import 'package:trellis/features/feeds/background/feed_check_handoff.dart';
import 'package:trellis/features/feeds/background/feed_check_runner.dart';
import 'package:trellis/features/feeds/background/feed_check_settings.dart';
import 'package:trellis/features/feeds/episode_download_coordinator.dart';
import 'package:trellis/features/feeds/feeds_repository.dart';

import '../support/fake_services.dart';
import '../support/scripted_fetcher.dart';
import 'feed_check_handoff_test.dart' show FakeDirectory;
import 'feed_check_settings_test.dart' show FakeScheduler;

void main() {
  late Directory dir;
  late AppDatabase db;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('trellis-app-pass');
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<int> episode(int profileId, int feedId, int t) async {
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Ep $t',
        persistence: 'ephemeron',
        firstSeenEpochDay: 0);
    await db.feedsDao.insertEpisodeIfNew(
        workId: workId,
        feedId: feedId,
        guid: 'g$workId',
        enclosureUrl: 'https://cast.test/$workId.mp3',
        publishedAtMs: t);
    return workId;
  }

  test('a handed-over pass the system stops leaves its picks queued, and '
      'they show on the Jobs screen before they start', () async {
    final profileId = await db.profilesDao.create('Reader');
    final feedId = await db.feedsDao
        .insertFeed(profileId: profileId, url: 'https://cast.test/feed');
    await setFeedAutoDownload(db, feedId, true);
    final newer = await episode(profileId, feedId, 20);
    final older = await episode(profileId, feedId, 10);

    final fetcher = ControllableAudioFetcher();
    final downloads = EpisodeDownloadCoordinator(
        services: testServices(dir, audioFetcher: fetcher), db: db);
    final runner = FeedCheckRunner.withCoordinator(
      db: db,
      repository: FeedsRepository(
          db: db, fetcher: ScriptedFetcher((_, _) => textResponse(''))),
      scheduler: FakeScheduler(),
      downloads: downloads,
    );
    final directory = FakeDirectory();
    final host = FeedCheckHost(
        directory: directory,
        runTask: (task, stop) => runner.run(task, stop: stop));
    await host.open();
    addTearDown(host.close);
    final worker = FeedCheckWorker(
        directory: directory,
        runHere: (_, _) async => fail('the worker ran it itself'));

    final running = worker.run(FeedCheckTask.autoDownload);
    for (var i = 0; i < 200 && fetcher.fetched.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(fetcher.fetched, ['https://cast.test/$newer.mp3']);
    expect(downloads.stateOf(older).paused, isTrue,
        reason: 'queued before it starts, so the Jobs screen lists it');

    worker.stop();
    expect(await running, isFalse, reason: 'picks remain: try again');

    Future<Map<String, Object?>> payload(int workId) async =>
        jsonDecode(await db.jobsDao.payloadOf(downloadJobId(workId)))
            as Map<String, Object?>;
    for (final id in [newer, older]) {
      expect(await payload(id), containsPair('queued', true), reason: '$id');
      expect(await payload(id), containsPair('auto', true), reason: '$id');
    }
    expect([for (final q in await queuedAutoDownloads(db)) q.workId],
        unorderedEquals([newer, older]));
  });

  test('both engines build their runner through the one factory', () {
    for (final path in [
      'lib/features/profiles/home_flow.dart',
      'lib/features/feeds/background/feed_check_platform_io.dart',
    ]) {
      final src = File(path).readAsStringSync();
      expect(src, contains('FeedCheckRunner.withCoordinator('), reason: path);
      expect(src, isNot(contains('FeedCheckRunner(\n')), reason: path);
    }
  });
}
