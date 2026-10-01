import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jobs_core/jobs_core.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/episodes/episode_actions.dart';
import 'package:trellis/features/feeds/episode_download_coordinator.dart';
import 'package:trellis/features/feeds/feed_detail_screen.dart';
import 'package:trellis/features/feeds/feeds_repository.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/search/search_screen.dart';
import 'package:trellis/features/search/search_store.dart';
import 'package:trellis/main.dart';
import 'package:trellis/services/device_services.dart';

import '../../support/fake_player.dart';
import '../../support/fake_services.dart';
import '../../support/pick_reader.dart';
import '../../support/scripted_fetcher.dart';

/// The clean-up (ADR-0016 section 5): multi-select on every episode list,
/// bulk actions with a lasting Undo, and "Mark everything older as
/// played". Bulk marking never reaches History, and nothing counts what
/// was left unplayed.
void main() {
  late AppDatabase db;
  late int profileId;
  late FakeEpisodePlayer player;
  late PlayerController controller;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
    player = FakeEpisodePlayer();
    controller = PlayerController(
        db: db, profileId: profileId, createPlayer: () => player);
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
  });

  Future<int> seedFeed() async {
    final id = await db.feedsDao
        .insertFeed(profileId: profileId, url: 'https://cast.test/feed');
    await db.feedsDao.updateRefreshState(id,
        title: 'Night Sky',
        etag: null,
        lastModified: null,
        breakerJson: '{}',
        nextPageUrl: null,
        updateNextPageUrl: true);
    return id;
  }

  Future<int> seedEpisode(int feedId, String title, int publishedAtMs,
      {bool audio = true}) async {
    final url = audio ? 'https://cast.test/$publishedAtMs-$title.mp3' : null;
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: audio ? 'episode' : 'article',
        title: title,
        persistence: 'ephemeron',
        firstSeenEpochDay: DateTime.now().toUtc().millisecondsSinceEpoch ~/
            Duration.millisecondsPerDay,
        sourceUrl: url);
    await db.feedsDao.insertEpisode(
        workId: id,
        feedId: feedId,
        guid: 'g-$title',
        enclosureUrl: url,
        publishedAtMs: publishedAtMs);
    return id;
  }

  Future<Episode> ep(int id) async => (await db.feedsDao.episodeOf(id))!;

  Finder bar(String text) => find.descendant(
      of: find.byKey(const Key('selection-bar')), matching: find.text(text));

  Finder tileOf(String title) => find
      .ancestor(of: find.text(title), matching: find.byType(ListTile))
      .first;

  group('the podcast page', () {
    late int feedId;
    late Map<String, int> ids;
    Directory? dir;
    DeviceServices? services;
    EpisodeDownloadCoordinator? downloads;

    setUp(() async {
      feedId = await seedFeed();
      ids = {};
      // Published one after another; "Tie" shares Dawn's moment.
      for (final (t, at) in [
        ('Alpha', 1000),
        ('Bravo', 2000),
        ('Dawn', 3000),
        ('Tie', 3000),
        ('Echo', 4000),
      ]) {
        ids[t] = await seedEpisode(feedId, t, at);
      }
    });
    tearDown(() {
      downloads?.dispose();
      downloads = null;
      services = null;
      dir?.deleteSync(recursive: true);
      dir = null;
    });

    void withDownloads() {
      dir = Directory.systemTemp.createTempSync('trellis-cleanup');
      services = testServices(dir!);
      downloads = EpisodeDownloadCoordinator(services: services!, db: db);
    }

    Future<void> pumpPage(WidgetTester tester) async {
      final feed = (await db.feedsDao.feedById(feedId))!;
      await tester.pumpWidget(MaterialApp(
          home: FeedDetailScreen(
              db: db,
              repository: FeedsRepository(
                  db: db,
                  fetcher: ScriptedFetcher((u, h) => textResponse('')),
                  services: services),
              feed: feed,
              playerController: controller,
              downloadCoordinator: downloads)));
      await tester.pumpAndSettle();
    }

    Future<void> longPress(WidgetTester tester, String title) async {
      await tester.longPress(find.text(title));
      await tester.pumpAndSettle();
    }

    Future<void> select(WidgetTester tester, List<String> titles) async {
      await longPress(tester, titles.first);
      for (final t in titles.skip(1)) {
        await tester.tap(find.text(t));
        await tester.pumpAndSettle();
      }
    }

    Future<void> undo(WidgetTester tester) async {
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
    }

    testWidgets('long-press selects, tap toggles, and the state is announced',
        (tester) async {
      await pumpPage(tester);
      expect(find.byKey(const Key('selection-bar')), findsNothing);

      await longPress(tester, 'Echo');
      expect(bar('1 selected'), findsOneWidget);
      expect(find.byKey(Key('play-${ids['Echo']}')), findsNothing,
          reason: 'a tap selects now; play would surprise');
      expect(tester.getSemantics(tileOf('Echo')),
          containsSemantics(isSelected: true));
      expect(tester.getSemantics(tileOf('Alpha')),
          containsSemantics(isSelected: false));
      expect(tester.widget<Checkbox>(find.byKey(Key('select-${ids['Echo']}')))
          .value, isTrue);

      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      expect(bar('2 selected'), findsOneWidget);
      await tester.tap(find.text('Echo'));
      await tester.pumpAndSettle();
      expect(bar('1 selected'), findsOneWidget);
      expect(player.loadedUrl, isNull);
    });

    testWidgets('Back and Escape leave selection, not the screen',
        (tester) async {
      await pumpPage(tester);
      await longPress(tester, 'Echo');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('selection-bar')), findsNothing);

      await longPress(tester, 'Echo');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('selection-bar')), findsNothing);
      expect(find.byType(FeedDetailScreen), findsOneWidget);
    });

    testWidgets('Select in the bar works without a long-press, and Select '
        'all takes every row', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.byKey(const Key('podcast-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('podcast-select')));
      await tester.pumpAndSettle();
      expect(bar('Select episodes'), findsOneWidget);

      await tester.tap(find.byKey(const Key('selection-all')));
      await tester.pumpAndSettle();
      expect(bar('5 selected'), findsOneWidget);
    });

    testWidgets('Mark played, then Undo puts back exactly what was there',
        (tester) async {
      await db.feedsDao.setReadAt(ids['Bravo']!, 5);
      await pumpPage(tester);
      await select(tester, ['Alpha', 'Bravo']);
      await tester.tap(find.byKey(const Key('bulk-mark-played')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('selection-bar')), findsNothing);
      expect(find.byKey(Key('played-${ids['Alpha']}')), findsOneWidget);
      expect(find.byKey(Key('played-${ids['Bravo']}')), findsOneWidget);
      expect(find.text('Marked 2 episodes played'), findsOneWidget);
      expect(await SearchStore(db).history(profileId), isEmpty,
          reason: 'History is what was actually listened to');

      await undo(tester);
      expect(find.byKey(Key('played-${ids['Alpha']}')), findsNothing);
      expect((await ep(ids['Alpha']!)).finishedAtMs, isNull);
      expect((await ep(ids['Alpha']!)).readAtMs, isNull);
      expect((await ep(ids['Bravo']!)).readAtMs, 5);
    });

    testWidgets('Mark unplayed, then Undo restores the played day and place',
        (tester) async {
      await db.feedsDao.markPlayed(ids['Echo']!, 7);
      await db.feedsDao.savePlayerPosition(
          profileId: profileId, workId: ids['Echo']!, tMs: 60000);
      await pumpPage(tester);
      await select(tester, ['Echo']);
      await more(tester, const Key('bulk-mark-unplayed'));
      expect((await ep(ids['Echo']!)).finishedAtMs, isNull);
      expect(find.text('Marked 1 episode unplayed'), findsOneWidget);

      await undo(tester);
      expect((await ep(ids['Echo']!)).finishedAtMs, 7);
      expect(
          (await db.feedsDao.allPlayerPositions()).single.tMs, 60000);
    });

    testWidgets('Mark unplayed on a half-heard episode offers Undo, which '
        'brings its place back', (tester) async {
      await db.feedsDao.savePlayerPosition(
          profileId: profileId, workId: ids['Dawn']!, tMs: 30000);
      await pumpPage(tester);
      await select(tester, ['Dawn']);
      await more(tester, const Key('bulk-mark-unplayed'));
      expect(await db.feedsDao.allPlayerPositions(), isEmpty);
      expect(find.text('Marked 1 episode unplayed'), findsOneWidget);
      await undo(tester);
      expect((await db.feedsDao.allPlayerPositions()).single.tMs, 30000);
    });

    testWidgets('Let it pass, then Undo', (tester) async {
      await pumpPage(tester);
      await select(tester, ['Alpha', 'Echo']);
      await more(tester, const Key('bulk-let-pass'));
      expect((await ep(ids['Alpha']!)).readAtMs, isNotNull);
      expect(find.text('Let 2 items pass'), findsOneWidget);
      await undo(tester);
      expect((await ep(ids['Alpha']!)).readAtMs, isNull);
      expect((await ep(ids['Echo']!)).readAtMs, isNull);
    });

    testWidgets('Add to Up Next, then Undo takes out only what it added',
        (tester) async {
      await db.queueDao
          .playLast(profileId: profileId, workId: ids['Dawn']!, nowMs: 1);
      await pumpPage(tester);
      await select(tester, ['Echo', 'Dawn']);
      await more(tester, const Key('bulk-up-next'));
      expect([for (final r in await db.queueDao.queueOf(profileId)) r.workId],
          [ids['Dawn'], ids['Echo']]);
      expect(find.text('Added 1 episode to Up Next'), findsOneWidget);
      expect(player.loadedUrl, isNull, reason: 'queueing never plays');

      await undo(tester);
      expect([for (final r in await db.queueDao.queueOf(profileId)) r.workId],
          [ids['Dawn']]);
    });

    testWidgets('Remove download deletes the files and says it can’t be '
        'undone by offering none', (tester) async {
      withDownloads();
      final e = await ep(ids['Echo']!);
      final file = services!.audioFileFor(e.workId, e.enclosureUrl!)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);
      await pumpPage(tester);
      expect(find.byKey(Key('downloaded-${ids['Echo']}')), findsOneWidget);

      await select(tester, ['Echo', 'Alpha']);
      await more(tester, const Key('bulk-remove-download'));
      expect(file.existsSync(), isFalse);
      expect(find.text('Removed 1 download. You can download again any time.'),
          findsOneWidget);
      expect(find.text('Undo'), findsNothing);
      expect(find.byKey(Key('downloaded-${ids['Echo']}')), findsNothing);
      expect((await ep(ids['Echo']!)).archivedAtMs, isNull,
          reason: 'removing a file says nothing about listening');
    });

    testWidgets('Remove download keeps the playing episode’s file and says '
        'so', (tester) async {
      withDownloads();
      final e = await ep(ids['Echo']!);
      final file = services!.audioFileFor(e.workId, e.enclosureUrl!)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);
      await pumpPage(tester);
      await tester.tap(find.byKey(Key('play-${ids['Echo']}')));
      await tester.pumpAndSettle();
      await select(tester, ['Echo']);
      await more(tester, const Key('bulk-remove-download'));
      expect(file.existsSync(), isTrue);
      expect(
          find.text('Nothing removed. The episode playing, transcribing or '
              'processing keeps its download.'),
          findsOneWidget);
    });

    Future<void> seedJob(String id, String kind, int workId,
        {String url = 'u'}) async {
      await db.jobsDao.save(Job(
          id: id,
          kind: kind,
          state: JobState.cancelled,
          checkpoint: null,
          totalUnits: 0,
          doneUnits: 0,
          createdAtMs: 1));
      await db.jobsDao.setPayload(
          id, jsonEncode({'workId': workId, 'title': 't', 'url': url}));
    }

    for (final kind in ['transcribe', 'dsp']) {
      testWidgets('Remove download keeps the file of an episode with a '
          '$kind job, and says so', (tester) async {
        withDownloads();
        File fileOf(Episode e) => services!.audioFileFor(e.workId, e.enclosureUrl!)
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync([1, 2, 3]);
        final busy = fileOf(await ep(ids['Echo']!));
        final free = fileOf(await ep(ids['Alpha']!));
        await seedJob('$kind-${ids['Echo']}', kind, ids['Echo']!);
        await pumpPage(tester);
        await select(tester, ['Echo', 'Alpha']);
        await more(tester, const Key('bulk-remove-download'));
        expect(busy.existsSync(), isTrue);
        expect(free.existsSync(), isFalse);
        expect(
            find.text('Removed 1 download. You can download again any time. '
                'The episode playing, transcribing or processing keeps its '
                'download.'),
            findsOneWidget);
      });
    }

    testWidgets('Remove download on an unfinished download stops it and '
        'says it stopped, not removed', (tester) async {
      withDownloads();
      final e = await ep(ids['Echo']!);
      await seedJob(downloadJobId(e.workId), 'download', e.workId,
          url: e.enclosureUrl!);
      await downloads!.restore();
      await pumpPage(tester);
      await select(tester, ['Echo']);
      await more(tester, const Key('bulk-remove-download'));
      expect(downloads!.entries, isEmpty);
      expect(await db.jobsDao.unfinished(), isEmpty);
      expect(
          find.text('Stopped 1 download in progress. You can download again '
              'any time.'),
          findsOneWidget);
    });

    testWidgets('a failed write keeps the selection and offers no Undo',
        (tester) async {
      await db.customStatement('CREATE TRIGGER no_writes BEFORE UPDATE ON '
          "episodes BEGIN SELECT RAISE(ABORT, 'disk said no'); END");
      await pumpPage(tester);
      await select(tester, ['Alpha', 'Echo']);
      await tester.tap(find.byKey(const Key('bulk-mark-played')));
      await tester.pumpAndSettle();
      expect(find.text('Couldn’t change these episodes. Nothing was changed.'),
          findsOneWidget);
      expect(bar('2 selected'), findsOneWidget);
      expect(find.text('Undo'), findsNothing);
      expect((await ep(ids['Alpha']!)).finishedAtMs, isNull);
    });

    testWidgets('Add to Up Next queues oldest to newest, whatever the sort',
        (tester) async {
      await pumpPage(tester);
      await select(tester, ['Echo', 'Alpha', 'Bravo']);
      await more(tester, const Key('bulk-up-next'));
      expect([for (final r in await db.queueDao.queueOf(profileId)) r.workId],
          [ids['Alpha'], ids['Bravo'], ids['Echo']]);
    });

    Future<void> markOlder(WidgetTester tester, String title) async {
      await tester.tap(find.byKey(Key('menu-${ids[title]}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('mark-older-${ids[title]}')));
      await tester.pumpAndSettle();
    }

    for (final oldestFirst in [false, true]) {
      testWidgets(
          'Mark everything older as played counts by publish date '
          '(${oldestFirst ? 'oldest' : 'newest'} first), skips ties and '
          'played ones, and undoes', (tester) async {
        await db.feedsDao.setSortOldestFirst(feedId, oldestFirst);
        await db.feedsDao.markPlayed(ids['Alpha']!, 7);
        await pumpPage(tester);
        await markOlder(tester, 'Dawn');

        expect(find.text('Mark 1 older episode as played?'), findsOneWidget,
            reason: 'Bravo only: Alpha is played, Tie is not older');
        await tester.tap(find.text('Mark 1 played'));
        await tester.pumpAndSettle();
        expect((await ep(ids['Bravo']!)).finishedAtMs, isNotNull);
        expect((await ep(ids['Tie']!)).finishedAtMs, isNull);
        expect((await ep(ids['Echo']!)).finishedAtMs, isNull);
        expect(await SearchStore(db).history(profileId), isEmpty);

        await undo(tester);
        expect((await ep(ids['Bravo']!)).finishedAtMs, isNull);
        expect((await ep(ids['Alpha']!)).finishedAtMs, 7);
      });
    }

    testWidgets('Cancel marks nothing, and the oldest row has no such item',
        (tester) async {
      await pumpPage(tester);
      await markOlder(tester, 'Echo');
      expect(find.text('Mark 4 older episodes as played?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect((await ep(ids['Alpha']!)).finishedAtMs, isNull);

      await tester.tap(find.byKey(Key('menu-${ids['Alpha']}')));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('mark-older-${ids['Alpha']}')), findsNothing);
    });

    testWidgets('selection holds at 360 dp and 2x text', (tester) async {
      tester.view.physicalSize = const Size(360, 720);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      await pumpPage(tester);
      await longPress(tester, 'Echo');
      expect(tester.takeException(), isNull);
      expect(bar('1 selected'), findsOneWidget);
      await tester.tap(find.byKey(const Key('bulk-mark-played')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Marked 1 episode played'), findsOneWidget);
    });
  });

  group('the Inbox', () {
    late Map<String, int> ids;

    setUp(() async {
      final feedId = await seedFeed();
      ids = {
        'Newest': await seedEpisode(feedId, 'Newest', 5000),
        'Article': await seedEpisode(feedId, 'Article', 4000, audio: false),
        'Middle': await seedEpisode(feedId, 'Middle', 3000),
        'Old': await seedEpisode(feedId, 'Old', 2000),
        'Oldest': await seedEpisode(feedId, 'Oldest', 1000),
      };
      await db.feedsDao.markPlayed(ids['Old']!, 7);
    });

    Future<void> pumpInbox(WidgetTester tester) async {
      await tester.pumpWidget(TrellisApp(
          db: db,
          fetcher: ScriptedFetcher((u, h) => textResponse('')),
          createPlayer: () => player));
      await tester.pumpAndSettle();
      await pickReader(tester, 'Ada');
      await tester.tap(find.text('Inbox'));
      await tester.pumpAndSettle();
    }

    Future<void> menu(WidgetTester tester, String title) async {
      await tester.tap(find.byKey(Key('menu-${ids[title]}')));
      await tester.pumpAndSettle();
    }

    for (final filter in ['chip-all', 'chip-audio']) {
      testWidgets('older means below in the list ($filter): unplayed audio '
          'only', (tester) async {
        await pumpInbox(tester);
        await tester.tap(find.byKey(Key(filter)));
        await tester.pumpAndSettle();
        await menu(tester, 'Newest');
        await tester.tap(find.byKey(Key('mark-older-${ids['Newest']}')));
        await tester.pumpAndSettle();
        expect(find.text('Mark 2 older episodes as played?'), findsOneWidget,
            reason: 'Middle and Oldest; the article has no played state '
                'and Old is already played');
        await tester.tap(find.text('Mark 2 played'));
        await tester.pumpAndSettle();
        expect((await ep(ids['Middle']!)).finishedAtMs, isNotNull);
        expect((await ep(ids['Oldest']!)).finishedAtMs, isNotNull);
        expect((await ep(ids['Newest']!)).finishedAtMs, isNull);
        expect(await SearchStore(db).history(profileId), isEmpty);
      });
    }

    testWidgets('older is strictly older: a tie the list puts below is not '
        'swept up', (tester) async {
      final feedId = (await db.feedsDao.feedsOf(profileId)).single.id;
      // Same moment as Middle, newer id, so it lists just above Middle.
      ids['Twin'] = await seedEpisode(feedId, 'Twin', 3000);
      await pumpInbox(tester);
      final twinY = tester.getTopLeft(find.text('Twin')).dy;
      expect(twinY, lessThan(tester.getTopLeft(find.text('Middle')).dy));
      await menu(tester, 'Twin');
      await tester.tap(find.byKey(Key('mark-older-${ids['Twin']}')));
      await tester.pumpAndSettle();
      expect(find.text('Mark 1 older episode as played?'), findsOneWidget,
          reason: 'Oldest only: Middle ties, Old is played');
    });

    testWidgets('the Text filter offers no mark-older (nothing there plays)',
        (tester) async {
      await pumpInbox(tester);
      await tester.tap(find.byKey(const Key('chip-text')));
      await tester.pumpAndSettle();
      await menu(tester, 'Article');
      expect(find.text('Mark everything older as played'), findsNothing);
    });

    testWidgets('Select from More, select all, swipes are off, filter '
        'changes keep only rows on screen', (tester) async {
      await pumpInbox(tester);
      await tester.tap(find.byKey(const Key('river-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('river-select')));
      await tester.pumpAndSettle();
      expect(bar('Select episodes'), findsOneWidget);

      await tester.tap(find.byKey(const Key('selection-all')));
      await tester.pumpAndSettle();
      expect(bar('5 selected'), findsOneWidget);
      final swipe = tester.widget<Dismissible>(
          find.byKey(Key('swipe-${ids['Newest']}')));
      expect(swipe.direction, DismissDirection.none);

      await tester.tap(find.byKey(const Key('chip-audio')));
      await tester.pumpAndSettle();
      expect(bar('4 selected'), findsOneWidget);

      await tester.tap(find.byKey(const Key('selection-done')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('selection-bar')), findsNothing);
    });

    testWidgets('a bulk Mark played over the Inbox leaves History alone',
        (tester) async {
      await pumpInbox(tester);
      await tester.longPress(find.text('Newest'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Middle'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bulk-mark-played')));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('played-${ids['Newest']}')), findsOneWidget);
      expect(find.text('Marked 2 episodes played'), findsOneWidget);
      expect(await SearchStore(db).history(profileId), isEmpty);
    });
  });

  group('History and search', () {
    late int heard;
    late int other;
    late Profile profile;

    setUp(() async {
      profile = (await db.profilesDao.all()).single;
      final feedId = await seedFeed();
      heard = await seedEpisode(feedId, 'Heard comet', 2000);
      other = await seedEpisode(feedId, 'Other comet', 1000);
      await db.feedsDao
          .savePlayerPosition(profileId: profileId, workId: heard, tMs: 9000);
    });

    SearchDoors doors() => SearchDoors(
        db: db,
        profile: profile,
        actions: EpisodeActions(
            db: db, profileId: profile.id, player: controller),
        useDefaultShare: false);

    testWidgets('History rows select and mark played; still listed once',
        (tester) async {
      await tester.pumpWidget(
          MaterialApp(home: HistoryScreen(doors: doors())));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('select-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('select-episodes')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Heard comet'));
      await tester.pumpAndSettle();
      expect(bar('1 selected'), findsOneWidget);
      await tester.tap(find.byKey(const Key('bulk-mark-played')));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('played-$heard')), findsOneWidget);
      expect((await SearchStore(db).history(profileId)).single.item.work.id,
          heard);
    });

    testWidgets('search results select, and a new query clears selection',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: SearchScreen(doors: doors(), debounce: Duration.zero)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('search-field')), 'comet');
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Other comet'));
      await tester.pumpAndSettle();
      expect(bar('1 selected'), findsOneWidget);
      await tester.tap(find.byKey(const Key('selection-all')));
      await tester.pumpAndSettle();
      expect(bar('2 selected'), findsOneWidget);
      await more(tester, const Key('bulk-let-pass'));
      expect((await ep(other)).readAtMs, isNotNull);
      expect(find.text('Let 2 items pass'), findsOneWidget);
      expect(
          tester
              .state<EditableTextState>(find.byType(EditableText))
              .widget
              .focusNode
              .hasFocus,
          isFalse,
          reason: 'the keyboard stays down after selection ends');
    });
  });
}

Future<void> more(WidgetTester tester, Key item) async {
  await tester.tap(find.byKey(const Key('selection-more')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(item));
  await tester.pumpAndSettle();
}
