import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/feeds/auto_download.dart';
import 'package:trellis/features/feeds/background/feed_check_settings.dart';
import 'package:trellis/features/feeds/feed_settings_screen.dart';
import 'package:trellis/features/models/models_screen.dart';

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
}
