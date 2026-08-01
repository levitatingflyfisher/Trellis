import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/feeds/feed_detail_screen.dart';
import 'package:trellis/features/feeds/feeds_repository.dart';
import 'package:trellis/features/feeds/feeds_screen.dart';

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

  Future<Feed> seedFeed({String? nextPageUrl}) async {
    final id = await db.feedsDao
        .insertFeed(profileId: profileId, url: 'https://cast.test/feed');
    await db.feedsDao.updateRefreshState(id,
        title: 'The Night Sky Cast',
        etag: null,
        lastModified: null,
        breakerJson: '{}',
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
    expect(find.textContaining("older ones aren't published in it"),
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

    expect(find.text("No older episodes were published in the feed's "
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
}
