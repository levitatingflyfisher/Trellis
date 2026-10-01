import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/feeds/feed_detail_screen.dart';
import 'package:trellis/features/feeds/feeds_repository.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/works/work_row.dart';
import 'package:trellis/main.dart';

import '../../support/fake_player.dart';
import '../../support/pick_reader.dart';
import '../../support/scripted_fetcher.dart';
import '../../support/tabs.dart';

/// 1.5.4: every list of works draws the same row. A transcribed episode
/// and a text work show up on each screen with Read, and an episode's ⋮
/// carries the same shared items in Latest as in the Queue.
void main() {
  late AppDatabase db;
  late int profileId;
  late int feedId;
  late int aurora;
  late int notes;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
    feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://x.test/f', title: 'Night Sky');
    final day = DateTime.now().millisecondsSinceEpoch;

    // A kept, transcribed episode and a kept feed article: both in
    // Latest, the show page, the Library, the Queue, History and Search.
    aurora = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Aurora notes',
        persistence: 'work',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://x.test/aurora.mp3');
    await db.feedsDao.insertEpisode(
        workId: aurora,
        feedId: feedId,
        guid: 'aurora',
        enclosureUrl: 'https://x.test/aurora.mp3',
        durationMs: 45 * 60000,
        publishedAtMs: day - 1000);
    await db.spineDao.insertSegments(
        aurora, const [(idx: 0, kind: 'prose', text: 'Lights overhead.')]);
    await db.spineDao.insertAlignments(
        aurora, const [(segmentIdx: 0, tStartMs: 0, tEndMs: 900)]);

    notes = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'article',
        title: 'Field notes',
        persistence: 'work',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://x.test/field');
    await db.feedsDao.insertEpisode(
        workId: notes,
        feedId: feedId,
        guid: 'notes',
        publishedAtMs: day - 2000);
    await db.spineDao.insertSegments(
        notes, const [(idx: 0, kind: 'prose', text: 'The marsh at dawn.')]);

    await db.queueDao.playLast(profileId: profileId, workId: aurora, nowMs: 1);
    await db.queueDao.playLast(profileId: profileId, workId: notes, nowMs: 2);
    // Touched, so both are in History.
    await db.feedsDao
        .savePlayerPosition(profileId: profileId, workId: aurora, tMs: 1000);
    await db.spineDao.savePosition(
        profileId: profileId,
        workId: notes,
        segmentIdx: 0,
        wordIdx: 1,
        lastModality: 'read');
  });
  tearDown(() => db.close());

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(TrellisApp(
        db: db,
        fetcher: ScriptedFetcher((u, h) => textResponse('')),
        createPlayer: () => FakeEpisodePlayer()));
    await tester.pumpAndSettle();
    await pickReader(tester, 'Ada');
  }

  void expectBothReadable(String screen) {
    for (final id in [aurora, notes]) {
      final row = find.ancestor(
          of: find.byKey(Key('read-$id')), matching: find.byType(WorkRow));
      expect(row, findsWidgets, reason: '$screen: Read on work $id');
    }
  }

  testWidgets('Latest, the Queue, History, the Library and Search all show '
      'Read on a transcribed episode and on a text work', (tester) async {
    await pumpApp(tester);
    expectBothReadable('Latest');

    await toTab(tester, 'Queue');
    expectBothReadable('Queue');

    await tester.tap(find.byKey(const Key('queue-history')));
    await tester.pumpAndSettle();
    expect(find.text('History'), findsWidgets);
    expectBothReadable('History');
    await tester.pageBack();
    await tester.pumpAndSettle();

    await toTab(tester, 'Library');
    expectBothReadable('Library');

    await toTab(tester, 'Latest');
    await tester.tap(find.byKey(const Key('river-search')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('search-field')), 'notes');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('search-results')), findsOneWidget);
    expectBothReadable('Search');
  });

  testWidgets('the show page shows Read on both too', (tester) async {
    final controller = PlayerController(
        db: db, profileId: profileId, createPlayer: FakeEpisodePlayer.new);
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
        home: FeedDetailScreen(
            db: db,
            repository: FeedsRepository(
                db: db, fetcher: ScriptedFetcher((u, h) => textResponse(''))),
            feed: (await db.feedsDao.feedById(feedId))!,
            playerController: controller)));
    await tester.pumpAndSettle();
    expectBothReadable('show page');
  });

  testWidgets('each kind of work has the SAME whole shared ⋮ section on '
      'every screen it appears on, with only screen items after it',
      (tester) async {
    final book = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'book',
        title: 'Marsh notes, a book',
        persistence: 'work',
        firstSeenEpochDay: 100);
    await db.spineDao.insertSegments(
        book, const [(idx: 0, kind: 'prose', text: 'Reeds.')]);
    await db.queueDao.playLast(profileId: profileId, workId: book, nowMs: 3);
    await db.spineDao.savePosition(
        profileId: profileId,
        workId: book,
        segmentIdx: 0,
        wordIdx: 1,
        lastModality: 'read');

    Future<List<String>> menuAt(Finder button) async {
      await tester.ensureVisible(button.first);
      await tester.pumpAndSettle();
      await tester.tap(button.first);
      await tester.pumpAndSettle();
      final words = [
        for (final e in tester.widgetList<PopupMenuEntry<String>>(
            find.byWidgetPredicate((w) => w is PopupMenuEntry<String>)))
          if (e is PopupMenuDivider)
            '|'
          else if (e is PopupMenuItem<String>)
            ((e.child as Text).data ?? ''),
      ];
      await tester.tapAt(Offset.zero); // close the menu
      await tester.pumpAndSettle();
      return words;
    }

    Future<List<String>> menuOf(int id) => menuAt(find.byKey(Key('menu-$id')));

    // The work page's ⋮, opened by tapping the row's title.
    Future<List<String>> pageMenuOf(String title) async {
      final row = find.text(title).first;
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      final words = await menuAt(find.byKey(const Key('work-page-menu')));
      await tester.pageBack();
      await tester.pumpAndSettle();
      return words;
    }

    List<String> shared(List<String> menu) =>
        menu.takeWhile((w) => w != '|').toList();

    // kind -> screen -> whole menu
    final menus = <String, Map<String, List<String>>>{
      'episode': {},
      'text': {},
      'book': {},
    };
    Future<void> read(String screen, {bool books = true, bool feed = true}) async {
      if (feed) {
        menus['episode']![screen] = await menuOf(aurora);
        menus['text']![screen] = await menuOf(notes);
      }
      if (books) menus['book']![screen] = await menuOf(book);
    }

    await pumpApp(tester);
    await read('Latest', books: false);

    await tester.tap(find.byKey(const Key('manage-feeds')));
    await tester.pumpAndSettle();
    await read('Books shelf', feed: false);
    await tester.tap(find.text('Night Sky'));
    await tester.pumpAndSettle();
    await read('show page', books: false);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('river-search')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('search-field')), 'notes');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await read('Search');
    await tester.pageBack();
    await tester.pumpAndSettle();

    await toTab(tester, 'Queue');
    await read('Queue');
    await tester.tap(find.byKey(const Key('queue-history')));
    await tester.pumpAndSettle();
    await read('History');
    await tester.pageBack();
    await tester.pumpAndSettle();

    await toTab(tester, 'Library');
    await read('Library');
    menus['episode']!['work page'] = await pageMenuOf('Aurora notes');
    menus['text']!['work page'] = await pageMenuOf('Field notes');
    menus['book']!['work page'] = await pageMenuOf('Marsh notes, a book');

    const pageButtons = {
      'Play next',
      'Play last',
      'Download',
      // Only an untranscribed episode's Translate… is the same act; aurora
      // has a transcript, so its ⋮ keeps it.
    };
    expect(shared(menus['episode']!['Latest']!), contains('Transcribe again'),
        reason: 'aurora is transcribed, and every screen knows it');
    for (final kind in menus.entries) {
      final screens = kind.value;
      expect(screens.length, greaterThanOrEqualTo(5), reason: kind.key);
      final first = screens.entries.first;
      expect(shared(first.value), contains('Share'), reason: kind.key);
      for (final other in screens.entries.skip(1)) {
        // The work page shows some shared items as buttons, and leaves
        // only those out of its ⋮ (the same list, filtered by value).
        final expected = other.key == 'work page'
            ? [
                for (final w in shared(first.value))
                  if (!pageButtons.contains(w)) w,
              ]
            : shared(first.value);
        expect(shared(other.value), expected,
            reason: '${kind.key}: ${other.key} vs ${first.key}');
      }
    }
    expect(shared(menus['episode']!['Latest']!),
        containsAll(['Play next', 'Play last', 'Share']));
    expect(shared(menus['text']!['Latest']!), contains('Mark finished'));
    // Each screen's own items come after the divider.
    expect(menus['episode']!['Latest']!.skipWhile((w) => w != '|'),
        containsAll(['Keep', 'Let it pass']));
    expect(menus['episode']!['show page']!, isNot(contains('Keep')));
    expect(menus['episode']!['Queue']!.last, 'Remove from Queue');
    expect(menus['book']!['Library']!.skipWhile((w) => w != '|'),
        containsAll(['Pin', 'Remove']));
  });
}
