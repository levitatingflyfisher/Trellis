import 'dart:convert';

import 'package:comms_core/comms_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/feeds/feed_detail_screen.dart';
import 'package:trellis/features/feeds/feeds_repository.dart';
import 'package:trellis/features/feeds/feeds_screen.dart';

import 'package:trellis/features/feeds/feed_settings_screen.dart';
import 'package:trellis/features/player/karaoke_screen.dart';
import 'package:trellis/features/player/player_controller.dart';

import 'package:trellis/features/reader/reader_doors.dart';

import '../support/fake_player.dart';
import '../support/fake_tts.dart';
import '../support/scripted_fetcher.dart';

/// The feed detail screen: a single feed's own episodes, newest first, plus
/// the RFC 5005 "Fetch older episodes" action when the last refresh found
/// an archive link — or, for the overwhelmingly common case where it
/// didn't, one calm line saying so instead.
void main() {
  late AppDatabase db;
  late int profileId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
  });
  tearDown(() => db.close());

  Future<Feed> seedFeed({String? nextPageUrl, String breakerJson = '{}'}) async {
    final id = await db.feedsDao
        .insertFeed(profileId: profileId, url: 'https://cast.test/feed');
    await db.feedsDao.updateRefreshState(id,
        title: 'The Night Sky Cast',
        etag: null,
        lastModified: null,
        breakerJson: breakerJson,
        nextPageUrl: nextPageUrl,
        updateNextPageUrl: true);
    await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Aurora season',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/aurora.mp3');
    final workId = (await db.spineDao.worksOf(profileId)).single.id;
    await db.feedsDao.insertEpisode(
        workId: workId,
        feedId: id,
        guid: 'https://cast.test/aurora',
        enclosureUrl: 'https://cast.test/aurora.mp3',
        publishedAtMs: 1000);
    return (await db.feedsDao.feedsOf(profileId)).single;
  }

  Future<void> pump(WidgetTester tester, Feed feed, ScriptedFetcher fetcher) =>
      tester.pumpWidget(MaterialApp(
          home: FeedDetailScreen(
              db: db,
              repository: FeedsRepository(db: db, fetcher: fetcher),
              feed: feed)));

  // A podcast is readable without being played: the show page offers
  // Read on a transcribed episode, as Latest does.
  testWidgets('Read on a transcribed episode opens its transcript',
      (tester) async {
    final feed = await seedFeed();
    final work = (await db.spineDao.worksOf(profileId)).single;
    await db.spineDao.insertSegments(
        work.id, const [(idx: 0, kind: 'prose', text: 'Lights overhead.')]);
    await db.spineDao.insertAlignments(
        work.id, const [(segmentIdx: 0, tStartMs: 0, tEndMs: 5000)]);
    final fake = FakeEpisodePlayer();
    final controller = PlayerController(
        db: db, profileId: profileId, createPlayer: () => fake);
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
        home: FeedDetailScreen(
            db: db,
            repository: FeedsRepository(
                db: db, fetcher: ScriptedFetcher((u, h) => textResponse(''))),
            feed: feed,
            playerController: controller)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('read-${work.id}')));
    await tester.pumpAndSettle();
    expect(find.byType(KaraokeScreen), findsOneWidget);
    expect(find.text('Lights overhead.'), findsOneWidget);
    expect(fake.loadedUrl, isNull);
  });

  testWidgets('the transcript opened here gets the same reader kit as '
      "Latest's", (tester) async {
    final feed = await seedFeed();
    final work = (await db.spineDao.worksOf(profileId)).single;
    await db.spineDao.insertSegments(
        work.id, const [(idx: 0, kind: 'prose', text: 'Lights overhead.')]);
    await db.spineDao.insertAlignments(
        work.id, const [(segmentIdx: 0, tStartMs: 0, tEndMs: 5000)]);
    final controller = PlayerController(
        db: db, profileId: profileId, createPlayer: FakeEpisodePlayer.new);
    addTearDown(controller.dispose);
    final tts = FakeTtsSpeaker();
    await tester.pumpWidget(MaterialApp(
        home: FeedDetailScreen(
            db: db,
            repository: FeedsRepository(
                db: db, fetcher: ScriptedFetcher((u, h) => textResponse(''))),
            feed: feed,
            playerController: controller,
            readerDoors: ReaderDoors(player: controller, tts: tts))));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('read-${work.id}')));
    await tester.pumpAndSettle();
    expect(tester.widget<KaraokeScreen>(find.byType(KaraokeScreen)).tts,
        same(tts));
  });

  testWidgets('a feed with a known archive link shows the fetch-older action',
      (tester) async {
    final feed = await seedFeed(nextPageUrl: 'https://cast.test/feed?page=2');
    await pump(tester, feed, ScriptedFetcher((u, h) => textResponse('')));
    await tester.pumpAndSettle();

    expect(find.text('Aurora season'), findsOneWidget);
    expect(find.byKey(const Key('fetch-older-episodes')), findsOneWidget);
    expect(find.byKey(const Key('no-archive-note')), findsNothing);
  });

  testWidgets(
      'a feed with no archive link shows the calm note instead of an action',
      (tester) async {
    final feed = await seedFeed();
    await pump(tester, feed, ScriptedFetcher((u, h) => textResponse('')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('no-archive-note')), findsOneWidget);
    expect(find.textContaining('Older ones aren’t published in it'),
        findsOneWidget);
    expect(find.byKey(const Key('fetch-older-episodes')), findsNothing);
  });

  testWidgets(
      'tapping fetch-older walks the archive and reports what it found',
      (tester) async {
    final feed = await seedFeed(nextPageUrl: 'https://cast.test/feed?page=2');
    final fetcher = ScriptedFetcher((url, headers) {
      expect(url.toString(), 'https://cast.test/feed?page=2');
      return textResponse('''
<rss><channel><title>t</title>
  <item><title>Comet watch</title><link>https://cast.test/comet</link></item>
</channel></rss>
''');
    });
    await pump(tester, feed, fetcher);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('fetch-older-episodes')));
    await tester.pumpAndSettle();

    expect(find.text('Found 1 older episode.'), findsOneWidget);
    expect(find.text('Comet watch'), findsOneWidget);
  });

  testWidgets(
      'an archive walk that finds nothing new reports so without adding '
      'episodes', (tester) async {
    final feed = await seedFeed(nextPageUrl: 'https://cast.test/feed?page=2');
    final fetcher = ScriptedFetcher((url, headers) =>
        textResponse('<rss><channel><title>t</title></channel></rss>'));
    await pump(tester, feed, fetcher);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('fetch-older-episodes')));
    await tester.pumpAndSettle();

    expect(find.text("No older episodes were published in the feed’s "
        'archive.'), findsOneWidget);
    expect(find.text('Aurora season'), findsOneWidget);
  });

  testWidgets('tapping a feed row from the feeds list opens its detail',
      (tester) async {
    final feed = await seedFeed(nextPageUrl: 'https://cast.test/feed?page=2');
    final repository = FeedsRepository(
        db: db, fetcher: ScriptedFetcher((u, h) => textResponse('')));
    await tester.pumpWidget(MaterialApp(
        home: FeedsScreen(
            db: db,
            repository: repository,
            profile: (await db.profilesDao.all()).single)));
    await tester.pumpAndSettle();

    await tester.tap(find.text(feed.title));
    await tester.pumpAndSettle();

    expect(find.byType(FeedDetailScreen), findsOneWidget);
    expect(find.text('Aurora season'), findsOneWidget);
  });

  group('a failing feed says why', () {
    // Why: a feed behind a robot check or gone from its host used to fail
    // without a word; the listener only noticed episodes had stopped.
    final walled = jsonEncode({
      'consecutiveFailures': 2,
      'broken': false,
      'lastError': feedBotWallReason,
    });
    const rss = '<rss><channel><title>The Night Sky Cast</title>'
        '</channel></rss>';

    testWidgets('the detail screen names the reason; a healthy feed does not',
        (tester) async {
      final feed = await seedFeed(breakerJson: walled);
      await pump(tester, feed, ScriptedFetcher((u, h) => textResponse(rss)));
      await tester.pumpAndSettle();
      expect(find.text(feedBotWallReason), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await db.feedsDao.updateRefreshState(feed.id,
          title: feed.title,
          etag: null,
          lastModified: null,
          breakerJson: '{}');
      final healthy = (await db.feedsDao.feedById(feed.id))!;
      await pump(tester, healthy, ScriptedFetcher((u, h) => textResponse(rss)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('feed-problem')), findsNothing);
    });

    testWidgets('a feed Trellis stopped checking says so', (tester) async {
      final feed = await seedFeed(
          breakerJson: jsonEncode({
        'consecutiveFailures': 1,
        'broken': true,
        'lastError': feedGoneReason,
      }));
      await pump(tester, feed, ScriptedFetcher((u, h) => textResponse(rss)));
      await tester.pumpAndSettle();
      expect(find.text(feedGoneReason), findsOneWidget);
      expect(find.textContaining('only once a week'), findsOneWidget);
    });

    testWidgets('Try again refetches, and a good answer clears the reason',
        (tester) async {
      final feed = await seedFeed(breakerJson: walled);
      final fetcher = ScriptedFetcher((u, h) => textResponse(rss));
      await pump(tester, feed, fetcher);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(fetcher.calls, hasLength(1));
      expect(find.byKey(const Key('feed-problem')), findsNothing);
    });

    testWidgets('the feeds list shows the reason in place of the address',
        (tester) async {
      final feed = await seedFeed(breakerJson: walled);
      await tester.pumpWidget(MaterialApp(
          home: FeedsScreen(
              db: db,
              repository: FeedsRepository(
                  db: db, fetcher: ScriptedFetcher((u, h) => textResponse(''))),
              profile: (await db.profilesDao.all()).single)));
      await tester.pumpAndSettle();

      expect(find.text(feedBotWallReason), findsOneWidget);
      expect(find.text(feed.url), findsNothing);
    });
  });

  group('the podcast page (ADR-0016)', () {
    late FakeEpisodePlayer player;
    late PlayerController controller;
    late Feed feed;
    late Map<String, int> ids;

    // Three episodes, published A then B then C; B is already played.
    setUp(() async {
      player = FakeEpisodePlayer();
      controller = PlayerController(
          db: db, profileId: profileId, createPlayer: () => player);
      feed = await seedFeed();
      ids = {'Aurora season': (await db.spineDao.worksOf(profileId)).single.id};
      for (final (title, at) in [('Bright comet', 2000), ('Clear night', 3000)]) {
        final id = await db.spineDao.insertWork(
            profileId: profileId,
            kind: 'episode',
            title: title,
            persistence: 'ephemeron',
            firstSeenEpochDay: 100,
            sourceUrl: 'https://cast.test/$at.mp3');
        await db.feedsDao.insertEpisode(
            workId: id,
            feedId: feed.id,
            guid: 'g$at',
            enclosureUrl: 'https://cast.test/$at.mp3',
            durationMs: 45 * 60000,
            publishedAtMs: at);
        ids[title] = id;
      }
      await db.feedsDao.markPlayed(ids['Bright comet']!, 1);
    });
    tearDown(() => controller.dispose());

    Future<void> pumpPage(WidgetTester tester, {Feed? f}) async {
      await tester.pumpWidget(MaterialApp(
          home: FeedDetailScreen(
              db: db,
              repository: FeedsRepository(
                  db: db, fetcher: ScriptedFetcher((u, h) => textResponse(''))),
              feed: f ?? feed,
              playerController: controller)));
      await tester.pumpAndSettle();
    }

    List<String> titlesInOrder(WidgetTester tester) {
      final titles = ids.keys.toList();
      final found = [
        for (final t in titles)
          (t, tester.getTopLeft(find.text(t)).dy),
      ]..sort((a, b) => a.$2.compareTo(b.$2));
      return [for (final f in found) f.$1];
    }

    Future<void> openMenu(WidgetTester tester, String title) async {
      await tester.tap(find.byKey(Key('menu-${ids[title]}')));
      await tester.pumpAndSettle();
    }

    testWidgets('rows play from here, and say their length', (tester) async {
      await pumpPage(tester);
      expect(find.textContaining(' · 45\u00A0min'), findsNWidgets(2));

      await tester.tap(find.byKey(Key('play-${ids['Clear night']}')));
      await tester.pumpAndSettle();
      expect(player.loadedUrl, 'https://cast.test/3000.mp3');
    });

    testWidgets('a played episode fades on this page too', (tester) async {
      await pumpPage(tester);
      expect(find.byKey(Key('played-${ids['Bright comet']}')), findsOneWidget);
      expect(find.byKey(Key('played-${ids['Clear night']}')), findsNothing);
    });

    testWidgets('newest first by default; oldest first is remembered for '
        'this show', (tester) async {
      await pumpPage(tester);
      expect(titlesInOrder(tester),
          ['Clear night', 'Bright comet', 'Aurora season']);

      await tester.tap(find.byKey(const Key('sort-oldest')));
      await tester.pumpAndSettle();
      expect(titlesInOrder(tester),
          ['Aurora season', 'Bright comet', 'Clear night']);
      expect((await db.feedsDao.feedById(feed.id))!.sortOldestFirst, isTrue);

      await tester.pumpWidget(const SizedBox());
      await pumpPage(tester, f: (await db.feedsDao.feedById(feed.id))!);
      expect(titlesInOrder(tester),
          ['Aurora season', 'Bright comet', 'Clear night']);
    });

    testWidgets('Play from here queues this and the unplayed ones after it '
        'in the order shown, then plays', (tester) async {
      await db.feedsDao.setSortOldestFirst(feed.id, true);
      await pumpPage(tester, f: (await db.feedsDao.feedById(feed.id))!);

      await openMenu(tester, 'Aurora season');
      await tester.tap(find.text('Play from here'));
      await tester.pumpAndSettle();

      final queue = await db.queueDao.queueOf(profileId);
      expect(queue.map((r) => r.workId),
          [ids['Aurora season'], ids['Clear night']],
          reason: 'Bright comet is already played');
      expect(player.loadedUrl, 'https://cast.test/aurora.mp3');
      expect(find.byKey(Key('queued-${ids['Clear night']}')), findsOneWidget);
    });

    testWidgets('Add unplayed to Queue appends them and says how many',
        (tester) async {
      await pumpPage(tester);
      await tester.tap(find.byKey(const Key('add-unplayed')));
      await tester.pumpAndSettle();

      final queue = await db.queueDao.queueOf(profileId);
      expect(queue.map((r) => r.workId),
          [ids['Clear night'], ids['Aurora season']]);
      expect(find.text('Added 2 episodes to the Queue.'), findsOneWidget);
      expect(player.loadedUrl, isNull, reason: 'queueing never starts play');
    });

    testWidgets('Mark played and Mark unplayed from the row menu',
        (tester) async {
      await pumpPage(tester);
      await openMenu(tester, 'Clear night');
      await tester.tap(find.text('Mark played'));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('played-${ids['Clear night']}')), findsOneWidget);

      await openMenu(tester, 'Clear night');
      await tester.tap(find.text('Mark unplayed'));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('played-${ids['Clear night']}')), findsNothing);
    });

    testWidgets('Podcast settings opens the show\'s settings',
        (tester) async {
      await pumpPage(tester);
      await tester.tap(find.byKey(const Key('podcast-settings')));
      await tester.pumpAndSettle();
      expect(find.byType(FeedSettingsScreen), findsOneWidget);
    });

    testWidgets('the page survives 320dp at 2x text', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      await pumpPage(tester);
      expect(tester.takeException(), isNull);
    });
  });
}
