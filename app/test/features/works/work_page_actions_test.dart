import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/episodes/episode_actions.dart';
import 'package:trellis/features/feeds/episode_download_coordinator.dart';
import 'package:trellis/features/feeds/feed_detail_screen.dart';
import 'package:trellis/features/feeds/feeds_repository.dart';
import 'package:trellis/features/player/mini_player_bar.dart';
import 'package:trellis/features/player/mini_player_host.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/reader/reader_doors.dart';
import 'package:trellis/features/reader/reader_screen.dart';
import 'package:trellis/features/transcribe/transcribe_coordinator.dart';
import 'package:trellis/features/works/work_open.dart';
import 'package:trellis/features/works/work_row.dart';
import 'package:trellis/services/device_services.dart';

import '../../support/fake_player.dart';
import '../../support/fake_services.dart';
import '../../support/fake_tts.dart';
import '../../support/scripted_fetcher.dart';

/// One primary Play per screen (1.5.9, user 2026-11-03: "three Play
/// buttons" on a transcribed episode's reader, the bar's and the page's
/// tied together, a third that wasn't). At most one filled action on a
/// page; a row whose episode is playing shows that, not a second Play;
/// the page never repeats the bar's Play; and everything that moves the
/// cursor by sound or by pace takes turns with the episode's audio.
void main() {
  late AppDatabase db;
  late int profileId;
  late int feedId;
  late int episode;
  late FakeEpisodePlayer fake;
  late PlayerController controller;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
    feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://x.test/f', title: 'Night Sky');
    episode = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Aurora season',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://x.test/aurora.mp3');
    await db.feedsDao.insertEpisode(
        workId: episode,
        feedId: feedId,
        guid: 'aurora',
        enclosureUrl: 'https://x.test/aurora.mp3',
        durationMs: 60 * 60000,
        publishedAtMs: 1000);
    fake = FakeEpisodePlayer();
    controller = PlayerController(
        db: db, profileId: profileId, createPlayer: () => fake);
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
  });

  Future<void> transcribe() async {
    await db.spineDao.insertSegments(episode, const [
      (idx: 0, kind: 'prose', text: 'First sentence of the lights.'),
      (idx: 1, kind: 'prose', text: 'Second sentence of the lights.'),
    ]);
    await db.spineDao.insertAlignments(episode, const [
      (segmentIdx: 0, tStartMs: 0, tEndMs: 10000),
      (segmentIdx: 1, tStartMs: 10000, tEndMs: 20000),
    ]);
  }

  Future<Work> work() async => (await db.spineDao.workById(episode))!;

  /// Filled buttons on the screen. `FilledButton.tonal` counts (it is a
  /// FilledButton); a tonal button with an icon is a quieter subclass.
  /// So does a filled icon button (the bar's Play, any `IconButton.filled`):
  /// it has no type of its own, so it is known by its fill, the primary
  /// colour, the same one a FilledButton wears.
  int filled() {
    var n = find.byType(FilledButton).evaluate().length;
    for (final e in find.byType(IconButton).evaluate()) {
      Material? fill;
      void visit(Element c) {
        if (fill != null) return;
        if (c.widget is Material) {
          fill = c.widget as Material;
          return;
        }
        c.visitChildren(visit);
      }

      e.visitChildren(visit);
      if (fill?.color == Theme.of(e).colorScheme.primary) n++;
    }
    return n;
  }

  group('the work page', () {
    late Directory dir;
    late DeviceServices services;
    setUp(() => dir = Directory.systemTemp.createTempSync('trellis-actions'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<void> pumpPage(WidgetTester tester) async {
      services = testServices(dir);
      final actions = EpisodeActions(
          db: db,
          profileId: profileId,
          player: controller,
          downloader: EpisodeDownloadCoordinator(services: services, db: db),
          transcriber: TranscribeCoordinator(db: db, services: services),
          services: services,
          transcribeRate: () => 1 / 12);
      final doors = WorkDoors(
          db: db,
          profileId: profileId,
          readerDoors: ReaderDoors(player: controller),
          actions: actions,
          transcribeRate: () => 1 / 12);
      final w = await work();
      final ep = await db.feedsDao.episodeOf(episode);
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                  body: Center(
                      child: TextButton(
                          onPressed: () =>
                              doors.open(context, (work: w, episode: ep)),
                          child: const Text('open')))))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('has at most one filled action', (tester) async {
      await pumpPage(tester);
      expect(filled(), lessThanOrEqualTo(1));
      // No mode is primary: Listen and Read both stay on the page.
      expect(find.byKey(const Key('mode-listen')), findsOneWidget);
      expect(find.byKey(const Key('mode-read')), findsOneWidget);
    });

    testWidgets('a transcribed episode too, and Read stays a tap away',
        (tester) async {
      await transcribe();
      await pumpPage(tester);
      expect(filled(), lessThanOrEqualTo(1));
      final read = tester.widget<ButtonStyleButton>(
          find.byKey(const Key('mode-read')));
      expect(read.onPressed, isNotNull);
    });

    testWidgets('survives text scale 2.0 with 48 dp mode buttons',
        (tester) async {
      tester.view.physicalSize = const Size(360 * 3, 800 * 3);
      tester.view.devicePixelRatio = 3;
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await transcribe();
      await pumpPage(tester);
      expect(tester.takeException(), isNull);
      for (final k in ['mode-listen', 'mode-read']) {
        expect(tester.getSize(find.byKey(Key(k))).height,
            greaterThanOrEqualTo(48));
      }
    });
  });

  group('the show page', () {
    Future<void> pumpShow(WidgetTester tester) async {
      final feed = (await db.feedsDao.feedsOf(profileId)).single;
      await tester.pumpWidget(MaterialApp(
          home: FeedDetailScreen(
              db: db,
              repository: FeedsRepository(
                  db: db,
                  fetcher: ScriptedFetcher((u, h) => textResponse(''))),
              feed: feed,
              playerController: controller)));
      await tester.pumpAndSettle();
    }

    testWidgets('has at most one filled action', (tester) async {
      await pumpShow(tester);
      expect(filled(), lessThanOrEqualTo(1));
    });

    testWidgets('the playing row shows Playing, and pauses on a tap',
        (tester) async {
      await pumpShow(tester);
      expect(find.byKey(Key('play-$episode')), findsOneWidget);
      expect(find.byKey(const Key('row-playing')), findsNothing);

      await tester.tap(find.byKey(Key('play-$episode')));
      await tester.pumpAndSettle();
      expect(controller.playing, isTrue);
      expect(find.byKey(const Key('row-playing')), findsOneWidget);
      expect(find.byKey(Key('play-$episode')), findsNothing,
          reason: 'a playing row shows its state, not a second Play');
      expect(find.text('Playing'), findsOneWidget);

      await tester.tap(find.byKey(const Key('row-playing')));
      await tester.pumpAndSettle();
      expect(controller.playing, isFalse);
    });
  });

  // Every list builds the same row (Latest, Queue, History, Library, the
  // show page, Search), so the row carries the rule for all of them.
  group('the row', () {
    Future<void> pumpRow(WidgetTester tester, Work w,
        {double scale = 1.0}) async {
      final ep = await db.feedsDao.episodeOf(w.id);
      await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
              data: MediaQueryData(
                  size: const Size(320, 640),
                  textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                  body: ListView(children: [
                WorkRow(
                    work: w,
                    episode: ep,
                    facts: WorkRowFacts.of(w, ep, WorkListState.empty),
                    player: controller,
                    onPlay: () => controller.playWork(w)),
              ])))));
      await tester.pumpAndSettle();
    }

    testWidgets('Playing only for the current, playing episode',
        (tester) async {
      final w = await work();
      await pumpRow(tester, w);
      expect(find.byKey(const Key('row-playing')), findsNothing);
      await controller.playWork(w);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('row-playing')), findsOneWidget);
      // Paused: Play again, which resumes the same episode.
      await controller.toggle();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('row-playing')), findsNothing);
      expect(find.byKey(Key('play-${w.id}')), findsOneWidget);
    });

    testWidgets('a position tick rebuilds no row', (tester) async {
      final w = await work();
      await controller.playWork(w);
      await pumpRow(tester, w);
      expect(find.byKey(const Key('row-playing')), findsOneWidget);
      var heard = 0;
      void count() => heard++;
      controller.addListener(count);
      addTearDown(() => controller.removeListener(count));
      fake.emitPosition(const Duration(seconds: 7));
      expect(heard, greaterThan(0), reason: 'the player did tick');
      expect(tester.binding.hasScheduledFrame, isFalse,
          reason: 'only a change of episode or of playing redraws a row');
    });

    testWidgets('Playing tells a screen reader a tap pauses', (tester) async {
      final semantics = tester.ensureSemantics();
      final w = await work();
      await controller.playWork(w);
      await pumpRow(tester, w);
      expect(tester.getSemantics(find.byKey(const Key('row-playing'))),
          matchesSemantics(
              label: 'Playing, pause',
              isButton: true,
              hasTapAction: true,
              hasFocusAction: true,
              isFocusable: true,
              hasEnabledState: true,
              isEnabled: true));
      semantics.dispose();
    });

    testWidgets('Playing is a 48 dp target and fits at text scale 2.0',
        (tester) async {
      final w = await work();
      await controller.playWork(w);
      await pumpRow(tester, w, scale: 2.0);
      expect(tester.takeException(), isNull);
      final size = tester.getSize(find.byKey(const Key('row-playing')));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(size.width, greaterThanOrEqualTo(48));
    });
  });

  // The page from the report: a transcribed episode's reader, with the
  // episode in the player and so in the bar. The bar is the shell's own
  // (attached to the host as the shell attaches it) and the reader is
  // pushed over a root page, so the bar is really drawn.
  group('the reader', () {
    late FakeTtsSpeaker tts;
    setUp(() async {
      tts = FakeTtsSpeaker();
      // Before anything plays: the player reads the alignments on load.
      await transcribe();
    });

    Future<void> pumpReader(WidgetTester tester, {bool bar = true}) async {
      final w = await work();
      final key = GlobalKey<NavigatorState>();
      final routes = MiniPlayerRoutes();
      await tester.pumpWidget(MaterialApp(
          navigatorKey: key,
          navigatorObservers: [routes],
          builder: (context, child) => MiniPlayerHost(
              routes: routes, navigatorKey: key, child: child!),
          home: const Scaffold(body: Text('root'))));
      if (bar) {
        tester
            .state<MiniPlayerHostState>(find.byType(MiniPlayerHost))
            .attach(controller, (_) => MiniPlayerBar(controller: controller));
      }
      unawaited(key.currentState!.push(MaterialPageRoute<void>(
          builder: (_) => ReaderScreen(
              db: db,
              profileId: profileId,
              work: w,
              player: controller,
              tts: tts,
              openOnPage: true))));
      await tester.pumpAndSettle();
    }

    Future<void> toRsvp(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('mode-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('mode-item-rsvp')));
      await tester.pumpAndSettle();
    }

    String rsvpWord(WidgetTester tester) {
      String at(Key k) => tester.widget<Text>(find.byKey(k)).data!;
      return at(const Key('rsvp-bef')) +
          at(const Key('rsvp-piv')) +
          at(const Key('rsvp-aft'));
    }

    final barPlay = find.byKey(const Key('player-toggle'));
    final listen = find.byKey(const Key('reader-play'));
    final pacer = find.byKey(const Key('play-toggle'));
    final backToAudio = find.byKey(const Key('back-to-audio'));

    /// The pacer, running, until the cursor reaches [word]: the reader
    /// reading ahead of (or behind) the paused voice.
    Future<void> paceTo(WidgetTester tester, String word) async {
      await tester.tap(pacer);
      await tester.pump();
      await tester.pump();
      expect(controller.playing, isFalse, reason: 'the pacer paused it');
      for (var i = 0; i < 40 && rsvpWord(tester) != word; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(rsvpWord(tester), word);
      await tester.tap(pacer); // the pacer stops
      await tester.pumpAndSettle();
    }

    testWidgets('while it plays and the page follows, the bar’s Play is the '
        'one Play', (tester) async {
      await controller.playWork(await work());
      await pumpReader(tester);
      expect(barPlay, findsOneWidget, reason: 'the bar is drawn');
      expect(listen, findsNothing,
          reason: 'the bar holds this episode’s Play');
      // Read aloud stays on the page, worded, never behind the bar.
      expect(find.byKey(const Key('speak-toggle')), findsOneWidget);
      expect(find.text('Read aloud'), findsOneWidget);
      expect(filled(), lessThanOrEqualTo(1));

      await toRsvp(tester);
      expect(barPlay, findsOneWidget);
      expect(listen, findsNothing);
      expect(pacer, findsOneWidget,
          reason: 'one word at a time is reading, and keeps its control');
      expect(filled(), 1, reason: 'the bar’s Play, and nothing beside it');
    });

    testWidgets('the one-word pacer is not a second Play', (tester) async {
      await controller.playWork(await work());
      await pumpReader(tester);
      await toRsvp(tester);
      Finder inPacer(Finder f) => find.descendant(of: pacer, matching: f);
      for (final running in [false, true]) {
        expect(inPacer(find.byIcon(Icons.play_arrow)), findsNothing);
        expect(inPacer(find.byIcon(Icons.play_circle_outline)), findsNothing);
        // A plain word, and never a mode's name.
        for (final word in ['Play', 'RSVP', 'Page', 'Listen', 'Read']) {
          expect(inPacer(find.text(word)), findsNothing);
        }
        expect(inPacer(find.text(running ? 'Pause' : 'Start')),
            findsOneWidget);
        expect(filled(), lessThanOrEqualTo(1));
        expect(tester.getSize(pacer).height, greaterThanOrEqualTo(48));
        if (!running) {
          await tester.tap(pacer);
          await tester.pump();
          await tester.pump();
        }
      }
      await tester.tap(pacer);
      await tester.pumpAndSettle();
    });

    testWidgets('with the bar, survives text scale 2.0; Start and Listen '
        'from here are 48 dp', (tester) async {
      tester.view.physicalSize = const Size(360 * 3, 800 * 3);
      tester.view.devicePixelRatio = 3;
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await controller.playWork(await work());
      await controller.toggle(); // paused: Listen from here shows too
      await pumpReader(tester);
      await toRsvp(tester);
      expect(tester.takeException(), isNull);
      expect(barPlay, findsOneWidget);
      for (final f in [pacer, listen]) {
        final size = tester.getSize(f);
        expect(size.height, greaterThanOrEqualTo(48));
        expect(size.width, greaterThanOrEqualTo(48));
      }
    });

    testWidgets('keeps Listen from here when the bar shows nothing of this '
        'episode', (tester) async {
      await pumpReader(tester);
      expect(listen, findsOneWidget);
      expect(find.byTooltip('Listen from here'), findsOneWidget);
    });

    testWidgets('keeps Listen from here while paused, in the bar',
        (tester) async {
      await controller.playWork(await work());
      await controller.toggle();
      await pumpReader(tester);
      expect(barPlay, findsOneWidget);
      expect(listen, findsOneWidget,
          reason: 'the bar would resume where the voice stopped; this '
              'starts it where the reader is');
    });

    testWidgets('Listen looks like listening, not a second Play',
        (tester) async {
      await pumpReader(tester);
      await toRsvp(tester);
      expect(
          find.descendant(of: listen, matching: find.byIcon(Icons.play_arrow)),
          findsNothing,
          reason: 'beside the bar’s Play, Listen wears headphones');
      expect(
          find.descendant(
              of: listen, matching: find.byIcon(Icons.headphones_outlined)),
          findsOneWidget);
    });

    // The review's drift: the pacer pauses the voice, the reader reads
    // ahead, and then the voice and the cursor must not go two ways.
    testWidgets('read ahead with the pacer, then Listen from here starts the '
        'voice at the cursor', (tester) async {
      await controller.playWork(await work());
      await pumpReader(tester);
      await toRsvp(tester);
      expect(rsvpWord(tester), 'First');
      await paceTo(tester, 'Second');
      expect(listen, findsOneWidget,
          reason: 'not following: the voice is behind the reader');

      await tester.tap(listen);
      await tester.pumpAndSettle();
      expect(controller.playing, isTrue);
      expect(controller.position.inMilliseconds, 10000,
          reason: '"Second" is where segment 1 starts, at 10 s');
      expect(rsvpWord(tester), 'Second', reason: 'the cursor stayed put');
      expect(listen, findsNothing, reason: 'playing and following again');
      expect(backToAudio, findsNothing);
    });

    testWidgets('read ahead with the pacer, then the bar’s Play: the page '
        'follows the voice again', (tester) async {
      await controller.playWork(await work());
      await pumpReader(tester);
      await toRsvp(tester);
      await paceTo(tester, 'Second');
      expect(backToAudio, findsOneWidget);

      await tester.tap(barPlay); // or the lock screen: the same controller
      await tester.pump();
      await tester.pump();
      expect(controller.playing, isTrue);
      expect(rsvpWord(tester), 'First',
          reason: 'the cursor rejoined the voice, not a word apart from it');
      expect(backToAudio, findsNothing);
      expect(listen, findsNothing);
      await tester.pumpAndSettle();
    });

    testWidgets('Read aloud pauses the episode: one voice at a time',
        (tester) async {
      await controller.playWork(await work());
      await pumpReader(tester);
      expect(controller.playing, isTrue);

      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();
      await tester.pump();
      expect(controller.playing, isFalse);
      expect(tts.utterances, isNotEmpty);
      expect(find.text('Stop'), findsOneWidget);
      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pumpAndSettle();
    });

    testWidgets('the episode playing again stops Read aloud', (tester) async {
      await controller.playWork(await work());
      await controller.toggle(); // paused, still in the bar
      await pumpReader(tester);
      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();
      expect(find.text('Stop'), findsOneWidget);

      await tester.tap(barPlay);
      await tester.pump();
      await tester.pump();
      expect(controller.playing, isTrue);
      expect(find.text('Read aloud'), findsOneWidget,
          reason: 'the voice stopped for the episode');
      await tester.pumpAndSettle();
    });

    testWidgets('the pacer pauses the episode, and the episode playing again '
        'pauses the pacer', (tester) async {
      await controller.playWork(await work());
      await pumpReader(tester);
      await toRsvp(tester);
      await tester.tap(pacer);
      await tester.pump();
      await tester.pump();
      expect(controller.playing, isFalse);
      expect(find.descendant(of: pacer, matching: find.text('Pause')),
          findsOneWidget);

      await tester.tap(barPlay);
      await tester.pump();
      await tester.pump();
      expect(find.descendant(of: pacer, matching: find.text('Start')),
          findsOneWidget,
          reason: 'the pacer let go when the episode took the cursor');
      await tester.pumpAndSettle();
    });

    testWidgets('a pause that fails never starts a second voice over the '
        'first', (tester) async {
      await controller.playWork(await work());
      await pumpReader(tester);
      fake.failNextPause = true;
      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();
      await tester.pump();
      expect(controller.playing, isTrue);
      expect(tts.utterances, isEmpty, reason: 'no voice over the audio');
      expect(find.text('Couldn’t pause the audio. Pause it, then try again.'),
          findsOneWidget);
      await tester.pumpAndSettle();
    });
  });
}
