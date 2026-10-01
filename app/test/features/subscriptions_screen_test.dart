import 'dart:convert';

import 'package:comms_core/comms_core.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/feeds/feed_detail_screen.dart';
import 'package:trellis/features/feeds/feeds_repository.dart';
import 'package:trellis/features/feeds/feeds_screen.dart';
import 'package:trellis/features/reader/reader_screen.dart';

import '../support/scripted_fetcher.dart';

/// The Subscriptions page (ADR-0016 section 3): every source shelved by
/// where it came from, alphabetical within a shelf, with unplayed counts
/// and failure reasons a scan can catch.
void main() {
  late AppDatabase db;
  late int profileId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
  });
  tearDown(() => db.close());

  Future<int> feed(String title,
      {String origin = 'podcast', String breakerJson = '{}'}) async {
    final id = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://x.test/${title.hashCode}');
    await db.feedsDao.updateRefreshState(id,
        title: title,
        etag: null,
        lastModified: null,
        breakerJson: breakerJson);
    await db.feedsDao.setOrigin(id, origin);
    return id;
  }

  var guid = 0;
  Future<int> episode(int feedId, {bool audio = true}) async {
    final n = guid++;
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: audio ? 'episode' : 'article',
        title: 'Item $n',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100);
    await db.feedsDao.insertEpisode(
        workId: workId,
        feedId: feedId,
        guid: 'g$n',
        enclosureUrl: audio ? 'https://x.test/$n.mp3' : null,
        publishedAtMs: n);
    return workId;
  }

  Future<int> book(String title, {int segments = 0, int? at}) async {
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'book',
        title: title,
        persistence: 'work',
        firstSeenEpochDay: 100);
    await db.spineDao.insertSegments(id, [
      for (var i = 0; i < segments; i++) (idx: i, kind: 'prose', text: 'p$i'),
    ]);
    if (at != null) {
      await db.spineDao.savePosition(
          profileId: profileId,
          workId: id,
          segmentIdx: at,
          wordIdx: 0,
          lastModality: 'read');
    }
    return id;
  }

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
        home: FeedsScreen(
            db: db,
            repository: FeedsRepository(
                db: db, fetcher: ScriptedFetcher((u, h) => textResponse(''))),
            profile: (await db.profilesDao.all()).single)));
    await tester.pumpAndSettle();
  }

  double top(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

  testWidgets('sources sit on their own shelves, in shelf order, each '
      'alphabetical ignoring a leading "The"', (tester) async {
    await feed('Zebra Talk');
    await feed('The Night Sky Cast');
    await feed('Apple Hour');
    await feed('Field Notes', origin: 'blog');
    await book('Middlemarch');
    await pump(tester);

    expect(find.text('Subscriptions'), findsOneWidget);
    final podcasts = find.byKey(const Key('shelf-podcasts'));
    final blogs = find.byKey(const Key('shelf-blogs'));
    final books = find.byKey(const Key('shelf-books'));
    expect(find.descendant(of: podcasts, matching: find.textContaining('3')),
        findsOneWidget);
    expect(top(tester, podcasts), lessThan(top(tester, find.text('Apple Hour'))));
    expect(top(tester, find.text('Apple Hour')),
        lessThan(top(tester, find.text('The Night Sky Cast'))));
    expect(top(tester, find.text('The Night Sky Cast')),
        lessThan(top(tester, find.text('Zebra Talk'))));
    expect(top(tester, find.text('Zebra Talk')), lessThan(top(tester, blogs)));
    expect(top(tester, blogs), lessThan(top(tester, find.text('Field Notes'))));
    expect(top(tester, find.text('Field Notes')), lessThan(top(tester, books)));
    expect(top(tester, books), lessThan(top(tester, find.text('Middlemarch'))));
  });

  // Both list forms mount only what is on screen, so this can't see the
  // difference ADR-0017 made (tiles and their disk checks no longer built
  // for every row up front); it pins that the builder still reaches the
  // end of a 300-show list in order.
  testWidgets('a long list scrolls to its last show', (tester) async {
    for (var i = 0; i < 300; i++) {
      await feed('Show ${i.toString().padLeft(3, '0')}');
    }
    await pump(tester);
    expect(find.text('Show 000'), findsOneWidget);
    expect(find.text('Show 299'), findsNothing);
    await tester.scrollUntilVisible(find.text('Show 299'), 2000,
        scrollable: find.byType(Scrollable).last);
    expect(find.text('Show 299'), findsOneWidget);
  });

  testWidgets('an empty shelf is not shown', (tester) async {
    await feed('Night Sky');
    await pump(tester);
    expect(find.byKey(const Key('shelf-podcasts')), findsOneWidget);
    expect(find.byKey(const Key('shelf-blogs')), findsNothing);
    expect(find.byKey(const Key('shelf-books')), findsNothing);
    expect(find.text('Blogs and newsletters'), findsNothing);
  });

  testWidgets('a row counts what is left to play, and says nothing when '
      'caught up', (tester) async {
    final busy = await feed('Busy');
    final done = await feed('Done');
    await episode(busy);
    await episode(busy);
    final heard = await episode(busy);
    await db.feedsDao.markPlayed(heard, 1);
    final passed = await episode(busy);
    await db.spineDao.setPersistence(passed, 'decayed');
    await db.feedsDao.markPlayed(await episode(done), 1);
    await pump(tester);

    expect(find.text('2 unplayed'), findsOneWidget);
    expect(find.byKey(Key('unplayed-$done')), findsNothing);
    expect(find.textContaining('0 unplayed'), findsNothing);
  });

  testWidgets('a failing feed shows its reason in the error colour',
      (tester) async {
    await feed('Walled',
        breakerJson: jsonEncode({
          'consecutiveFailures': 2,
          'broken': false,
          'lastError': feedBotWallReason,
        }));
    await pump(tester);
    final reason = tester.widget<Text>(find.text(feedBotWallReason));
    final context = tester.element(find.text(feedBotWallReason));
    expect(reason.style?.color, Theme.of(context).colorScheme.error);
  });

  testWidgets('tapping a podcast opens its page', (tester) async {
    final id = await feed('Night Sky');
    await episode(id);
    await pump(tester);
    await tester.tap(find.text('Night Sky'));
    await tester.pumpAndSettle();
    expect(find.byType(FeedDetailScreen), findsOneWidget);
  });

  testWidgets('a book shows its progress and opens in the reader',
      (tester) async {
    await book('Middlemarch', segments: 4, at: 1);
    await book('Emma');
    await pump(tester);

    expect(find.text('25% read'), findsOneWidget);
    await tester.tap(find.text('Middlemarch'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(ReaderScreen), findsOneWidget);
  });

  testWidgets('with books but no feeds, the shelf shows and Follow stays in '
      'reach', (tester) async {
    await book('Middlemarch');
    await pump(tester);
    expect(find.text('No feeds yet.'), findsNothing);
    expect(find.byKey(const Key('shelf-books')), findsOneWidget);
    expect(find.byKey(const Key('follow')), findsOneWidget);
  });

  testWidgets('nothing at all shows the invitation to follow', (tester) async {
    await pump(tester);
    expect(find.text('No feeds yet.'), findsOneWidget);
    expect(find.text('Follow a feed'), findsOneWidget);
  });

  testWidgets('large text on a narrow phone does not overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final long = await feed('A very long podcast name that goes on and on '
        'well past the edge of a narrow phone',
        breakerJson: jsonEncode({
          'consecutiveFailures': 1,
          'broken': false,
          'lastError': feedBotWallReason,
        }));
    for (var i = 0; i < 12; i++) {
      await episode(long);
    }
    await feed('An equally long newsletter title that will need wrapping too',
        origin: 'blog');
    await book('The Life and Opinions of Tristram Shandy, Gentleman',
        segments: 10, at: 3);
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
            data: const MediaQueryData(
                size: Size(320, 800), textScaler: TextScaler.linear(2)),
            child: FeedsScreen(
                db: db,
                repository: FeedsRepository(
                    db: db,
                    fetcher: ScriptedFetcher((u, h) => textResponse(''))),
                profile: (await db.profilesDao.all()).single))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('12 unplayed'), findsOneWidget);
  });

  test('shelf order ignores case and a leading "The "', () {
    expect(shelfKey('The Night Sky'), 'night sky');
    expect(shelfKey('Theatre Talk'), 'theatre talk');
    expect(shelfKey('  apple'), 'apple');
  });
}
