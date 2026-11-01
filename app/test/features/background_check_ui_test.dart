import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/feeds/auto_download.dart';
import 'package:trellis/features/feeds/background/feed_check_settings.dart';
import 'package:trellis/features/feeds/feed_settings_screen.dart';
import 'package:trellis/features/feeds/feeds_repository.dart';
import 'package:trellis/features/feeds/feeds_screen.dart';
import 'package:trellis/features/models/models_screen.dart';

import '../support/scripted_fetcher.dart';
import 'feed_check_settings_test.dart' show FakeScheduler;

void main() {
  late AppDatabase db;
  late int feedId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final profileId = await db.profilesDao.create('Reader');
    feedId = await db.feedsDao
        .insertFeed(profileId: profileId, url: 'https://cast.test/feed');
  });
  tearDown(() => db.close());

  Future<void> pumpSettings(WidgetTester tester, {required bool offer}) async {
    final feed = (await db.feedsDao.feedById(feedId))!;
    await tester.pumpWidget(MaterialApp(
        home: FeedSettingsScreen(
            db: db, feed: feed, offerAutoDownload: offer)));
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const Key('feed-settings-save')));
    await tester.tap(find.byKey(const Key('feed-settings-save')));
    await tester.pumpAndSettle();
  }

  testWidgets('turning auto-download on passes the consent dialog, and a '
      'no leaves it off', (tester) async {
    await pumpSettings(tester, offer: true);
    final toggle = find.byKey(const Key('feed-settings-auto-download'));
    await tester.ensureVisible(toggle);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('consent-dialog')), findsOneWidget);
    expect(find.textContaining('only on Wi-Fi'), findsOneWidget);
    await tester.tap(find.byKey(const Key('consent-cancel')));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('consent-accept')));
    await tester.pumpAndSettle();
    await save(tester);

    expect((await db.feedsDao.feedById(feedId))!.autoDownload, isTrue);
    expect(await AutoDownloadMarks(db).read(feedId), isNotNull,
        reason: 'turning it on starts from now');
  });

  testWidgets('where no pass can run, the switch is not offered',
      (tester) async {
    await pumpSettings(tester, offer: false);
    expect(find.byKey(const Key('feed-settings-auto-download')), findsNothing);
  });

  testWidgets('"Checking feeds" turns background checks off and on through '
      'the scheduler', (tester) async {
    final scheduler = FakeScheduler();
    final settings = FeedCheckSettings(db, scheduler);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: FeedCheckSection(settings: settings))));
    await tester.pumpAndSettle();

    final background = find.byKey(const Key('feed-check-background'));
    expect(tester.widget<SwitchListTile>(background).value, isTrue);
    expect(find.textContaining('won’t get a notification'), findsOneWidget);

    await tester.tap(background);
    await tester.pumpAndSettle();
    expect(scheduler.calls, ['cancel', 'cancel-auto']);
    expect(
        tester
            .widget<SwitchListTile>(
                find.byKey(const Key('feed-check-wifi-only')))
            .onChanged,
        isNull,
        reason: 'Wi-Fi only means nothing while checks are off');

    await tester.tap(background);
    await tester.pumpAndSettle();
    expect(scheduler.calls.last, 'schedule unmetered=true replace=false');
  });

  Future<void> pumpSubscriptions(WidgetTester tester,
      {FeedCheckSettings? feedCheck}) async {
    await tester.pumpWidget(MaterialApp(
        home: FeedsScreen(
            db: db,
            repository: FeedsRepository(
                db: db, fetcher: ScriptedFetcher((u, h) => textResponse(''))),
            profile: (await db.profilesDao.all()).single,
            feedCheck: feedCheck)));
    await tester.pumpAndSettle();
  }

  testWidgets('Subscriptions has a visible door to the Wi-Fi switches '
      '(1.6.0, user: "update on WiFi or not" was "missing": it sat only '
      'under Models & storage)', (tester) async {
    final scheduler = FakeScheduler();
    await pumpSubscriptions(tester,
        feedCheck: FeedCheckSettings(db, scheduler));

    final door = find.byKey(const Key('feeds-wifi-and-data'));
    expect(door, findsOneWidget);
    expect(find.text('Wi-Fi and data'), findsOneWidget);
    await tester.tap(door);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('feed-check-background')), findsOneWidget);
    final wifiOnly = find.byKey(const Key('feed-check-wifi-only'));
    expect(tester.widget<SwitchListTile>(wifiOnly).value, isTrue);
    await tester.tap(wifiOnly);
    await tester.pumpAndSettle();
    expect(scheduler.calls, ['schedule unmetered=false replace=true']);
  });

  testWidgets('on a narrow phone with large text the door wraps under the '
      'last-checked line, never off the edge', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!),
        home: FeedsScreen(
            db: db,
            repository: FeedsRepository(
                db: db, fetcher: ScriptedFetcher((u, h) => textResponse(''))),
            profile: (await db.profilesDao.all()).single,
            feedCheck: FeedCheckSettings(db, FakeScheduler()))));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final door = tester.getRect(find.byKey(const Key('feeds-wifi-and-data')));
    final line = tester.getRect(find.byKey(const Key('feeds-last-checked')));
    expect(door.right, lessThanOrEqualTo(320));
    expect(door.left, greaterThanOrEqualTo(0));
    expect(door.top, greaterThanOrEqualTo(line.bottom),
        reason: 'under the line, not squeezed beside it');
  });

  testWidgets('where nothing can run in the background, Subscriptions '
      'offers no such door', (tester) async {
    await pumpSubscriptions(tester);
    expect(find.byKey(const Key('feeds-wifi-and-data')), findsNothing);
    expect(find.byKey(const Key('feeds-last-checked')), findsOneWidget);
  });
}
