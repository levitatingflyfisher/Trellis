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

  @override
  Future<List<Map<String, Object?>>> runSelect(
      QueryExecutor executor, String statement, List<Object?> args) async {
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

  testWidgets('scrolling reaches the oldest item, page after page',
      (tester) async {
    await seed(riverPageSize * 2 + 5);
    await openLatest(tester);
    expect(find.text('Item ${riverPageSize * 2 + 5}'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Item 1'), 600,
        scrollable: list, maxScrolls: 400);
    expect(find.text('Item 1'), findsOneWidget);
  });

  testWidgets('keeping an item on a later page keeps it, and its place',
      (tester) async {
    final ids = await seed(riverPageSize + 20);
    await openLatest(tester);
    await tester.scrollUntilVisible(find.text('Item 5'), 600,
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
    await tester.scrollUntilVisible(find.text('Item 5'), 600,
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
        find.byType(CircularProgressIndicator), 600,
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

    await tester.scrollUntilVisible(find.text('Item 1'), 600,
        scrollable: list, maxScrolls: 50);
    expect(find.text('Item 1'), findsOneWidget);
  });

  testWidgets('a failed page offers a retry, not an endless spinner',
      (tester) async {
    await seed(riverPageSize + 5);
    await openLatest(tester);
    gate.fail = true;
    await tester.scrollUntilVisible(
        find.byKey(const Key('river-more-retry')), 600,
        scrollable: list, maxScrolls: 400);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.tap(find.byKey(const Key('river-more-retry')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Item 1'), 600,
        scrollable: list, maxScrolls: 50);
    expect(find.text('Item 1'), findsOneWidget);
  });
}
