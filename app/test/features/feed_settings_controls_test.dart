import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/feeds/feed_settings_screen.dart';

/// Owner (board, 12 Nov): "the skip lengths and similar settings take free
/// typed text. That is weird." Every number from a small range is a row of
/// preset chips; the block is smaller and holds at large text.
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

  Future<void> pumpSettings(WidgetTester tester) async {
    final feed = (await db.feedsDao.feedById(feedId))!;
    await tester.pumpWidget(
        MaterialApp(home: FeedSettingsScreen(db: db, feed: feed)));
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final f = find.byKey(Key(key));
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  Future<Feed> save(WidgetTester tester) async {
    await tapKey(tester, 'feed-settings-save');
    return (await db.feedsDao.feedById(feedId))!;
  }

  testWidgets('no number is typed: the only text box left is the rule text',
      (tester) async {
    await pumpSettings(tester);
    final boxes = tester.widgetList<TextField>(find.byType(TextField));
    expect(boxes.map((b) => b.key), [const Key('rule-text')]);
  });

  testWidgets('skip lengths are preset chips: 5 to 60 seconds, and Off',
      (tester) async {
    await pumpSettings(tester);
    for (final s in [5, 10, 15, 30, 45, 60]) {
      expect(find.byKey(Key('feed-settings-skip-intro-$s')), findsOneWidget);
      expect(find.byKey(Key('feed-settings-skip-outro-$s')), findsOneWidget);
    }
    await tapKey(tester, 'feed-settings-skip-intro-15');
    await tapKey(tester, 'feed-settings-skip-outro-45');
    await tapKey(tester, 'feed-settings-keep-latest-audio-5');
    final feed = await save(tester);
    expect(feed.skipIntroSeconds, 15);
    expect(feed.skipOutroSeconds, 45);
    expect(feed.keepLatestAudio, 5);
  });

  testWidgets('Off and All clear a saved choice back to none',
      (tester) async {
    await db.feedsDao.updatePlaybackSettings(feedId,
        skipIntroSeconds: 30, skipOutroSeconds: 10, keepLatestAudio: 3);
    await pumpSettings(tester);
    expect(
        tester
            .widget<ChoiceChip>(
                find.byKey(const Key('feed-settings-skip-intro-30')))
            .selected,
        isTrue);
    await tapKey(tester, 'feed-settings-skip-intro-off');
    await tapKey(tester, 'feed-settings-keep-latest-audio-all');
    final feed = await save(tester);
    expect(feed.skipIntroSeconds, isNull);
    expect(feed.skipOutroSeconds, 10, reason: 'untouched choices survive');
    expect(feed.keepLatestAudio, isNull);
  });

  testWidgets('a value typed before the chips is shown as its own chip and '
      'kept', (tester) async {
    await db.feedsDao.updatePlaybackSettings(feedId,
        skipIntroSeconds: 22, keepLatestAudio: 7);
    await pumpSettings(tester);
    final odd = find.byKey(const Key('feed-settings-skip-intro-22'));
    expect(odd, findsOneWidget);
    expect(tester.widget<ChoiceChip>(odd).selected, isTrue);
    expect(find.byKey(const Key('feed-settings-keep-latest-audio-7')),
        findsOneWidget);
    final feed = await save(tester);
    expect(feed.skipIntroSeconds, 22);
    expect(feed.keepLatestAudio, 7);
  });

  testWidgets('trim silence is three chips: app default, on, off',
      (tester) async {
    await pumpSettings(tester);
    for (final k in ['default', 'on', 'off']) {
      expect(
          find.byWidgetPredicate(
              (w) => w is ChoiceChip && w.key == Key('feed-settings-dsp-$k')),
          findsOneWidget);
    }
  });

  testWidgets('the speed choices are chips too', (tester) async {
    await pumpSettings(tester);
    expect(
        find.byWidgetPredicate((w) =>
            w is ChoiceChip && w.key == const Key('feed-settings-speed-1.5')),
        findsOneWidget);
    expect(
        find.byWidgetPredicate((w) =>
            w is ChoiceChip &&
            w.key == const Key('feed-settings-speed-default')),
        findsOneWidget);
  });

  testWidgets('the playback block is compact: at 412 dp and normal text, '
      'speed, both skips and keep-audio fit in one screen', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpSettings(tester);
    final bottom = tester
        .getBottomLeft(
            find.byKey(const Key('feed-settings-keep-latest-audio-all')))
        .dy;
    expect(bottom, lessThan(915),
        reason: 'the four number settings sit above the fold');
  });

  for (final scale in [1.0, 2.0, 3.0]) {
    testWidgets('at 320 dp and ${scale}x text nothing overflows and every '
        'chip can be reached', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpSettings(tester);
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'feed-settings-skip-outro-60');
      await tapKey(tester, 'feed-settings-speed-2.0');
      expect(tester.takeException(), isNull);
      final feed = await save(tester);
      expect(feed.skipOutroSeconds, 60);
      expect(feed.speedOverride, 2.0);
    });
  }
}
