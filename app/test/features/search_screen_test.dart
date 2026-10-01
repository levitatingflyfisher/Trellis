import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/episodes/episode_actions.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/search/search_screen.dart';
import 'package:trellis/features/search/search_store.dart';
import 'package:trellis/features/search/share_item.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/pick_reader.dart';
import '../support/scripted_fetcher.dart';

/// History and search on screen (ADR-0016 section 4): history before
/// anything is typed, results after a pause in typing, transcript hits
/// that play from their sentence, and Share that always does something.
void main() {
  late AppDatabase db;
  late FakeEpisodePlayer player;
  late PlayerController controller;
  late Profile profile;
  late int aurora;
  late int journal;
  final now = DateTime(2026, 10, 22, 12);

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    player = FakeEpisodePlayer();
    final pid = await db.profilesDao.create('Ada');
    profile = (await db.profilesDao.all()).single;
    controller =
        PlayerController(db: db, profileId: pid, createPlayer: () => player);
    final feed = await db.feedsDao.insertFeed(
        profileId: pid, url: 'https://cast.test/f', title: 'Night Sky Hour');
    aurora = await db.spineDao.insertWork(
        profileId: pid,
        kind: 'episode',
        title: 'Aurora season',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/a.mp3');
    await db.feedsDao.insertEpisode(
        workId: aurora,
        feedId: feed,
        guid: 'a',
        enclosureUrl: 'https://cast.test/a.mp3',
        publishedAtMs: 1000);
    await db.spineDao.insertSegments(aurora, const [
      (idx: 0, kind: 'prose', text: 'Welcome back.'),
      (idx: 1, kind: 'prose', text: 'The comet was brighter than expected.'),
    ]);
    await db.spineDao.insertAlignments(aurora, const [
      (segmentIdx: 0, tStartMs: 0, tEndMs: 60000),
      (segmentIdx: 1, tStartMs: 754000, tEndMs: 760000),
    ]);
    journal = await db.spineDao.insertWork(
        profileId: pid,
        kind: 'book',
        title: 'Comet journal',
        persistence: 'work',
        firstSeenEpochDay: 100);
    await db.spineDao.insertSegments(
        journal, const [(idx: 0, kind: 'prose', text: 'Day one.')]);
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
  });

  SearchDoors doors({ShareText? share, bool useDefaultShare = false}) =>
      SearchDoors(
          db: db,
          profile: profile,
          actions: EpisodeActions(
              db: db,
              profileId: profile.id,
              player: controller,
              localMlAvailable: false),
          shareText: share,
          useDefaultShare: useDefaultShare,
          now: () => now);

  Future<void> pumpSearch(WidgetTester tester, SearchDoors d) async {
    await tester.pumpWidget(MaterialApp(home: SearchScreen(doors: d)));
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('search-field')), text);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
  }

  Future<void> touch(int workId, DateTime at) async {
    await db.feedsDao
        .savePlayerPosition(profileId: profile.id, workId: workId, tMs: 1);
    await db.customStatement(
        'UPDATE player_positions SET updated_at_ms = ? WHERE work_id = ?',
        [at.millisecondsSinceEpoch, workId]);
  }

  group('before anything is typed', () {
    testWidgets('history shows, grouped by day, newest first',
        (tester) async {
      await touch(aurora, DateTime(2026, 10, 22, 8));
      await db.spineDao.savePosition(
          profileId: profile.id,
          workId: journal,
          segmentIdx: 0,
          wordIdx: 1,
          lastModality: 'read');
      await db.customStatement(
          'UPDATE positions SET updated_at_ms = ? WHERE work_id = ?',
          [DateTime(2026, 10, 21, 20).millisecondsSinceEpoch, journal]);
      await pumpSearch(tester, doors());

      expect(find.byKey(const Key('search-history-heading')), findsOneWidget);
      final order = [
        for (final k in ['day-Today', 'item-$aurora', 'day-Yesterday',
            'item-$journal'])
          tester.getTopLeft(find.byKey(Key(k))).dy,
      ];
      expect(order, List.of(order)..sort());
    });

    testWidgets('with no history it says so instead of showing nothing',
        (tester) async {
      await pumpSearch(tester, doors());
      expect(find.byKey(const Key('history-empty')), findsOneWidget);
    });

    testWidgets('clearing the box brings history back', (tester) async {
      await pumpSearch(tester, doors());
      await type(tester, 'comet');
      expect(find.byKey(const Key('search-results')), findsOneWidget);
      await type(tester, '');
      expect(find.byKey(const Key('search-history-heading')), findsOneWidget);
    });
  });

  group('typing', () {
    testWidgets('waits for a pause before searching', (tester) async {
      await pumpSearch(tester, doors());
      await tester.enterText(find.byKey(const Key('search-field')), 'comet');
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('search-results')), findsNothing);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('search-results')), findsOneWidget);
    });

    testWidgets('titles come first, then what was said, with the match in '
        'bold and its time', (tester) async {
      await pumpSearch(tester, doors());
      await type(tester, 'comet');
      final items = find.byKey(const Key('search-items-heading'));
      final said = find.byKey(const Key('search-said-heading'));
      expect(tester.getTopLeft(items).dy,
          lessThan(tester.getTopLeft(said).dy));
      expect(find.byKey(Key('item-$journal')), findsOneWidget);
      final hit = find.byKey(Key('said-$aurora-1'));
      expect(hit, findsOneWidget);
      expect(find.descendant(of: hit, matching: find.text('Aurora season · 12:34')),
          findsOneWidget);
      final rich = tester.widget<RichText>(find.descendant(
          of: hit,
          matching: find.byWidgetPredicate((w) =>
              w is RichText && w.text.toPlainText().contains('comet'))));
      final bold = <String>[];
      rich.text.visitChildren((s) {
        if (s is TextSpan &&
            s.style?.fontWeight == FontWeight.w800 &&
            s.text != null) {
          bold.add(s.text!);
        }
        return true;
      });
      expect(bold, ['comet']);
    });

    testWidgets('a show name finds its episodes', (tester) async {
      await pumpSearch(tester, doors());
      await type(tester, 'night sky');
      expect(find.byKey(Key('item-$aurora')), findsOneWidget);
    });

    testWidgets('no match says so', (tester) async {
      await pumpSearch(tester, doors());
      await type(tester, 'zebra');
      expect(find.byKey(const Key('search-nothing')), findsOneWidget);
    });
  });

  testWidgets('a failing search says so instead of showing stale results',
      (tester) async {
    final store = _FlakyStore(db);
    await tester.pumpWidget(
        MaterialApp(home: SearchScreen(doors: doors(), store: store)));
    await tester.pumpAndSettle();
    await type(tester, 'comet');
    expect(find.byKey(const Key('search-results')), findsOneWidget);
    store.failing = true;
    await type(tester, 'aurora');
    expect(find.byKey(const Key('search-results')), findsNothing);
    expect(find.byKey(const Key('search-failed')), findsOneWidget);
    store.failing = false;
    await type(tester, 'aurora s');
    expect(find.byKey(const Key('search-failed')), findsNothing);
    expect(find.byKey(Key('item-$aurora')), findsOneWidget);
  });

  testWidgets('tapping what was said plays from that sentence',
      (tester) async {
    await pumpSearch(tester, doors());
    await type(tester, 'comet');
    await tester.tap(find.byKey(Key('said-$aurora-1')));
    await tester.pumpAndSettle();
    expect(player.loadedUrl, 'https://cast.test/a.mp3');
    expect(player.log.last, 'seek:754000');
  });

  group('share', () {
    late List<String> copied;
    setUp(() {
      copied = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
    });
    tearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    Future<void> shareAurora(WidgetTester tester) async {
      await type(tester, 'aurora');
      await tester.tap(find.byKey(Key('menu-$aurora')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('share-$aurora')));
      await tester.pumpAndSettle();
    }

    const text = 'Aurora season, from Night Sky Hour\nhttps://cast.test/a.mp3';

    testWidgets('hands the title and link to the platform share',
        (tester) async {
      final shared = <String>[];
      await pumpSearch(tester,
          doors(share: (t, {subject}) async => shared.add(t)));
      await shareAurora(tester);
      expect(shared, [text]);
      expect(copied, isEmpty);
    });

    testWidgets('with no platform share it copies and says so',
        (tester) async {
      await pumpSearch(tester, doors());
      await shareAurora(tester);
      expect(copied, [text]);
      expect(find.text('Copied to the clipboard'), findsOneWidget);
    });

    testWidgets('a failing platform share falls back to the clipboard',
        (tester) async {
      await pumpSearch(tester,
          doors(share: (t, {subject}) async => throw StateError('no sheet')));
      await shareAurora(tester);
      expect(copied, [text]);
    });

    testWidgets('a book with no link shares its title', (tester) async {
      await pumpSearch(tester, doors());
      await type(tester, 'journal');
      await tester.tap(find.byKey(Key('share-$journal')));
      await tester.pumpAndSettle();
      expect(copied, ['Comet journal']);
    });
  });

  group('the way in', () {
    Future<void> pumpApp(WidgetTester tester) async {
      await tester.pumpWidget(TrellisApp(
          db: db,
          fetcher: ScriptedFetcher((u, h) => textResponse('')),
          createPlayer: () => FakeEpisodePlayer()));
      await tester.pumpAndSettle();
      await pickReader(tester, 'Ada');
      await tester.tap(find.descendant(
          of: find.byType(NavigationBar), matching: find.text('Inbox')));
      await tester.pumpAndSettle();
    }

    testWidgets('Search at the top of the Inbox opens search', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.byKey(const Key('river-search')));
      await tester.pumpAndSettle();
      expect(find.byType(SearchScreen), findsOneWidget);
    });

    testWidgets('History in the Inbox menu opens history', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.byKey(const Key('river-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('river-open-history')));
      await tester.pumpAndSettle();
      expect(find.byType(HistoryScreen), findsOneWidget);
    });

    testWidgets('Subscriptions has its own search', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.byKey(const Key('manage-feeds')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('feeds-search')));
      await tester.pumpAndSettle();
      expect(find.byType(SearchScreen), findsOneWidget);
    });
  });
}

class _FlakyStore extends SearchStore {
  bool failing = false;
  _FlakyStore(super.db);

  @override
  Future<SearchResults> search(int profileId, String query) async {
    if (failing) throw StateError('database is closed');
    return super.search(profileId, query);
  }
}
