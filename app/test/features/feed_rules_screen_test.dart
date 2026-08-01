import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart' hide Alignment;
import 'package:trellis/features/feeds/feed_rules.dart';
import 'package:trellis/features/feeds/feeds_repository.dart';
import 'package:trellis/features/feeds/feeds_screen.dart';

import '../support/scripted_fetcher.dart';

const _rss = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel><title>t</title></channel></rss>
''';

/// Phase 3 (Campaign 5): the rules editor lives on the feed settings
/// surface (feed_settings_screen.dart) — calm, few controls, the same
/// screen's own layout idioms, since no separate include/exclude filter
/// screen exists anywhere in this app to share a precedent with (that
/// spec line's "existing" filter turned out to be fictional — verified:
/// zero UI references anywhere in lib/).
void main() {
  late AppDatabase db;
  late Profile profile;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.profilesDao.create('Ada');
    profile = (await db.profilesDao.all()).single;
  });
  tearDown(() => db.close());

  Future<void> pumpFeeds(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: FeedsScreen(
          db: db,
          repository: FeedsRepository(
              db: db,
              fetcher: ScriptedFetcher((u, h) => textResponse(_rss))),
          profile: profile),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> openSettings(WidgetTester tester, int feedId) async {
    await tester.tap(find.byKey(Key('feed-menu-$feedId')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Podcast settings'));
    await tester.pumpAndSettle();
  }

  testWidgets('adding a rule and saving persists it to Feeds.rulesJson',
      (tester) async {
    final feedId = await db.feedsDao
        .insertFeed(profileId: profile.id, url: 'https://cast.test/feed');
    await pumpFeeds(tester);
    await openSettings(tester, feedId);

    expect(find.text('Rules'), findsOneWidget);

    await tester.enterText(
        find.byKey(const Key('rule-text')), 'sponsored');
    await tester.ensureVisible(find.byKey(const Key('rule-action-skip')));
    await tester.tap(find.byKey(const Key('rule-action-skip')));
    await tester.ensureVisible(find.byKey(const Key('rule-add')));
    await tester.tap(find.byKey(const Key('rule-add')));
    await tester.pumpAndSettle();

    expect(find.textContaining('"sponsored"'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('feed-settings-save')));
    await tester.tap(find.byKey(const Key('feed-settings-save')));
    await tester.pumpAndSettle();

    final feed = (await db.feedsDao.feedsOf(profile.id)).single;
    final rules = decodeFeedRules(feed.rulesJson);
    expect(rules, hasLength(1));
    expect(rules.single.text, 'sponsored');
    expect(rules.single.action, FeedRuleAction.skip);
    expect(rules.single.field, FeedRuleField.title,
        reason: 'title is the default field');
  });

  testWidgets('deleting a rule removes it before save', (tester) async {
    final feedId = await db.feedsDao
        .insertFeed(profileId: profile.id, url: 'https://cast.test/feed');
    await db.feedsDao.setRules(
        feedId,
        encodeFeedRules(const [
          FeedRule(
              field: FeedRuleField.title,
              match: FeedRuleMatch.contains,
              text: 'sponsored',
              action: FeedRuleAction.skip),
        ]));
    await pumpFeeds(tester);
    await openSettings(tester, feedId);

    expect(find.textContaining('"sponsored"'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('rule-delete-0')));
    await tester.tap(find.byKey(const Key('rule-delete-0')));
    await tester.pumpAndSettle();
    expect(find.textContaining('"sponsored"'), findsNothing);

    await tester.ensureVisible(find.byKey(const Key('feed-settings-save')));
    await tester.tap(find.byKey(const Key('feed-settings-save')));
    await tester.pumpAndSettle();

    final feed = (await db.feedsDao.feedsOf(profile.id)).single;
    expect(decodeFeedRules(feed.rulesJson), isEmpty);
  });

  testWidgets('existing rules show on open, with their action labelled',
      (tester) async {
    final feedId = await db.feedsDao
        .insertFeed(profileId: profile.id, url: 'https://cast.test/feed');
    await db.feedsDao.setRules(
        feedId,
        encodeFeedRules(const [
          FeedRule(
              field: FeedRuleField.description,
              match: FeedRuleMatch.notContains,
              text: 'transcript',
              action: FeedRuleAction.markReadOnArrival),
        ]));
    await pumpFeeds(tester);
    await openSettings(tester, feedId);

    expect(find.textContaining('"transcript"'), findsOneWidget);
    expect(find.textContaining('— Mark read'), findsOneWidget);
  });
}
