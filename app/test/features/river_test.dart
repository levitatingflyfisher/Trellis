import 'dart:io';

import 'package:flutter/material.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/main.dart';
import 'package:trellis/services/device_services.dart';

import '../support/fake_player.dart';
import '../support/fake_services.dart';
import '../support/scripted_fetcher.dart';

const _rssOne = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel>
  <title>The Night Sky Cast</title>
  <item>
    <title>Aurora season</title>
    <link>https://cast.test/aurora</link>
    <pubDate>Wed, 05 Aug 2026 12:00:00 GMT</pubDate>
    <description>Lights in the north.</description>
    <enclosure url="https://cast.test/aurora.mp3" type="audio/mpeg"/>
  </item>
</channel></rss>
''';

const _rssTwo = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel>
  <title>The Night Sky Cast</title>
  <item>
    <title>Perseid peak tonight</title>
    <link>https://cast.test/perseids</link>
    <pubDate>Thu, 06 Aug 2026 12:00:00 GMT</pubDate>
    <description>Look northeast.</description>
  </item>
  <item>
    <title>Aurora season</title>
    <link>https://cast.test/aurora</link>
    <pubDate>Wed, 05 Aug 2026 12:00:00 GMT</pubDate>
    <description>Lights in the north.</description>
    <enclosure url="https://cast.test/aurora.mp3" type="audio/mpeg"/>
  </item>
</channel></rss>
''';

/// The River (ADR-0003 law 1): ONE reverse-chronological list across every
/// feed — no ranking code path exists to test, only ordering. Unread dots,
/// text/audio filters that never reorder, pull-to-refresh under the
/// breaker, and playback into the shell's persistent mini bar.
void main() {
  late AppDatabase db;
  late FakeEpisodePlayer player;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    player = FakeEpisodePlayer();
  });
  tearDown(() => db.close());

  Future<int> seedProfile() => db.profilesDao.create('Ada');

  Future<void> pumpApp(
    WidgetTester tester,
    ScriptedFetcher fetcher, {
    DeviceServices? services,
  }) async {
    await tester.pumpWidget(
      TrellisApp(
        db: db,
        fetcher: fetcher,
        createPlayer: () => player,
        services: services,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle();
  }

  Future<void> openRiver(WidgetTester tester) async {
    await tester.tap(find.text('River'));
    await tester.pumpAndSettle();
  }

  Future<int> seedRiverItem({
    required int profileId,
    required int feedId,
    required String title,
    required int publishedAtMs,
    String? enclosureUrl,
    String? guid,
    String desc = '',
  }) async {
    final workId = await db.spineDao.insertWork(
      profileId: profileId,
      kind: enclosureUrl != null ? 'episode' : 'article',
      title: title,
      persistence: 'ephemeron',
      firstSeenEpochDay:
          DateTime.now().toUtc().millisecondsSinceEpoch ~/
          Duration.millisecondsPerDay,
      sourceUrl: enclosureUrl,
    );
    if (desc.isNotEmpty) {
      await db.spineDao.insertSegments(workId, [
        (idx: 0, kind: 'prose', text: desc),
      ]);
    }
    await db.feedsDao.insertEpisode(
      workId: workId,
      feedId: feedId,
      guid: guid ?? 'guid-$title',
      enclosureUrl: enclosureUrl,
      publishedAtMs: publishedAtMs,
    );
    return workId;
  }

  testWidgets('an empty river is an invitation, and its button reaches the '
      'subscribe screen', (tester) async {
    await seedProfile();
    await pumpApp(tester, ScriptedFetcher((u, h) => textResponse(_rssOne)));
    await openRiver(tester);

    expect(find.text('The river is quiet.'), findsOneWidget);
    await tester.tap(find.text('Follow a feed'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('subscribe-url')), findsOneWidget);
  });

  testWidgets('items render newest-first across feeds — the DAO order, '
      'untouched', (tester) async {
    final profileId = await seedProfile();
    final feedA = await db.feedsDao.insertFeed(
      profileId: profileId,
      url: 'https://a/f',
    );
    final feedB = await db.feedsDao.insertFeed(
      profileId: profileId,
      url: 'https://b/f',
    );
    await seedRiverItem(
      profileId: profileId,
      feedId: feedA,
      title: 'Middle item',
      publishedAtMs: 2000,
    );
    await seedRiverItem(
      profileId: profileId,
      feedId: feedB,
      title: 'Newest item',
      publishedAtMs: 3000,
      enclosureUrl: 'https://b/1.mp3',
    );
    await seedRiverItem(
      profileId: profileId,
      feedId: feedA,
      title: 'Oldest item',
      publishedAtMs: 1000,
    );

    await pumpApp(tester, ScriptedFetcher((u, h) => textResponse(_rssOne)));
    await openRiver(tester);

    final newestY = tester.getTopLeft(find.text('Newest item')).dy;
    final middleY = tester.getTopLeft(find.text('Middle item')).dy;
    final oldestY = tester.getTopLeft(find.text('Oldest item')).dy;
    expect(newestY, lessThan(middleY));
    expect(middleY, lessThan(oldestY));
  });

  testWidgets('the text/audio chips filter without reordering', (tester) async {
    final profileId = await seedProfile();
    final feedId = await db.feedsDao.insertFeed(
      profileId: profileId,
      url: 'https://a/f',
    );
    await seedRiverItem(
      profileId: profileId,
      feedId: feedId,
      title: 'A text item',
      publishedAtMs: 2000,
    );
    await seedRiverItem(
      profileId: profileId,
      feedId: feedId,
      title: 'An audio item',
      publishedAtMs: 1000,
      enclosureUrl: 'https://a/1.mp3',
    );

    await pumpApp(tester, ScriptedFetcher((u, h) => textResponse(_rssOne)));
    await openRiver(tester);

    expect(find.text('A text item'), findsOneWidget);
    expect(find.text('An audio item'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chip-audio')));
    await tester.pumpAndSettle();
    expect(find.text('A text item'), findsNothing);
    expect(find.text('An audio item'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chip-text')));
    await tester.pumpAndSettle();
    expect(find.text('A text item'), findsOneWidget);
    expect(find.text('An audio item'), findsNothing);

    await tester.tap(find.byKey(const Key('chip-all')));
    await tester.pumpAndSettle();
    expect(find.text('A text item'), findsOneWidget);
    expect(find.text('An audio item'), findsOneWidget);
  });

  testWidgets('opening a text item reads its shownotes and clears the '
      'unread dot', (tester) async {
    final profileId = await seedProfile();
    final feedId = await db.feedsDao.insertFeed(
      profileId: profileId,
      url: 'https://a/f',
    );
    final workId = await seedRiverItem(
      profileId: profileId,
      feedId: feedId,
      title: 'A text item',
      publishedAtMs: 1000,
      desc: 'The shownotes body.',
    );

    await pumpApp(tester, ScriptedFetcher((u, h) => textResponse(_rssOne)));
    await openRiver(tester);

    expect(find.byKey(Key('unread-dot-$workId')), findsOneWidget);
    await tester.tap(find.text('A text item'));
    await tester.pumpAndSettle();

    // The reader opened on the spine work (RSVP shows the first word).
    expect(find.byKey(const Key('reader-tapzone')), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(
      find.byKey(Key('unread-dot-$workId')),
      findsNothing,
      reason: 'opening marked it read',
    );
  });

  testWidgets('pull-to-refresh runs a conditional GET, honours the breaker, '
      'and lands new items', (tester) async {
    final profileId = await seedProfile();
    // A live feed with stored validators…
    final liveId = await db.feedsDao.insertFeed(
      profileId: profileId,
      url: 'https://cast.test/feed',
    );
    await db.feedsDao.updateRefreshState(
      liveId,
      title: 'The Night Sky Cast',
      etag: '"v1"',
      lastModified: null,
      breakerJson: '{}',
    );
    // …whose aurora episode is already known (guid = the item link, the
    // same identity ingest derives).
    await seedRiverItem(
      profileId: profileId,
      feedId: liveId,
      title: 'Aurora season',
      publishedAtMs: 1000,
      enclosureUrl: 'https://cast.test/aurora.mp3',
      guid: 'https://cast.test/aurora',
    );
    // And a broken feed the breaker must skip.
    await db.feedsDao.updateRefreshState(
      await db.feedsDao.insertFeed(
        profileId: profileId,
        url: 'https://dead.test/feed',
      ),
      title: 'Dead',
      etag: null,
      lastModified: null,
      breakerJson: '{"broken":true}',
    );

    final fetcher = ScriptedFetcher((u, h) => textResponse(_rssTwo));
    await pumpApp(tester, fetcher);
    await openRiver(tester);

    await tester.fling(find.byType(ListView).last, const Offset(0, 300), 1000);
    await tester.pumpAndSettle();

    // The new item arrived; the known one was deduped, not duplicated.
    expect(find.text('Perseid peak tonight'), findsOneWidget);
    expect(find.text('Aurora season'), findsOneWidget);

    // Exactly one fetch — the live feed, conditionally; never the broken one.
    final call = fetcher.calls.single;
    expect(call.url.host, 'cast.test');
    expect(call.headers?['If-None-Match'], '"v1"');
  });

  testWidgets('the play button starts the episode and the mini bar '
      'persists across tabs', (tester) async {
    final profileId = await seedProfile();
    final feedId = await db.feedsDao.insertFeed(
      profileId: profileId,
      url: 'https://a/f',
    );
    final workId = await seedRiverItem(
      profileId: profileId,
      feedId: feedId,
      title: 'An audio item',
      publishedAtMs: 1000,
      enclosureUrl: 'https://a/1.mp3',
    );

    await pumpApp(tester, ScriptedFetcher((u, h) => textResponse(_rssOne)));
    await openRiver(tester);

    await tester.tap(find.byKey(Key('play-$workId')));
    await tester.pumpAndSettle();

    expect(player.playing, isTrue);
    expect(player.loadedUrl, 'https://a/1.mp3');
    expect(find.byKey(const Key('mini-player')), findsOneWidget);

    // The bar lives in the shell: still there on the Library tab.
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mini-player')), findsOneWidget);
  });

  testWidgets('Play next queues an episode — available whether or not '
      'local ML is', (tester) async {
    final profileId = await seedProfile();
    final feedId = await db.feedsDao.insertFeed(
      profileId: profileId,
      url: 'https://a/f',
    );
    final workId = await seedRiverItem(
      profileId: profileId,
      feedId: feedId,
      title: 'An audio item',
      publishedAtMs: 1000,
      enclosureUrl: 'https://a/1.mp3',
    );

    await pumpApp(tester, ScriptedFetcher((u, h) => textResponse(_rssOne)));
    await openRiver(tester);

    await tester.tap(find.byKey(Key('menu-$workId')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play next'));
    await tester.pumpAndSettle();

    final queue = await db.queueDao.queueOf(profileId);
    expect(queue.map((r) => r.workId), [workId]);
  });

  testWidgets(
    'an archived episode (P4 "archive, never forget") shows dimmed with '
    'a re-download affordance; the row survives',
    (tester) async {
      final profileId = await seedProfile();
      final feedId = await db.feedsDao.insertFeed(
        profileId: profileId,
        url: 'https://a/f',
      );
      final workId = await seedRiverItem(
        profileId: profileId,
        feedId: feedId,
        title: 'An archived episode',
        publishedAtMs: 1000,
        enclosureUrl: 'https://a/1.mp3',
      );
      await db.feedsDao.setArchived(workId, 999);

      await pumpApp(tester, ScriptedFetcher((u, h) => textResponse(_rssOne)));
      await openRiver(tester);

      expect(
        find.text('An archived episode'),
        findsOneWidget,
        reason: 'the row survives — only the audio went',
      );
      final opacity = tester.widget<Opacity>(
        find.byKey(Key('archived-$workId')),
      );
      expect(opacity.opacity, lessThan(1.0));

      await tester.tap(find.byKey(Key('menu-$workId')));
      await tester.pumpAndSettle();
      expect(find.text('Re-download audio'), findsOneWidget);
    },
  );

  testWidgets('a non-archived episode is never dimmed and offers no '
      're-download item', (tester) async {
    final profileId = await seedProfile();
    final feedId = await db.feedsDao.insertFeed(
      profileId: profileId,
      url: 'https://a/f',
    );
    final workId = await seedRiverItem(
      profileId: profileId,
      feedId: feedId,
      title: 'A normal episode',
      publishedAtMs: 1000,
      enclosureUrl: 'https://a/1.mp3',
    );

    await pumpApp(tester, ScriptedFetcher((u, h) => textResponse(_rssOne)));
    await openRiver(tester);

    expect(find.byKey(Key('archived-$workId')), findsNothing);
    await tester.tap(find.byKey(Key('menu-$workId')));
    await tester.pumpAndSettle();
    expect(find.text('Re-download audio'), findsNothing);
  });

  testWidgets('Play last appends behind whatever is already queued', (
    tester,
  ) async {
    final profileId = await seedProfile();
    final feedId = await db.feedsDao.insertFeed(
      profileId: profileId,
      url: 'https://a/f',
    );
    final first = await seedRiverItem(
      profileId: profileId,
      feedId: feedId,
      title: 'First',
      publishedAtMs: 2000,
      enclosureUrl: 'https://a/1.mp3',
    );
    final second = await seedRiverItem(
      profileId: profileId,
      feedId: feedId,
      title: 'Second',
      publishedAtMs: 1000,
      enclosureUrl: 'https://a/2.mp3',
    );

    await pumpApp(tester, ScriptedFetcher((u, h) => textResponse(_rssOne)));
    await openRiver(tester);

    await tester.tap(find.byKey(Key('menu-$first')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play last'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('menu-$second')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play last'));
    await tester.pumpAndSettle();

    final queue = await db.queueDao.queueOf(profileId);
    expect(queue.map((r) => r.workId), [first, second]);
  });

  group('triage verbs (Campaign 5: Keep / Let it pass)', () {
    testWidgets('swiping right Keeps a text item — promoted, read, undo '
        'restores verbatim', (tester) async {
      final profileId = await seedProfile();
      final feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://a/f');
      final workId = await seedRiverItem(
          profileId: profileId,
          feedId: feedId,
          title: 'A text item',
          publishedAtMs: 1000);

      await pumpApp(tester, ScriptedFetcher((u, h) => textResponse(_rssOne)));
      await openRiver(tester);

      expect(find.byKey(Key('unread-dot-$workId')), findsOneWidget);
      await tester.drag(
          find.byKey(Key('swipe-$workId')), const Offset(500, 0));
      await tester.pumpAndSettle();

      // The tile survives the swipe (dimmed rows, not vanished rows, is
      // this house's idiom) — only its state changed.
      expect(find.text('A text item'), findsOneWidget);
      expect(find.byKey(Key('unread-dot-$workId')), findsNothing);
      var work = await db.spineDao.workById(workId);
      expect(work!.persistence, 'work');
      expect(find.text('Kept — now in your library'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(find.byKey(Key('unread-dot-$workId')), findsOneWidget);
      work = await db.spineDao.workById(workId);
      expect(work!.persistence, 'ephemeron');
    });

    testWidgets('swiping left lets a text item pass — read, never '
        'promoted, undo restores', (tester) async {
      final profileId = await seedProfile();
      final feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://a/f');
      final workId = await seedRiverItem(
          profileId: profileId,
          feedId: feedId,
          title: 'A text item',
          publishedAtMs: 1000);

      await pumpApp(tester, ScriptedFetcher((u, h) => textResponse(_rssOne)));
      await openRiver(tester);

      await tester.drag(
          find.byKey(Key('swipe-$workId')), const Offset(-500, 0));
      await tester.pumpAndSettle();

      expect(find.byKey(Key('unread-dot-$workId')), findsNothing);
      var work = await db.spineDao.workById(workId);
      expect(work!.persistence, 'ephemeron',
          reason: 'let it pass never promotes');
      expect(find.text('Marked read'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(find.byKey(Key('unread-dot-$workId')), findsOneWidget);
    });

    testWidgets('overflow parity: a text (non-audio) row offers Keep and '
        'Let it pass from its menu too, not swipe-only', (tester) async {
      final profileId = await seedProfile();
      final feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://a/f');
      final workId = await seedRiverItem(
          profileId: profileId,
          feedId: feedId,
          title: 'A text item',
          publishedAtMs: 1000);

      await pumpApp(tester, ScriptedFetcher((u, h) => textResponse(_rssOne)));
      await openRiver(tester);

      expect(find.byKey(Key('menu-$workId')), findsOneWidget,
          reason: 'text rows had no menu at all before this campaign');
      await tester.tap(find.byKey(Key('menu-$workId')));
      await tester.pumpAndSettle();
      expect(find.text('Keep'), findsOneWidget);
      expect(find.text('Let it pass'), findsOneWidget);

      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();

      final work = await db.spineDao.workById(workId);
      expect(work!.persistence, 'work');
    });

    testWidgets('overflow parity: an audio row keeps its play/queue/'
        'transcribe items AND now offers Keep / Let it pass', (tester) async {
      final profileId = await seedProfile();
      final feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://a/f');
      final workId = await seedRiverItem(
          profileId: profileId,
          feedId: feedId,
          title: 'An audio item',
          publishedAtMs: 1000,
          enclosureUrl: 'https://a/1.mp3');

      await pumpApp(tester, ScriptedFetcher((u, h) => textResponse(_rssOne)));
      await openRiver(tester);

      await tester.tap(find.byKey(Key('menu-$workId')));
      await tester.pumpAndSettle();
      expect(find.text('Keep'), findsOneWidget);
      expect(find.text('Let it pass'), findsOneWidget);
      expect(find.text('Play next'), findsOneWidget);
      expect(find.text('Play last'), findsOneWidget);
    });
  });

  group('download (Campaign 6) — the door onto disk that is not '
      'transcription', () {
    late Directory dir;
    late FakeAudioFetcher fetcher;
    late DeviceServices services;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('trellis-river-dl');
      fetcher = FakeAudioFetcher();
      services = testServices(dir, audioFetcher: fetcher);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    testWidgets('Download opens the one consent dialog; confirming fetches the '
        'audio and the row gains the quiet downloaded indicator', (
      tester,
    ) async {
      final profileId = await seedProfile();
      final feedId = await db.feedsDao.insertFeed(
        profileId: profileId,
        url: 'https://a/f',
      );
      final workId = await seedRiverItem(
        profileId: profileId,
        feedId: feedId,
        title: 'An audio item',
        publishedAtMs: 1000,
        enclosureUrl: 'https://a/1.mp3',
      );

      await pumpApp(
        tester,
        ScriptedFetcher((u, h) => textResponse(_rssOne)),
        services: services,
      );
      await openRiver(tester);
      expect(find.byKey(Key('downloaded-$workId')), findsNothing);

      await tester.tap(find.byKey(Key('menu-$workId')));
      await tester.pumpAndSettle();
      expect(find.text('Download'), findsOneWidget);
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('consent-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('consent-accept')));
      await tester.pumpAndSettle();

      expect(fetcher.fetched, ['https://a/1.mp3']);
      expect(find.byKey(Key('downloaded-$workId')), findsOneWidget);
    });

    testWidgets('cancelling the consent dialog downloads nothing', (
      tester,
    ) async {
      final profileId = await seedProfile();
      final feedId = await db.feedsDao.insertFeed(
        profileId: profileId,
        url: 'https://a/f',
      );
      final workId = await seedRiverItem(
        profileId: profileId,
        feedId: feedId,
        title: 'An audio item',
        publishedAtMs: 1000,
        enclosureUrl: 'https://a/1.mp3',
      );

      await pumpApp(
        tester,
        ScriptedFetcher((u, h) => textResponse(_rssOne)),
        services: services,
      );
      await openRiver(tester);

      await tester.tap(find.byKey(Key('menu-$workId')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('consent-cancel')));
      await tester.pumpAndSettle();

      expect(fetcher.fetched, isEmpty);
      expect(find.byKey(Key('downloaded-$workId')), findsNothing);
    });

    testWidgets(
      'an episode already on disk shows the indicator on open and never '
      'offers Download again',
      (tester) async {
        final profileId = await seedProfile();
        final feedId = await db.feedsDao.insertFeed(
          profileId: profileId,
          url: 'https://a/f',
        );
        final workId = await seedRiverItem(
          profileId: profileId,
          feedId: feedId,
          title: 'An audio item',
          publishedAtMs: 1000,
          enclosureUrl: 'https://a/1.mp3',
        );
        final target = services.audioFileFor(workId, 'https://a/1.mp3');
        target.parent.createSync(recursive: true);
        target.writeAsBytesSync([1, 2, 3]);

        await pumpApp(
          tester,
          ScriptedFetcher((u, h) => textResponse(_rssOne)),
          services: services,
        );
        await openRiver(tester);

        expect(find.byKey(Key('downloaded-$workId')), findsOneWidget);
        await tester.tap(find.byKey(Key('menu-$workId')));
        await tester.pumpAndSettle();
        expect(find.text('Download'), findsNothing);
      },
    );

    group('the offline DSP preprocess composes with Download', () {
      testWidgets(
        'a feed with DSP enabled: downloading also processes the audio',
        (tester) async {
          final encoder = FakeDspEncoder();
          final dspServices = testServices(
            dir,
            audioFetcher: fetcher,
            dspEncoder: encoder,
          );
          final profileId = await seedProfile();
          final feedId = await db.feedsDao.insertFeed(
            profileId: profileId,
            url: 'https://a/f',
          );
          await db.feedsDao.updatePlaybackSettings(feedId, dspEnabled: true);
          final workId = await seedRiverItem(
            profileId: profileId,
            feedId: feedId,
            title: 'An audio item',
            publishedAtMs: 1000,
            enclosureUrl: 'https://a/1.mp3',
          );

          await pumpApp(
            tester,
            ScriptedFetcher((u, h) => textResponse(_rssOne)),
            services: dspServices,
          );
          await openRiver(tester);

          await tester.tap(find.byKey(Key('menu-$workId')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Download'));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('consent-accept')));
          await tester.pumpAndSettle();

          final audio = dspServices.audioFileFor(workId, 'https://a/1.mp3');
          expect(encoder.processedInputs, [audio.path]);
          final episode = await db.feedsDao.episodeOf(workId);
          expect(episode?.dspProcessedDurationMs, isNotNull);
        },
      );

      testWidgets(
        'a feed with DSP left at the default (off): downloading never '
        'processes',
        (tester) async {
          final encoder = FakeDspEncoder();
          final dspServices = testServices(
            dir,
            audioFetcher: fetcher,
            dspEncoder: encoder,
          );
          final profileId = await seedProfile();
          final feedId = await db.feedsDao.insertFeed(
            profileId: profileId,
            url: 'https://a/f',
          );
          final workId = await seedRiverItem(
            profileId: profileId,
            feedId: feedId,
            title: 'An audio item',
            publishedAtMs: 1000,
            enclosureUrl: 'https://a/1.mp3',
          );

          await pumpApp(
            tester,
            ScriptedFetcher((u, h) => textResponse(_rssOne)),
            services: dspServices,
          );
          await openRiver(tester);

          await tester.tap(find.byKey(Key('menu-$workId')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Download'));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('consent-accept')));
          await tester.pumpAndSettle();

          expect(encoder.processedInputs, isEmpty);
        },
      );
    });
  });
}
