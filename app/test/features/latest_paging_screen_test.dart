import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull, Column;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/tabs.dart';
import '../support/scripted_fetcher.dart';
import '../support/pick_reader.dart';

/// Latest pages (ADR-0019): it loads one page, loads the next as the
/// listener nears the end, and an action on a row re-reads that row
/// rather than dropping the list back to its first page.
/// Holds or fails the next "page below" query (the keyset `after`
/// clause) when armed, so a test can land a reload or an error mid-page.
class _PageGate extends QueryInterceptor {
  Completer<void>? hold;
  bool fail = false;

  /// Holds the next read of the queue: a row's re-read after an action.
  Completer<void>? holdQueue;

  /// Holds the next text-size lookup: a landing page's sizes.
  Completer<void>? holdSizes;

  @override
  Future<List<Map<String, Object?>>> runSelect(
      QueryExecutor executor, String statement, List<Object?> args) async {
    if (statement.contains('"segments"') && statement.contains('GROUP BY')) {
      final h = holdSizes;
      if (h != null) {
        holdSizes = null;
        await h.future;
      }
    }
    if (statement.contains('FROM "queue"')) {
      final h = holdQueue;
      if (h != null) {
        holdQueue = null;
        await h.future;
      }
    }
    if (statement.contains('"work_id" < ?')) {
      if (fail) {
        fail = false;
        throw StateError('disk said no');
      }
      final h = hold;
      if (h != null) {
        hold = null;
        await h.future;
      }
    }
    return executor.runSelect(statement, args);
  }
}

void main() {
  late AppDatabase db;
  late _PageGate gate;
  setUp(() {
    gate = _PageGate();
    db = AppDatabase.forTesting(NativeDatabase.memory().interceptWith(gate));
  });
  tearDown(() => db.close());

  /// [count] text items, 'Item 1' oldest; returns their work ids by number.
  Future<Map<int, int>> seed(int count) async {
    final profileId = await db.profilesDao.create('Ada');
    final feedId = await db.feedsDao
        .insertFeed(profileId: profileId, url: 'https://cast.test/feed');
    final ids = <int, int>{};
    for (var i = 1; i <= count; i++) {
      final id = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'article',
          title: 'Item $i',
          persistence: 'ephemeron',
          firstSeenEpochDay: 100);
      await db.feedsDao.insertEpisode(
          workId: id, feedId: feedId, guid: 'g$i', publishedAtMs: i * 1000);
      // Enough text for a reading time on the row.
      await db.spineDao.insertSegments(
          id, [(idx: 0, kind: 'prose', text: 'Words on the marsh. ' * 80)]);
      ids[i] = id;
    }
    return ids;
  }

  Future<void> openLatest(WidgetTester tester) async {
    await tester.pumpWidget(TrellisApp(
        db: db,
        fetcher: ScriptedFetcher((u, h) => textResponse('')),
        createPlayer: () => FakeEpisodePlayer()));
    await tester.pumpAndSettle();
    await pickReader(tester, 'Ada');
    await tester.tap(tabLabel('Latest'));
    await tester.pumpAndSettle();
  }

  final list = find.byType(Scrollable).last;
  // Every scroll here steps by less than a screen: a drag far past the
  // end while the next page loads trips the stretch indicator's
  // debug-only build-during-frame check (Flutter's, not the app's).

  testWidgets('scrolling reaches the oldest item, page after page',
      (tester) async {
    await seed(riverPageSize * 2 + 5);
    await openLatest(tester);
    expect(find.text('Item ${riverPageSize * 2 + 5}'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Item 1'), 300,
        scrollable: list, maxScrolls: 400);
    expect(find.text('Item 1'), findsOneWidget);
  });

  testWidgets('keeping an item on a later page keeps it, and its place',
      (tester) async {
    final ids = await seed(riverPageSize + 20);
    await openLatest(tester);
    await tester.scrollUntilVisible(find.text('Item 5'), 300,
        scrollable: list, maxScrolls: 400);
    await tester.pumpAndSettle();

    await tester.drag(find.byKey(Key('swipe-${ids[5]}')), const Offset(500, 0));
    await tester.pumpAndSettle();

    expect((await db.spineDao.workById(ids[5]!))!.persistence, 'work');
    expect(find.text('Item 5'), findsOneWidget,
        reason: 'the row is patched in place, not reloaded off screen');
    expect(find.byKey(Key('unread-dot-${ids[5]}')), findsNothing);
  });

  testWidgets('a trip to another tab keeps the loaded pages and the scroll '
      'position', (tester) async {
    await seed(riverPageSize + 20);
    await openLatest(tester);
    await tester.scrollUntilVisible(find.text('Item 5'), 300,
        scrollable: list, maxScrolls: 400);
    await tester.pumpAndSettle();
    final y = tester.getTopLeft(find.text('Item 5')).dy;

    await toTab(tester, 'Queue');
    await toTab(tester, 'Latest');

    expect(find.text('Item 5'), findsOneWidget,
        reason: 'the second page is still loaded and still in view');
    expect(tester.getTopLeft(find.text('Item 5')).dy, y);
  });

  testWidgets('a reload while a page is in flight does not stall paging',
      (tester) async {
    await seed(riverPageSize + 5);
    await openLatest(tester);
    final release = gate.hold = Completer<void>();
    await tester.scrollUntilVisible(
        find.byType(CircularProgressIndicator), 300,
        scrollable: list, maxScrolls: 400);
    await tester.pump();
    expect(gate.hold, isNull, reason: 'the page below is in flight');

    // A filter change replaces the list; its footer asks for the next
    // page and is turned away by the one still in flight.
    await tester.tap(find.byKey(const Key('chip-text')));
    await tester.pump();
    await tester.pump();
    release.complete();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    await tester.scrollUntilVisible(find.text('Item 1'), 300,
        scrollable: list, maxScrolls: 50);
    expect(find.text('Item 1'), findsOneWidget);
  });

  testWidgets('a failed page offers a retry, not an endless spinner',
      (tester) async {
    await seed(riverPageSize + 5);
    await openLatest(tester);
    gate.fail = true;
    await tester.scrollUntilVisible(
        find.byKey(const Key('river-more-retry')), 300,
        scrollable: list, maxScrolls: 400);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.tap(find.byKey(const Key('river-more-retry')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Item 1'), 300,
        scrollable: list, maxScrolls: 50);
    expect(find.text('Item 1'), findsOneWidget);
  });

  group('a row re-read and a page landing merge, whichever comes first', () {
    Future<void> markFinished(WidgetTester tester, int id) async {
      // No pumpAndSettle: the footer's spinner never settles.
      await tester.tap(find.byKey(Key('menu-$id')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(Key('mark-finished-$id')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    Future<void> holdNextPage(WidgetTester tester) async {
      await tester.scrollUntilVisible(
          find.byType(CircularProgressIndicator), 300,
          scrollable: list, maxScrolls: 400);
      await tester.pump();
    }

    testWidgets('the re-read lands first: the page keeps its In Queue',
        (tester) async {
      final ids = await seed(riverPageSize + 5);
      await openLatest(tester);
      // The page's rows arrive; its sizes are held, so the re-read below
      // lands in between.
      final page = gate.holdSizes = Completer<void>();
      await holdNextPage(tester);
      expect(gate.holdSizes, isNull, reason: 'the page below is in flight');

      // Item 6 is page one's last row, on screen by the spinner.
      await db.queueDao
          .playLast(profileId: 1, workId: ids[6]!, nowMs: 1);
      await markFinished(tester, ids[6]!);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.byKey(Key('queued-${ids[6]}')), findsOneWidget);

      page.complete();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.byKey(Key('queued-${ids[6]}')), findsOneWidget,
          reason: 'the landing page must not put back an older state');
      await tester.scrollUntilVisible(find.text('Item 1'), 300,
          scrollable: list, maxScrolls: 50);
      expect(find.textContaining('min\u00A0read'), findsWidgets);
    });

    testWidgets('the page lands first: the re-read keeps its reading times',
        (tester) async {
      final ids = await seed(riverPageSize + 5);
      await openLatest(tester);
      final page = gate.hold = Completer<void>();
      await holdNextPage(tester);

      final reread = gate.holdQueue = Completer<void>();
      await markFinished(tester, ids[6]!);
      await tester.pump();
      expect(gate.holdQueue, isNull, reason: 'the re-read is in flight');

      page.complete();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      reread.complete();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.scrollUntilVisible(find.text('Item 1'), 300,
          scrollable: list, maxScrolls: 50);
      await tester.pump();
      final meta = find.descendant(
          of: find.byKey(Key('swipe-${ids[1]}')),
          matching: find.textContaining('min\u00A0read'));
      expect(meta, findsOneWidget,
          reason: 'page two’s sizes survive a re-read that started before '
              'the page landed');
    });
  });
}
