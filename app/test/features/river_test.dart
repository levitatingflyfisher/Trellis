import 'package:flutter/material.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/scripted_fetcher.dart';

const _rssOne = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel>
  <title>The Night Sky Cast</title>
  <item>
    <title>Aurora season</title>
    <link>https://cast.test/aurora</link>
    <pubDate>Wed, 05 Aug 2026 12:00:00 GMT</pubDate>
    <description>Lights in the north.</description>
    <enclosure url="https://cast.test/aurora.mp3" type="audio/mpeg"/>
  </item>
</channel></rss>
''';

const _rssTwo = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel>
  <title>The Night Sky Cast</title>
  <item>
    <title>Perseid peak tonight</title>
    <link>https://cast.test/perseids</link>
    <pubDate>Thu, 06 Aug 2026 12:00:00 GMT</pubDate>
    <description>Look northeast.</description>
  </item>
  <item>
    <title>Aurora season</title>
    <link>https://cast.test/aurora</link>
    <pubDate>Wed, 05 Aug 2026 12:00:00 GMT</pubDate>
    <description>Lights in the north.</description>
    <enclosure url="https://cast.test/aurora.mp3" type="audio/mpeg"/>
  </item>
</channel></rss>
''';

/// The River (ADR-0003 law 1): ONE reverse-chronological list across every
/// feed — no ranking code path exists to test, only ordering. Unread dots,
/// text/audio filters that never reorder, pull-to-refresh under the
/// breaker, and playback into the shell's persistent mini bar.
void main() {
  late AppDatabase db;
  late FakeEpisodePlayer player;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    player = FakeEpisodePlayer();
  });
  tearDown(() => db.close());

  Future<int> seedProfile() => db.profilesDao.create('Ada');

  Future<void> pumpApp(WidgetTester tester, ScriptedFetcher fetcher) async {
    await tester.pumpWidget(
        TrellisApp(db: db, fetcher: fetcher, createPlayer: () => player));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle();
  }

  Future<void> openRiver(WidgetTester tester) async {
    await tester.tap(find.text('River'));
    await tester.pumpAndSettle();
  }

  Future<int> seedRiverItem(
      {required int profileId,
      required int feedId,
      required String title,
      required int publishedAtMs,
      String? enclosureUrl,
      String? guid,
      String desc = ''}) async {
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: enclosureUrl != null ? 'episode' : 'article',
        title: title,
        persistence: 'ephemeron',
        firstSeenEpochDay:
            DateTime.now().toUtc().millisecondsSinceEpoch ~/
                Duration.millisecondsPerDay,
        sourceUrl: enclosureUrl);
    if (desc.isNotEmpty) {
      await db.spineDao
          .insertSegments(workId, [(idx: 0, kind: 'prose', text: desc)]);
    }
    await db.feedsDao.insertEpisode(
        workId: workId,
        feedId: feedId,
        guid: guid ?? 'guid-$title',
        enclosureUrl: enclosureUrl,
        publishedAtMs: publishedAtMs);
    return workId;
  }

  testWidgets('an empty river is an invitation, and its button reaches the '
      'subscribe screen', (tester) async {
    await seedProfile();
    await pumpApp(tester, ScriptedFetcher((u, h) => textResponse(_rssOne)));
    await openRiver(tester);

    expect(find.text('The river is quiet.'), findsOneWidget);
    await tester.tap(find.text('Follow a feed'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('subscribe-url')), findsOneWidget);
  });

  testWidgets('items render newest-first across feeds — the DAO order, '
      'untouched', (tester) async {
    final profileId = await seedProfile();
    final feedA =
        await db.feedsDao.insertFeed(profileId: profileId, url: 'https://a/f');
    final feedB =
        await db.feedsDao.insertFeed(profileId: profileId, url: 'https://b/f');
    await seedRiverItem(
        profileId: profileId, feedId: feedA, title: 'Middle item',
        publishedAtMs: 2000);
    await seedRiverItem(
        profileId: profileId, feedId: feedB, title: 'Newest item',
        publishedAtMs: 3000, enclosureUrl: 'https://b/1.mp3');
    await seedRiverItem(
        profileId: profileId, feedId: feedA, title: 'Oldest item',
        publishedAtMs: 1000);

    await pumpApp(tester, ScriptedFetcher((u, h) => textResponse(_rssOne)));
    await openRiver(tester);

    final newestY = tester.getTopLeft(find.text('Newest item')).dy;
    final middleY = tester.getTopLeft(find.text('Middle item')).dy;
    final oldestY = tester.getTopLeft(find.text('Oldest item')).dy;
    expect(newestY, lessThan(middleY));
    expect(middleY, lessThan(oldestY));
  });

  testWidgets('the text/audio chips filter without reordering', (tester) async {
    final profileId = await seedProfile();
    final feedId =
        await db.feedsDao.insertFeed(profileId: profileId, url: 'https://a/f');
    await seedRiverItem(
        profileId: profileId, feedId: feedId, title: 'A text item',
        publishedAtMs: 2000);
    await seedRiverItem(
        profileId: profileId, feedId: feedId, title: 'An audio item',
        publishedAtMs: 1000, enclosureUrl: 'https://a/1.mp3');

    await pumpApp(tester, ScriptedFetcher((u, h) => textResponse(_rssOne)));
    await openRiver(tester);

    expect(find.text('A text item'), findsOneWidget);
    expect(find.text('An audio item'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chip-audio')));
    await tester.pumpAndSettle();
    expect(find.text('A text item'), findsNothing);
    expect(find.text('An audio item'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chip-text')));
    await tester.pumpAndSettle();
    expect(find.text('A text item'), findsOneWidget);
    expect(find.text('An audio item'), findsNothing);

    await tester.tap(find.byKey(const Key('chip-all')));
    await tester.pumpAndSettle();
    expect(find.text('A text item'), findsOneWidget);
    expect(find.text('An audio item'), findsOneWidget);
  });

  testWidgets('opening a text item reads its shownotes and clears the '
      'unread dot', (tester) async {
    final profileId = await seedProfile();
    final feedId =
        await db.feedsDao.insertFeed(profileId: profileId, url: 'https://a/f');
    final workId = await seedRiverItem(
        profileId: profileId,
        feedId: feedId,
        title: 'A text item',
        publishedAtMs: 1000,
        desc: 'The shownotes body.');

    await pumpApp(tester, ScriptedFetcher((u, h) => textResponse(_rssOne)));
    await openRiver(tester);

    expect(find.byKey(Key('unread-dot-$workId')), findsOneWidget);
    await tester.tap(find.text('A text item'));
    await tester.pumpAndSettle();

    // The reader opened on the spine work (RSVP shows the first word).
    expect(find.byKey(const Key('reader-tapzone')), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byKey(Key('unread-dot-$workId')), findsNothing,
        reason: 'opening marked it read');
  });

  testWidgets('pull-to-refresh runs a conditional GET, honours the breaker, '
      'and lands new items', (tester) async {
    final profileId = await seedProfile();
    // A live feed with stored validators…
    final liveId = await db.feedsDao
        .insertFeed(profileId: profileId, url: 'https://cast.test/feed');
    await db.feedsDao.updateRefreshState(liveId,
        title: 'The Night Sky Cast',
        etag: '"v1"',
        lastModified: null,
        breakerJson: '{}');
    // …whose aurora episode is already known (guid = the item link, the
    // same identity ingest derives).
    await seedRiverItem(
        profileId: profileId,
        feedId: liveId,
        title: 'Aurora season',
        publishedAtMs: 1000,
        enclosureUrl: 'https://cast.test/aurora.mp3',
        guid: 'https://cast.test/aurora');
    // And a broken feed the breaker must skip.
    await db.feedsDao.updateRefreshState(
        await db.feedsDao
            .insertFeed(profileId: profileId, url: 'https://dead.test/feed'),
        title: 'Dead',
        etag: null,
        lastModified: null,
        breakerJson: '{"broken":true}');

    final fetcher = ScriptedFetcher((u, h) => textResponse(_rssTwo));
    await pumpApp(tester, fetcher);
    await openRiver(tester);

    await tester.fling(
        find.byType(ListView).last, const Offset(0, 300), 1000);
    await tester.pumpAndSettle();

    // The new item arrived; the known one was deduped, not duplicated.
    expect(find.text('Perseid peak tonight'), findsOneWidget);
    expect(find.text('Aurora season'), findsOneWidget);

    // Exactly one fetch — the live feed, conditionally; never the broken one.
    final call = fetcher.calls.single;
    expect(call.url.host, 'cast.test');
    expect(call.headers?['If-None-Match'], '"v1"');
  });

  testWidgets('the play button starts the episode and the mini bar '
      'persists across tabs', (tester) async {
    final profileId = await seedProfile();
    final feedId =
        await db.feedsDao.insertFeed(profileId: profileId, url: 'https://a/f');
    final workId = await seedRiverItem(
        profileId: profileId,
        feedId: feedId,
        title: 'An audio item',
        publishedAtMs: 1000,
        enclosureUrl: 'https://a/1.mp3');

    await pumpApp(tester, ScriptedFetcher((u, h) => textResponse(_rssOne)));
    await openRiver(tester);

    await tester.tap(find.byKey(Key('play-$workId')));
    await tester.pumpAndSettle();

    expect(player.playing, isTrue);
    expect(player.loadedUrl, 'https://a/1.mp3');
    expect(find.byKey(const Key('mini-player')), findsOneWidget);

    // The bar lives in the shell: still there on the Library tab.
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mini-player')), findsOneWidget);
  });
}
