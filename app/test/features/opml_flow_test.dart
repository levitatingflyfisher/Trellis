import 'dart:convert';

import 'package:comms_core/comms_core.dart' as comms;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/feeds/feeds_repository.dart';
import 'package:trellis/features/feeds/feeds_screen.dart';

import '../support/scripted_fetcher.dart';

const _rss = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel>
  <title>The Night Sky Cast</title>
  <item>
    <title>Aurora season</title>
    <link>https://cast.test/aurora</link>
    <pubDate>Wed, 05 Aug 2026 12:00:00 GMT</pubDate>
    <description>Lights in the north.</description>
  </item>
</channel></rss>
''';

const _opmlTwo = '''
<?xml version="1.0" encoding="UTF-8"?>
<opml version="2.0">
  <head><title>subs</title></head>
  <body>
    <outline type="rss" text="Night Sky" xmlUrl="https://cast.test/feed"/>
    <outline type="rss" text="Second Cast" xmlUrl="https://second.test/feed"/>
  </body>
</opml>
''';

/// OPML both ways through the feeds screen, with the platform file seams
/// faked — the pure interchange logic is comms_core's, already tested
/// there; this pins the wiring: import subscribes + validates by fetching,
/// export round-trips through comms_core's parser.
void main() {
  late AppDatabase db;
  late Profile profile;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.profilesDao.create('Ada');
    profile = (await db.profilesDao.all()).single;
  });
  tearDown(() => db.close());

  Future<void> pumpFeeds(
    WidgetTester tester, {
    required ScriptedFetcher fetcher,
    List<int>? opmlToPick,
    List<(String, List<int>)>? savedFiles,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FeedsScreen(
          db: db,
          repository: FeedsRepository(db: db, fetcher: fetcher),
          profile: profile,
          pickOpmlBytes: () async => opmlToPick,
          saveOpmlBytes: (name, bytes) async {
            savedFiles?.add((name, bytes));
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('importing an OPML follows its feeds and validates each by '
      'fetching', (tester) async {
    final fetcher = ScriptedFetcher((u, h) => textResponse(_rss));
    await pumpFeeds(
      tester,
      fetcher: fetcher,
      opmlToPick: utf8.encode(_opmlTwo),
    );

    await tester.tap(find.byKey(const Key('opml-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import OPML'));
    await tester.pumpAndSettle();

    expect(find.text('Following 2 new feeds.'), findsOneWidget);
    final feeds = await db.feedsDao.feedsOf(profile.id);
    expect(feeds.map((f) => f.url), [
      'https://cast.test/feed',
      'https://second.test/feed',
    ]);
    // Validation fetched both.
    expect(fetcher.calls.map((c) => c.url.host).toSet(), {
      'cast.test',
      'second.test',
    });
    // …and the outline's own title survives the validating fetch (donor
    // law: a parsed title only fills an EMPTY one).
    expect(feeds.first.title, 'Night Sky');
    // Items landed as river ephemera.
    expect(await db.feedsDao.riverItems(profile.id), isNotEmpty);
  });

  testWidgets('an already-followed outline is skipped, not duplicated', (
    tester,
  ) async {
    await db.feedsDao.insertFeed(
      profileId: profile.id,
      url: 'https://cast.test/feed',
    );
    final fetcher = ScriptedFetcher((u, h) => textResponse(_rss));
    await pumpFeeds(
      tester,
      fetcher: fetcher,
      opmlToPick: utf8.encode(_opmlTwo),
    );

    await tester.tap(find.byKey(const Key('opml-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import OPML'));
    await tester.pumpAndSettle();

    expect(find.text('Following 1 new feed.'), findsOneWidget);
    expect(await db.feedsDao.feedsOf(profile.id), hasLength(2));
  });

  testWidgets('an invalid OPML file is refused calmly', (tester) async {
    final fetcher = ScriptedFetcher((u, h) => textResponse(_rss));
    await pumpFeeds(
      tester,
      fetcher: fetcher,
      opmlToPick: utf8.encode('not opml at all <'),
    );

    await tester.tap(find.byKey(const Key('opml-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import OPML'));
    await tester.pumpAndSettle();

    expect(find.text('Invalid OPML file'), findsOneWidget);
    expect(await db.feedsDao.feedsOf(profile.id), isEmpty);
  });

  testWidgets('export writes an OPML that comms_core parses back to the '
      'same subscriptions', (tester) async {
    final feedId = await db.feedsDao.insertFeed(
      profileId: profile.id,
      url: 'https://cast.test/feed',
    );
    await db.feedsDao.updateRefreshState(
      feedId,
      title: 'The Night Sky Cast',
      etag: null,
      lastModified: null,
      breakerJson: '{}',
    );
    final saved = <(String, List<int>)>[];
    await pumpFeeds(
      tester,
      fetcher: ScriptedFetcher((u, h) => textResponse(_rss)),
      savedFiles: saved,
    );

    await tester.tap(find.byKey(const Key('opml-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export OPML'));
    await tester.pumpAndSettle();

    expect(saved, hasLength(1));
    expect(saved.single.$1, 'trellis-feeds.opml');
    final outlines = comms.parseOpml(utf8.decode(saved.single.$2));
    expect(outlines.single.url, 'https://cast.test/feed');
    expect(outlines.single.title, 'The Night Sky Cast');
  });

  testWidgets('unfollowing from the feeds screen removes the feed and its '
      'unpromoted ephemera; promoted works stay', (tester) async {
    final feedId = await db.feedsDao.insertFeed(
      profileId: profile.id,
      url: 'https://cast.test/feed',
    );
    // One passing ephemeron, one promoted keeper.
    final passing = await db.spineDao.insertWork(
      profileId: profile.id,
      kind: 'article',
      title: 'Passing item',
      persistence: 'ephemeron',
      firstSeenEpochDay: 100,
    );
    await db.feedsDao.insertEpisode(
      workId: passing,
      feedId: feedId,
      guid: 'a',
      publishedAtMs: 1,
    );
    final kept = await db.spineDao.insertWork(
      profileId: profile.id,
      kind: 'episode',
      title: 'Kept episode',
      persistence: 'ephemeron',
      firstSeenEpochDay: 100,
      sourceUrl: 'https://cast.test/kept.mp3',
    );
    await db.feedsDao.insertEpisode(
      workId: kept,
      feedId: feedId,
      guid: 'b',
      publishedAtMs: 2,
    );
    await db.spineDao.promoteWork(kept);

    await pumpFeeds(
      tester,
      fetcher: ScriptedFetcher((u, h) => textResponse(_rss)),
    );
    await tester.tap(find.byKey(Key('feed-menu-$feedId')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unfollow'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unfollow').last); // the dialog's confirm
    await tester.pumpAndSettle();

    expect(await db.feedsDao.feedsOf(profile.id), isEmpty);
    final titles = (await db.spineDao.worksOf(profile.id)).map((w) => w.title);
    expect(titles, ['Kept episode']);
  });

  testWidgets('a feed\'s podcast settings (speed, skip intro/outro) round-trip '
      'through the settings screen', (tester) async {
    final feedId = await db.feedsDao.insertFeed(
      profileId: profile.id,
      url: 'https://cast.test/feed',
    );
    await pumpFeeds(
      tester,
      fetcher: ScriptedFetcher((u, h) => textResponse(_rss)),
    );

    await tester.tap(find.byKey(Key('feed-menu-$feedId')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Podcast settings'));
    await tester.pumpAndSettle();

    expect(find.text('Playback settings'), findsOneWidget);

    await tester.tap(find.byKey(const Key('feed-settings-speed-1.5')));
    await tester.enterText(
      find.byKey(const Key('feed-settings-skip-intro')),
      '15',
    );
    await tester.enterText(
        find.byKey(const Key('feed-settings-skip-outro')), '30');
    await tester.ensureVisible(find.byKey(const Key('feed-settings-save')));
    await tester.tap(find.byKey(const Key('feed-settings-save')));
    await tester.pumpAndSettle();

    final feed = await db.feedsDao.feedById(feedId);
    expect(feed!.speedOverride, 1.5);
    expect(feed.skipIntroSeconds, 15);
    expect(feed.skipOutroSeconds, 30);
  });

  testWidgets('the settings screen shows what was already saved, and '
      '"Use app default" clears the speed override', (tester) async {
    final feedId = await db.feedsDao.insertFeed(
      profileId: profile.id,
      url: 'https://cast.test/feed',
    );
    await db.feedsDao.updatePlaybackSettings(
      feedId,
      speedOverride: 1.75,
      skipIntroSeconds: 10,
      skipOutroSeconds: 20,
    );
    await pumpFeeds(
      tester,
      fetcher: ScriptedFetcher((u, h) => textResponse(_rss)),
    );

    await tester.tap(find.byKey(Key('feed-menu-$feedId')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Podcast settings'));
    await tester.pumpAndSettle();

    expect(find.text('10'), findsOneWidget);
    expect(find.text('20'), findsOneWidget);

    await tester.tap(find.byKey(const Key('feed-settings-speed-default')));
    await tester.ensureVisible(find.byKey(const Key('feed-settings-save')));
    await tester.tap(find.byKey(const Key('feed-settings-save')));
    await tester.pumpAndSettle();

    final feed = await db.feedsDao.feedById(feedId);
    expect(feed!.speedOverride, isNull);
    expect(feed.skipIntroSeconds, 10, reason: 'untouched fields survive');
  });

  testWidgets(
    'keep-latest-N audio (P4 "archive, never forget") round-trips and '
    'defaults to "keep all"',
    (tester) async {
      final feedId = await db.feedsDao.insertFeed(
        profileId: profile.id,
        url: 'https://cast.test/feed',
      );
      await pumpFeeds(
        tester,
        fetcher: ScriptedFetcher((u, h) => textResponse(_rss)),
      );

      await tester.tap(find.byKey(Key('feed-menu-$feedId')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Podcast settings'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Keep the latest'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('feed-settings-keep-latest-audio')),
        '5',
      );
      await tester.ensureVisible(find.byKey(const Key('feed-settings-save')));
      await tester.tap(find.byKey(const Key('feed-settings-save')));
      await tester.pumpAndSettle();

      expect((await db.feedsDao.feedById(feedId))!.keepLatestAudio, 5);
    },
  );

  testWidgets(
    'the offline DSP setting (Campaign 6) defaults to "Use app default" '
    'and round-trips On/Off',
    (tester) async {
      final feedId = await db.feedsDao.insertFeed(
        profileId: profile.id,
        url: 'https://cast.test/feed',
      );
      await pumpFeeds(
        tester,
        fetcher: ScriptedFetcher((u, h) => textResponse(_rss)),
      );

      await tester.tap(find.byKey(Key('feed-menu-$feedId')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Podcast settings'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Trim silence'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('feed-settings-dsp-on')));
      await tester.tap(find.byKey(const Key('feed-settings-dsp-on')));
      await tester.ensureVisible(find.byKey(const Key('feed-settings-save')));
      await tester.tap(find.byKey(const Key('feed-settings-save')));
      await tester.pumpAndSettle();

      expect((await db.feedsDao.feedById(feedId))!.dspEnabled, isTrue);
    },
  );

  testWidgets('the offline DSP setting shows a saved Off choice, and "Use app '
      'default" clears it back to null', (tester) async {
    final feedId = await db.feedsDao.insertFeed(
      profileId: profile.id,
      url: 'https://cast.test/feed',
    );
    await db.feedsDao.updatePlaybackSettings(feedId, dspEnabled: false);
    await pumpFeeds(
      tester,
      fetcher: ScriptedFetcher((u, h) => textResponse(_rss)),
    );

    await tester.tap(find.byKey(Key('feed-menu-$feedId')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Podcast settings'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const Key('feed-settings-dsp-default')),
    );
    await tester.tap(find.byKey(const Key('feed-settings-dsp-default')));
    await tester.ensureVisible(find.byKey(const Key('feed-settings-save')));
    await tester.tap(find.byKey(const Key('feed-settings-save')));
    await tester.pumpAndSettle();

    expect((await db.feedsDao.feedById(feedId))!.dspEnabled, isNull);
  });

  group('the household DSP default (Campaign 6)', () {
    testWidgets(
        'starts unchecked (off), and tapping it flips the household '
        'default on', (tester) async {
      await pumpFeeds(tester,
          fetcher: ScriptedFetcher((u, h) => textResponse(_rss)));

      await tester.tap(find.byKey(const Key('opml-menu')));
      await tester.pumpAndSettle();
      final before = tester.widget<CheckedPopupMenuItem<String>>(
          find.byKey(const Key('dsp-global-default-toggle')));
      expect(before.checked, isFalse);

      await tester.tap(find.byKey(const Key('dsp-global-default-toggle')));
      await tester.pumpAndSettle();

      expect(await db.profilesDao.dspGlobalDefault(profile.id), isTrue);
    });

    testWidgets('shows checked once the household default is already on, '
        'and tapping it flips back off', (tester) async {
      await db.profilesDao.setDspGlobalDefault(profile.id, true);
      await pumpFeeds(tester,
          fetcher: ScriptedFetcher((u, h) => textResponse(_rss)));

      await tester.tap(find.byKey(const Key('opml-menu')));
      await tester.pumpAndSettle();
      final before = tester.widget<CheckedPopupMenuItem<String>>(
          find.byKey(const Key('dsp-global-default-toggle')));
      expect(before.checked, isTrue);

      await tester.tap(find.byKey(const Key('dsp-global-default-toggle')));
      await tester.pumpAndSettle();

      expect(await db.profilesDao.dspGlobalDefault(profile.id), isFalse);
    });
  });
}
