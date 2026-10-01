import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/feeds/auto_download.dart';
import 'package:trellis/features/feeds/background/feed_check_runner.dart';
import 'package:trellis/features/feeds/background/feed_check_settings.dart';
import 'package:trellis/features/feeds/feeds_repository.dart';

import '../support/scripted_fetcher.dart';
import 'feed_check_settings_test.dart' show FakeScheduler;

String rss(List<String> guids) => '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel><title>A Cast</title>
${[
      for (final g in guids)
        '<item><title>$g</title><guid>$g</guid>'
            '<pubDate>Wed, 05 Aug 2026 12:00:00 GMT</pubDate>'
            '<enclosure url="https://cast.test/$g.mp3" type="audio/mpeg"/>'
            '</item>'
    ].join()}
</channel></rss>''';

void main() {
  late AppDatabase db;
  late FakeScheduler scheduler;
  final listings = <String, List<String>>{};
  late ScriptedFetcher fetcher;
  final started = <int>[];

  FeedCheckRunner runner() {
    final repo = FeedsRepository(db: db, fetcher: fetcher);
    final r = FeedCheckRunner(
        db: db,
        repository: repo,
        scheduler: scheduler,
        onDisk: (_, _) => false,
        startDownload: (AutoDownloadPick p) async => started.add(p.workId));
    repo.afterCheck = r.requestAutoDownloadIfPending;
    return r;
  }

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    scheduler = FakeScheduler();
    listings.clear();
    started.clear();
    fetcher = ScriptedFetcher(
        (url, _) => textResponse(rss(listings[url.toString()] ?? const [])));
  });
  tearDown(() => db.close());

  test('a check refreshes every reader’s feeds and records each', () async {
    final ada = await db.profilesDao.create('Ada');
    final bo = await db.profilesDao.create('Bo');
    await db.feedsDao.insertFeed(profileId: ada, url: 'https://a.test/feed');
    await db.feedsDao.insertFeed(profileId: bo, url: 'https://b.test/feed');
    listings['https://a.test/feed'] = ['a1'];
    listings['https://b.test/feed'] = ['b1', 'b2'];

    await runner().run(FeedCheckTask.check);

    expect(fetcher.calls.map((c) => c.url.host).toSet(), {'a.test', 'b.test'});
    expect(await readLastChecked(db, ada), isNotNull);
    expect(await readLastChecked(db, bo), isNotNull);
    expect(scheduler.calls, isEmpty, reason: 'no show is opted in');
    expect(started, isEmpty);
  });

  test('a feed in backoff is not fetched by a check', () async {
    final ada = await db.profilesDao.create('Ada');
    final id = await db.feedsDao
        .insertFeed(profileId: ada, url: 'https://down.test/feed');
    final farFuture = DateTime.now().millisecondsSinceEpoch + 3600 * 1000;
    final feed = (await db.feedsDao.feedById(id))!;
    await db.feedsDao.updateRefreshState(id,
        title: feed.title,
        etag: null,
        lastModified: null,
        breakerJson: '{"consecutiveFailures":1,"nextAttemptMs":$farFuture}');

    await runner().run(FeedCheckTask.check);
    expect(fetcher.calls, isEmpty);
  });

  test('new episodes on an opted-in show ask for a pass; the check itself '
      'downloads nothing', () async {
    final ada = await db.profilesDao.create('Ada');
    final id =
        await db.feedsDao.insertFeed(profileId: ada, url: 'https://a.test/feed');
    listings['https://a.test/feed'] = ['old'];
    final r = runner();
    await r.run(FeedCheckTask.check);
    await setFeedAutoDownload(db, id, true);
    listings['https://a.test/feed'] = ['old', 'new'];

    await r.run(FeedCheckTask.check);
    expect(scheduler.calls, ['auto-download']);
    expect(started, isEmpty);

    await r.run(FeedCheckTask.autoDownload);
    expect(started, hasLength(1));
  });

  test('asked to stop, a check leaves the remaining readers for next time',
      () async {
    final ada = await db.profilesDao.create('Ada');
    await db.feedsDao.insertFeed(profileId: ada, url: 'https://a.test/feed');
    final stop = StopSignal()..request();
    await runner().run(FeedCheckTask.check, stop: stop);
    expect(fetcher.calls, isEmpty);
  });

  test('a stop during a pass pauses the download it started, and only that',
      () async {
    final ada = await db.profilesDao.create('Ada');
    final id =
        await db.feedsDao.insertFeed(profileId: ada, url: 'https://a.test/feed');
    listings['https://a.test/feed'] = ['old'];
    await runner().run(FeedCheckTask.check);
    await setFeedAutoDownload(db, id, true);
    listings['https://a.test/feed'] = ['old', 'n1', 'n2'];
    await runner().run(FeedCheckTask.check);

    final stop = StopSignal();
    final cancelled = <int>[];
    final inFlight = Completer<void>();
    final pass = FeedCheckRunner(
        db: db,
        repository: FeedsRepository(db: db, fetcher: fetcher),
        scheduler: scheduler,
        onDisk: (_, _) => false,
        cancelDownload: cancelled.add,
        startDownload: (p) async {
          started.add(p.workId);
          stop.request();
          await inFlight.future;
          return null;
        });
    final running = pass.run(FeedCheckTask.autoDownload, stop: stop);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(cancelled, [started.single]);
    inFlight.complete();
    await running;
    expect(started, hasLength(1), reason: 'nothing starts after the stop');
  });
}
