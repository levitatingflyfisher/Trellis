import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/tabs.dart';
import '../support/scripted_fetcher.dart';
import '../support/pick_reader.dart';

/// "New since you last looked" (ADR-0019): one quiet line between what was
/// published since the previous open of Latest and what was already
/// there. No count and no badge (ADR-0003 law 5's spirit).
void main() {
  late AppDatabase db;
  late int profileId;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
  });
  tearDown(() => db.close());

  const divider = 'New since you last looked';
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  const hour = Duration.millisecondsPerHour;

  Future<void> seed(Map<String, int> titlesToPublishedMs) async {
    final feedId = await db.feedsDao
        .insertFeed(profileId: profileId, url: 'https://cast.test/feed');
    for (final MapEntry(key: title, value: ms) in titlesToPublishedMs.entries) {
      final id = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'article',
          title: title,
          persistence: 'ephemeron',
          firstSeenEpochDay: 100);
      await db.feedsDao.insertEpisode(
          workId: id, feedId: feedId, guid: title, publishedAtMs: ms);
    }
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(TrellisApp(
        db: db,
        fetcher: ScriptedFetcher((u, h) => textResponse('')),
        createPlayer: () => FakeEpisodePlayer()));
    await tester.pumpAndSettle();
    await pickReader(tester, 'Ada');
  }

  Future<void> openLatest(WidgetTester tester) async {
    await tester.tap(tabLabel('Latest'));
    await tester.pumpAndSettle();
  }

  testWidgets('what arrived since the last visit sits above the line, and '
      'the next visit starts fresh', (tester) async {
    await seed({
      'Old news': nowMs - 48 * hour,
      'Fresh one': nowMs - 1 * hour,
      'Fresh two': nowMs - 2 * hour,
    });
    await db.profilesDao.swapLatestSeen(profileId, nowMs: nowMs - 24 * hour);
    await pumpApp(tester);
    await openLatest(tester);

    expect(find.text(divider), findsOneWidget);
    double y(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(y('Fresh two'), lessThan(y(divider)));
    expect(y(divider), lessThan(y('Old news')));
    expect(find.textContaining(RegExp(r'\d+ new')), findsNothing,
        reason: 'no count to nag with');

    // Away and back: a tab switch is not a new visit, so the line holds.
    await tester.tap(tabLabel('Queue'));
    await tester.pumpAndSettle();
    await openLatest(tester);
    expect(find.text(divider), findsOneWidget);
    expect(y('Fresh two'), lessThan(y(divider)));

    // A passing interruption (the notification shade, a system dialog)
    // is not leaving the app either.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text(divider), findsOneWidget);

    // Leaving the app and coming back is: everything was seen.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text(divider), findsNothing);
  });

  testWidgets('the very first visit draws no line over the whole archive',
      (tester) async {
    await seed({'Old news': nowMs - 48 * hour, 'Fresh': nowMs - hour});
    await pumpApp(tester);
    await openLatest(tester);
    expect(find.text('Fresh'), findsOneWidget);
    expect(find.text(divider), findsNothing);
  });

  testWidgets('nothing new, no line', (tester) async {
    await seed({'Old news': nowMs - 48 * hour});
    await db.profilesDao.swapLatestSeen(profileId, nowMs: nowMs - 24 * hour);
    await pumpApp(tester);
    await openLatest(tester);
    expect(find.text(divider), findsNothing);
  });
}
