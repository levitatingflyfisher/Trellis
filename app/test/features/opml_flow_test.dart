import 'dart:async';
import 'dart:convert';

import 'package:comms_core/comms_core.dart' as comms;
import 'package:drift/drift.dart' show ApplyInterceptor;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/feeds/feeds_repository.dart';
import 'package:trellis/features/feeds/feeds_screen.dart';

import '../support/scripted_fetcher.dart';
import '../support/statement_counter.dart';

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

const _opmlThreeWithRepeat = '''
<?xml version="1.0" encoding="UTF-8"?>
<opml version="2.0">
  <head><title>subs</title></head>
  <body>
    <outline type="rss" text="Night Sky" xmlUrl="https://cast.test/feed"/>
    <outline type="rss" text="Second Cast" xmlUrl="https://second.test/feed"/>
    <outline type="rss" text="Night Sky again" xmlUrl=" https://cast.test/feed "/>
    <outline type="rss" text="Third Cast" xmlUrl="https://third.test/feed"/>
  </body>
</opml>
''';

/// A synthetic list of [n] made-up shows.
String _opmlOf(int n) => '''
<?xml version="1.0" encoding="UTF-8"?>
<opml version="2.0"><head><title>subs</title></head><body>
${[for (var i = 0; i < n; i++) '<outline type="rss" text="Show $i" xmlUrl="https://s$i.test/feed"/>'].join('\n')}
</body></opml>
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

  testWidgets('a file of shows all already followed says how many, and '
      'Show them lists just those', (tester) async {
    for (final (url, title) in [
      ('https://cast.test/feed', 'Night Sky'),
      ('https://second.test/feed', 'Second Cast'),
      ('https://other.test/feed', 'Not In The File'),
    ]) {
      await db.feedsDao
          .insertFeed(profileId: profile.id, url: url, title: title);
    }
    final fetcher = ScriptedFetcher((u, h) => textResponse(_rss));
    await pumpFeeds(tester,
        fetcher: fetcher, opmlToPick: utf8.encode(_opmlTwo));

    await tester.tap(find.byKey(const Key('opml-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import OPML'));
    await tester.pumpAndSettle();

    expect(find.text('Already following all 2.'), findsOneWidget);
    expect(fetcher.calls, isEmpty);
    await tester.tap(find.widgetWithText(SnackBarAction, 'Show them'));
    await tester.pumpAndSettle();
    expect(find.text('Night Sky'), findsOneWidget);
    expect(find.text('Second Cast'), findsOneWidget);
    expect(find.text('Not In The File'), findsNothing);
    final chip = find.byKey(const Key('from-file-chip'));
    expect(find.descendant(of: chip, matching: find.text('From that file 2')),
        findsOneWidget);
    // Letting the chip go brings every show back.
    await tester.tap(find.byTooltip('Show every show'));
    await tester.pumpAndSettle();
    expect(find.text('Not In The File'), findsOneWidget);
  });

  testWidgets('a file whose addresses are all blank says so, not "all 0"',
      (tester) async {
    await pumpFeeds(tester,
        fetcher: ScriptedFetcher((u, h) => textResponse(_rss)),
        opmlToPick: utf8.encode('<opml version="2.0"><body>'
            '<outline text="Nothing" xmlUrl="   "/></body></opml>'));
    await tester.tap(find.byKey(const Key('opml-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import OPML'));
    await tester.pumpAndSettle();
    expect(find.text('No feed URLs found in that file.'), findsOneWidget);
  });

  testWidgets('a long import lists every new feed at once, shows how far '
      'it has got, and counts the ones that could not be reached', (
    tester,
  ) async {
    final gates = <Completer<comms.FetchResponse>>[];
    final fetcher = ScriptedFetcher((u, h) {
      final gate = Completer<comms.FetchResponse>();
      gates.add(gate);
      return gate.future;
    });
    await pumpFeeds(
      tester,
      fetcher: fetcher,
      opmlToPick: utf8.encode(_opmlThreeWithRepeat),
    );

    await tester.tap(find.byKey(const Key('opml-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import OPML'));
    for (var i = 0; i < 50 && gates.length < 3; i++) {
      await tester.pump();
    }

    // All three rows are up before any fetch has answered.
    expect(find.text('Night Sky'), findsOneWidget);
    expect(find.text('Second Cast'), findsOneWidget);
    expect(find.text('Third Cast'), findsOneWidget);
    expect(find.text('Checking 1 of 3…'), findsOneWidget);

    gates[0].complete(textResponse(_rss));
    for (var i = 0; i < 50; i++) {
      await tester.pump();
      if (find.text('Checking 2 of 3…').evaluate().isNotEmpty) break;
    }
    expect(find.text('Checking 2 of 3…'), findsOneWidget);

    gates[1].complete(textResponse('', status: 500));
    gates[2].complete(textResponse('', status: 404));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('opml-import-progress')), findsNothing);
    expect(
      find.text('Following 3 new feeds. 2 couldn’t be reached; their rows '
          'say why.'),
      findsOneWidget,
    );
    expect(await db.feedsDao.feedsOf(profile.id), hasLength(3),
        reason: 'the repeated outline was followed once');
  });

  testWidgets('going to the background stops the import: what is in '
      'flight finishes, nothing new starts, and the toast says so', (
    tester,
  ) async {
    final gates = <Completer<comms.FetchResponse>>[];
    final fetcher = ScriptedFetcher((u, h) {
      final gate = Completer<comms.FetchResponse>();
      gates.add(gate);
      return gate.future;
    });
    await pumpFeeds(tester,
        fetcher: fetcher, opmlToPick: utf8.encode(_opmlOf(8)));
    await tester.tap(find.byKey(const Key('opml-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import OPML'));
    for (var i = 0; i < 50 && gates.length < 4; i++) {
      await tester.pump();
    }
    expect(gates, hasLength(4), reason: 'four at a time');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    for (final g in gates) {
      g.complete(textResponse(_rss));
    }
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(fetcher.calls, hasLength(4));
    expect(find.byKey(const Key('opml-import-progress')), findsNothing);
    expect(
        find.text('Following 8 new feeds. 4 aren’t checked yet; the next '
            'refresh checks them.'),
        findsOneWidget);
  });

  testWidgets('the system file picker hiding the app does not stop the '
      'import it is picking for', (tester) async {
    final fetcher = ScriptedFetcher((u, h) => textResponse(_rss));
    await tester.pumpWidget(MaterialApp(
        home: FeedsScreen(
            db: db,
            repository: FeedsRepository(db: db, fetcher: fetcher),
            profile: profile,
            // On Android the picker is its own activity: the app goes
            // to the background and back before the file arrives.
            pickOpmlBytes: () async {
              final b = tester.binding;
              b.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
              b.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
              b.handleAppLifecycleStateChanged(AppLifecycleState.paused);
              b.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
              b.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
              b.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
              return utf8.encode(_opmlOf(6));
            })));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('opml-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import OPML'));
    await tester.pumpAndSettle();
    expect(fetcher.calls, hasLength(6));
    expect(find.text('Following 6 new feeds.'), findsOneWidget);
  });

  testWidgets('leaving Subscriptions stops the import', (tester) async {
    final gates = <Completer<comms.FetchResponse>>[];
    final fetcher = ScriptedFetcher((u, h) {
      final gate = Completer<comms.FetchResponse>();
      gates.add(gate);
      return gate.future;
    });
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => FeedsScreen(
                            db: db,
                            repository:
                                FeedsRepository(db: db, fetcher: fetcher),
                            profile: profile,
                            pickOpmlBytes: () async =>
                                utf8.encode(_opmlOf(8))))),
                child: const Text('open')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('opml-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import OPML'));
    for (var i = 0; i < 50 && gates.length < 4; i++) {
      await tester.pump();
    }
    await tester.pageBack();
    await tester.pumpAndSettle();
    for (final g in gates) {
      g.complete(textResponse(_rss));
    }
    await tester.pumpAndSettle();
    expect(fetcher.calls, hasLength(4));
    expect(await db.feedsDao.feedsOf(profile.id), hasLength(8),
        reason: 'the follows themselves stay');
  });

  testWidgets('one unreachable feed gets the singular sentence', (
    tester,
  ) async {
    final fetcher = ScriptedFetcher((u, h) => u.host == 'second.test'
        ? textResponse('', status: 500)
        : textResponse(_rss));
    await pumpFeeds(
      tester,
      fetcher: fetcher,
      opmlToPick: utf8.encode(_opmlTwo),
    );

    await tester.tap(find.byKey(const Key('opml-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import OPML'));
    await tester.pumpAndSettle();

    expect(
      find.text('Following 2 new feeds. 1 couldn’t be reached; its row says '
          'why.'),
      findsOneWidget,
    );
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

    expect(find.text("That file isn’t an OPML podcast list Trellis can read."),
        findsOneWidget);
    expect(find.text('Invalid OPML file'), findsNothing);
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
    // Deliberate (a menu choice): no dialog; gone from the list, with a
    // lasting Undo, and nothing deleted until the offer is let go.
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('Unfollowed'), findsOneWidget);
    // Unfollow deletes every unkept item, read or not; the words say so.
    expect(find.textContaining("What you haven’t kept goes too"),
        findsOneWidget);
    expect(await db.feedsDao.feedsOf(profile.id), hasLength(1));
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.byKey(Key('feed-menu-$feedId')), findsOneWidget);

    await tester.tap(find.byKey(Key('feed-menu-$feedId')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unfollow'));
    await tester.pumpAndSettle();
    expect(find.byKey(Key('feed-menu-$feedId')), findsNothing);
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();

    expect(await db.feedsDao.feedsOf(profile.id), isEmpty);
    final titles = (await db.spineDao.worksOf(profile.id)).map((w) => w.title);
    expect(titles, ['Kept episode']);
  });

  testWidgets('leaving with an unfollow on offer finishes it before the '
      'screen behind reloads', (tester) async {
    final feedId = await db.feedsDao.insertFeed(
      profileId: profile.id,
      url: 'https://cast.test/feed',
    );
    late BuildContext home;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (c) {
        home = c;
        return const Text('inbox');
      }),
    ));
    // What Latest does: await the push, then reload at once.
    List<Feed>? seenOnReturn;
    unawaited(Navigator.of(home)
        .push(MaterialPageRoute<void>(
            builder: (_) => FeedsScreen(
                  db: db,
                  repository: FeedsRepository(
                      db: db,
                      fetcher: ScriptedFetcher((u, h) => textResponse(_rss))),
                  profile: profile,
                )))
        .then((_) async =>
            seenOnReturn = await db.feedsDao.feedsOf(profile.id)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('feed-menu-$feedId')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unfollow'));
    await tester.pumpAndSettle();

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('inbox'), findsOneWidget);
    expect(seenOnReturn, isEmpty,
        reason: 'the cascade ran before the pop, not after the reload');
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

  group('a big import', () {
    late StatementCounter counter;
    late AppDatabase big;
    late Profile reader;
    setUp(() async {
      counter = StatementCounter();
      big = AppDatabase.forTesting(
          NativeDatabase.memory().interceptWith(counter));
      await big.profilesDao.create('Ada');
      reader = (await big.profilesDao.all()).single;
    });
    tearDown(() => big.close());


    testWidgets('118 progress beats reload the list a handful of times, not '
        'once a beat', (tester) async {
      final repo = _BeatingRepository(big);
      await tester.pumpWidget(MaterialApp(
          home: FeedsScreen(
              db: big,
              repository: repo,
              profile: reader,
              // Synthetic: 118 made-up shows, the size of one listener's list.
              pickOpmlBytes: () async => utf8.encode(_opmlOf(118)))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('opml-menu')));
      await tester.pumpAndSettle();
      counter.calls.clear();
      await tester.tap(find.text('Import OPML'));
      for (var i = 0; i < 400 && repo.beats < 118; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      expect(repo.beats, 118);
      expect(find.text('Following 118 new feeds.'), findsOneWidget);
      // feedsOf, the list's own read (not the follow's per-URL checks).
      final reloads = counter.selectsMatching(
          RegExp(r'FROM "feeds" WHERE "profile_id" = \? ORDER BY'));
      expect(reloads, lessThanOrEqualTo(10), reason: '$reloads list reads');
      // No books, so the books' row facts are never read.
      expect(counter.selectsMatching('queue'), 0);
    });
  });
}

/// Follows for real, then reports 118 progress beats 20 ms apart without
/// fetching anything.
class _BeatingRepository extends FeedsRepository {
  _BeatingRepository(AppDatabase db)
      : super(db: db, fetcher: ScriptedFetcher((u, h) => textResponse('')));

  var beats = 0;

  @override
  Future<Map<int, RefreshOutcome>> refreshMany(List<Feed> feeds,
      {bool force = false,
      int maxConcurrent = 4,
      int maxPerHost = 2,
      void Function(int done, int total)? onProgress,
      bool Function()? shouldStop}) async {
    for (var i = 0; i < feeds.length; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      beats++;
      onProgress?.call(i + 1, feeds.length);
    }
    return {
      for (final f in feeds) f.id: (status: RefreshStatus.fresh, newItems: 0)
    };
  }
}
