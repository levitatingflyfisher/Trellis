import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/feeds/feeds_screen.dart';
import 'package:trellis/features/reader/reader_screen.dart';
import 'package:trellis/features/works/work_page.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/pick_reader.dart';
import '../support/scripted_fetcher.dart';
import '../support/tabs.dart';

/// 1.5.8 (user: "like AntennaPod, the bottom nav bar almost never goes
/// away"): pages opened from a tab open inside it, under the same bars.
/// Only the reader takes the whole screen.
void main() {
  late AppDatabase db;
  late FakeEpisodePlayer player;
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    player = FakeEpisodePlayer();
  });
  tearDown(() => db.close());

  Future<int> seedProfile() => db.profilesDao.create('Ada');

  Future<int> seedEpisode(int profileId, String title) async {
    final feedId = await db.feedsDao
        .insertFeed(profileId: profileId, url: 'https://cast.test/feed');
    final workId = await db.spineDao.insertWork(
      profileId: profileId,
      kind: 'episode',
      title: title,
      persistence: 'ephemeron',
      firstSeenEpochDay: DateTime.now().toUtc().millisecondsSinceEpoch ~/
          Duration.millisecondsPerDay,
      sourceUrl: 'https://cast.test/1.mp3',
    );
    await db.spineDao
        .insertSegments(workId, [(idx: 0, kind: 'prose', text: 'Show notes.')]);
    await db.feedsDao.insertEpisode(
      workId: workId,
      feedId: feedId,
      guid: 'guid-$title',
      enclosureUrl: 'https://cast.test/1.mp3',
      publishedAtMs: 1000,
    );
    return workId;
  }

  Future<int> seedText(int profileId, String title) async {
    final workId = await db.spineDao.insertWork(
      profileId: profileId,
      kind: 'text',
      title: title,
      persistence: 'kept',
      firstSeenEpochDay: 1,
    );
    await db.spineDao
        .insertSegments(workId, [(idx: 0, kind: 'prose', text: 'Hello.')]);
    return workId;
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(TrellisApp(
        db: db,
        fetcher: ScriptedFetcher((u, h) => textResponse('')),
        createPlayer: () => player));
    await tester.pumpAndSettle();
    await pickReader(tester, 'Ada');
  }

  Finder appBarTitle(String title) => find.descendant(
      of: find.byType(AppBar), matching: find.text(title));

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  testWidgets('Subscriptions opens inside Latest, under the bottom bar; '
      'back pops within the tab', (tester) async {
    await seedProfile();
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('manage-feeds')));
    await tester.pumpAndSettle();
    expect(find.byType(FeedsScreen), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget,
        reason: 'a page pushed from a tab keeps the bottom bar');

    await back(tester);
    expect(find.byType(FeedsScreen), findsNothing);
    expect(appBarTitle('Latest'), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('each tab keeps its own pages; back acts on the tab in view, '
      'and tapping the current tab returns to its root', (tester) async {
    await seedProfile();
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('manage-feeds')));
    await tester.pumpAndSettle();
    expect(find.byType(FeedsScreen), findsOneWidget);

    // The Library is at its root: back there must not pop Latest's page
    // out of sight.
    await toTab(tester, 'Library');
    expect(appBarTitle('Library'), findsOneWidget);
    await back(tester);
    await toTab(tester, 'Latest');
    expect(find.byType(FeedsScreen), findsOneWidget,
        reason: 'Latest kept its page across the trip');

    await toTab(tester, 'Latest');
    expect(find.byType(FeedsScreen), findsNothing);
    expect(appBarTitle('Latest'), findsOneWidget);
  });

  testWidgets('a Latest card opens its episode page inside the tab; Play '
      'stays its own one-tap button', (tester) async {
    final profileId = await seedProfile();
    final workId = await seedEpisode(profileId, 'Aurora season');
    await pumpApp(tester);

    expect(find.byKey(Key('play-$workId')), findsOneWidget,
        reason: 'Play is visible on the card');
    await tester.tap(find.text('Aurora season'));
    await tester.pumpAndSettle();
    expect(find.byType(WorkPage), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);

    await back(tester);
    expect(find.byType(WorkPage), findsNothing);

    // Play is one tap: it plays, and opens no page.
    await tester.tap(find.byKey(Key('play-$workId')));
    await tester.pumpAndSettle();
    expect(player.loadedUrl, 'https://cast.test/1.mp3');
    expect(player.playing, isTrue);
    expect(find.byType(WorkPage), findsNothing);
  });

  testWidgets('a Queue card opens its episode page inside the tab',
      (tester) async {
    final profileId = await seedProfile();
    final workId = await seedEpisode(profileId, 'Perseid peak');
    await db.queueDao.playLast(profileId: profileId, workId: workId, nowMs: 1);
    await pumpApp(tester);
    await toTab(tester, 'Queue');

    expect(find.byKey(Key('play-$workId')), findsOneWidget);
    await tester.tap(find.text('Perseid peak'));
    await tester.pumpAndSettle();
    expect(find.byType(WorkPage), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('the reader takes the whole screen', (tester) async {
    final profileId = await seedProfile();
    await seedText(profileId, 'A quiet text');
    await pumpApp(tester);
    await toTab(tester, 'Library');

    await tester.tap(find.text('A quiet text'));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    await tester.tap(find.byKey(const Key('mode-read')));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderScreen), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);

    await back(tester);
    expect(find.byType(WorkPage), findsOneWidget,
        reason: 'closing the reader comes back to the page under it');
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('+ Add on the Library offers every way in, and Subscribe '
      'opens inside the tab', (tester) async {
    final profileId = await seedProfile();
    await seedText(profileId, 'A quiet text');
    await pumpApp(tester);
    await toTab(tester, 'Library');

    await tester.tap(find.byKey(const Key('library-add')));
    await tester.pumpAndSettle();
    for (final entry in [
      'Subscribe to a feed',
      'Import an EPUB',
      'Paste text',
      'Open a link',
    ]) {
      expect(find.text(entry), findsOneWidget, reason: entry);
    }
    await tester.tap(find.text('Subscribe to a feed'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('subscribe-url')), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('an empty Library offers Subscribe too', (tester) async {
    await seedProfile();
    await pumpApp(tester);
    await toTab(tester, 'Library');
    expect(find.text('Subscribe to a feed'), findsOneWidget);
  });

  testWidgets('Subscriptions is one tap from the Library too, inside the '
      'tab', (tester) async {
    await seedProfile();
    await pumpApp(tester);
    await toTab(tester, 'Library');

    await tester.tap(find.byKey(const Key('library-subscriptions')));
    await tester.pumpAndSettle();
    expect(find.byType(FeedsScreen), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    await back(tester);
    expect(appBarTitle('Library'), findsOneWidget);
  });

  testWidgets('one rule for ⋮: app-level items live in the Library\'s, and '
      'every tab\'s ends in Theme', (tester) async {
    await seedProfile();
    await pumpApp(tester);

    Future<List<String>> menu(Key key) async {
      await tester.tap(find.byKey(key));
      await tester.pumpAndSettle();
      final words = [
        for (final e in find
            .descendant(
                of: find.byType(PopupMenuItem<String>, skipOffstage: false),
                matching: find.byType(Text))
            .evaluate())
          (e.widget as Text).data ?? '',
        for (final e in find
            .descendant(
                of: find.byType(CheckedPopupMenuItem<String>),
                matching: find.byType(Text))
            .evaluate())
          (e.widget as Text).data ?? '',
      ];
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      return words;
    }

    const appLevel = ['Models & storage', 'Backup & migrate', 'Switch reader'];
    final latest = await menu(const Key('river-more'));
    expect(latest, contains('Theme'));
    expect(latest, isNot(contains('Jobs')),
        reason: 'the jobs strip is the door while a job exists');
    await toTab(tester, 'Queue');
    expect(await menu(const Key('queue-more')), contains('Theme'));
    await toTab(tester, 'Courses');
    final courses = await menu(const Key('study-settings'));
    expect(courses, contains('Theme'));
    expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('Backup')),
        findsNothing);
    await toTab(tester, 'Library');
    final library = await menu(const Key('library-more'));
    for (final item in appLevel) {
      expect(library.any((w) => w.startsWith(item)), isTrue, reason: item);
      expect(latest.any((w) => w.startsWith(item)), isFalse, reason: item);
      expect(courses.any((w) => w.startsWith(item)), isFalse, reason: item);
    }
    expect(library, contains('Theme'));
  });
}
