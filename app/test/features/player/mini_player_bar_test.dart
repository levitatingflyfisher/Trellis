import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/mini_player_bar.dart';
import 'package:trellis/features/player/player_controller.dart';

import '../../support/fake_player.dart';

/// The bar the user touches most (1.5.9): a tap opens the episode, the X
/// closes it for good, and it takes one slim row.
void main() {
  late AppDatabase db;
  late FakeEpisodePlayer player;
  late PlayerController controller;
  late int profileId;
  late int feedId;

  /// Each player asked for is a fresh fake ([first] for the first, so a
  /// test can steer it before the load); [player] follows the newest. A
  /// released fake throws if used again.
  PlayerController newController(FakeEpisodePlayer first) {
    var made = 0;
    return PlayerController(
        db: db,
        profileId: profileId,
        createPlayer: () => made++ == 0 ? first : player = FakeEpisodePlayer());
  }

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    player = FakeEpisodePlayer();
    profileId = await db.profilesDao.create('Ada');
    feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://cast.test/feed', title: 'A Show');
    controller = newController(player);
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
  });

  Future<Work> seedEpisode(
      {String title = 'Ep 1', String kind = 'episode'}) async {
    final enclosure = 'https://cast.test/$title.mp3';
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: kind,
        title: title,
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: enclosure);
    await db.feedsDao.insertEpisode(
        workId: workId,
        feedId: feedId,
        guid: 'guid-$title',
        enclosureUrl: enclosure,
        publishedAtMs: 1000);
    return (await db.spineDao.workById(workId))!;
  }

  Future<void> pumpBar(WidgetTester tester, PlayerController c) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: const SizedBox.expand(),
        bottomNavigationBar: MiniPlayerBar(controller: c),
      ),
    ));
    await tester.pump();
  }

  /// The bar paints nothing: no bar, and no height where it was.
  void expectHidden(WidgetTester tester, {String? reason}) {
    expect(find.byKey(const Key('mini-player')), findsNothing,
        reason: reason);
    expect(tester.getSize(find.byType(MiniPlayerBar)).height, 0,
        reason: reason);
  }

  /// Taps X in [tester], then checks the bar is gone at once, after two
  /// seconds of fake time, and after a restart (a fresh controller
  /// rehydrating, as the shell does on launch): nothing has been played.
  Future<void> closeAndCheck(WidgetTester tester, PlayerController c,
      {Completer<void>? releaseAfterTap}) async {
    expect(find.byKey(const Key('mini-player')), findsOneWidget);
    await tester.tap(find.byKey(const Key('player-close')));
    await tester.pumpAndSettle();
    releaseAfterTap?.complete();
    await tester.pumpAndSettle();
    expectHidden(tester, reason: 'right after X');
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expectHidden(tester, reason: '2 s after X');
    expect(player.playing, isFalse, reason: 'X stops the sound too');

    expect(c.playing, isFalse, reason: 'nothing started after X');

    final restarted = newController(FakeEpisodePlayer());
    addTearDown(restarted.dispose);
    await restarted.rehydrateLastPlayed();
    await pumpBar(tester, restarted);
    expectHidden(tester, reason: 'a restart must not bring a closed bar back');
  }

  group('X hides the bar and it stays hidden', () {
    testWidgets('playing', (tester) async {
      await controller.playWork(await seedEpisode());
      await pumpBar(tester, controller);
      expect(player.playing, isTrue);
      await closeAndCheck(tester, controller);
    });

    testWidgets('paused', (tester) async {
      await controller.playWork(await seedEpisode());
      player.emitPosition(const Duration(seconds: 40));
      await controller.toggle();
      await pumpBar(tester, controller);
      expect(player.playing, isFalse);
      await closeAndCheck(tester, controller);
    });

    testWidgets('paused, restored after a restart (nothing loaded yet)',
        (tester) async {
      await controller.playWork(await seedEpisode());
      player.emitPosition(const Duration(seconds: 40));
      await controller.toggle();
      final restored = newController(FakeEpisodePlayer());
      addTearDown(restored.dispose);
      await restored.rehydrateLastPlayed();
      await pumpBar(tester, restored);
      expect(find.text('Paused at 0:40'), findsOneWidget);
      await closeAndCheck(tester, restored);
    });

    testWidgets('buffering (a load still in flight)', (tester) async {
      await controller.playWork(await seedEpisode(title: 'First'));
      await pumpBar(tester, controller);
      final second = await seedEpisode(title: 'Second');
      final gate = Completer<void>();
      player.loadGate = gate;
      unawaited(controller.playWork(second));
      await tester.pump();
      await closeAndCheck(tester, controller, releaseAfterTap: gate);
      expect(player.log.last, isNot('play'),
          reason: 'the load that finished after X must not start playing');
    });

    testWidgets('immediately after a skip forward (the skip not yet done)',
        (tester) async {
      await controller.playWork(await seedEpisode());
      player.emitDuration(const Duration(minutes: 10));
      await pumpBar(tester, controller);
      final seeking = Completer<void>();
      player.seekGate = seeking;
      unawaited(controller.seekBy(const Duration(seconds: 30)));
      await tester.pump();
      expect(player.log.last, 'seek:30000', reason: 'the skip is in flight');
      await closeAndCheck(tester, controller, releaseAfterTap: seeking);
    });

    testWidgets('as the episode ends, with another queued after it',
        (tester) async {
      final first = await seedEpisode(title: 'One');
      final second = await seedEpisode(title: 'Two');
      await db.queueDao
          .playLast(profileId: profileId, workId: first.id, nowMs: 1);
      await db.queueDao
          .playLast(profileId: profileId, workId: second.id, nowMs: 2);
      await controller.playWork(first);
      await pumpBar(tester, controller);
      player.emitCompleted();
      await closeAndCheck(tester, controller);
      expect(controller.current, isNull,
          reason: 'X wins over the queue moving on');
    });
  });

  testWidgets('tapping title or art opens the work page', (tester) async {
    await controller.playWork(await seedEpisode(title: 'Aurora season'));
    var opened = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        bottomNavigationBar: MiniPlayerBar(
            controller: controller, onOpenWork: () => opened++),
      ),
    ));
    await tester.pump();

    await tester.tap(find.text('Aurora season'));
    await tester.pump();
    expect(opened, 1);
    await tester.tap(find.byKey(const Key('player-art')));
    await tester.pump();
    expect(opened, 2);
  });

  testWidgets('show page is in the bar\'s menu', (tester) async {
    await controller.playWork(await seedEpisode());
    var shown = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        bottomNavigationBar: MiniPlayerBar(
            controller: controller, onOpenShow: () => shown++),
      ),
    ));
    await tester.pump();

    await tester.tap(find.byKey(const Key('player-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Go to show'));
    await tester.pumpAndSettle();
    expect(shown, 1);
  });

  testWidgets('no onOpenShow: the menu has no "Go to show"', (tester) async {
    await controller.playWork(await seedEpisode());
    await pumpBar(tester, controller);

    await tester.tap(find.byKey(const Key('player-menu')));
    await tester.pumpAndSettle();
    expect(find.text('Go to show'), findsNothing);
  });

  testWidgets('frequent actions stay in the bar; the rare ones are in the menu',
      (tester) async {
    await controller.playWork(await seedEpisode());
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        bottomNavigationBar: MiniPlayerBar(
          controller: controller,
          onCapture: () {},
          onOpenCaptures: () {},
          onOpenQueue: () {},
        ),
      ),
    ));
    await tester.pump();

    for (final k in [
      'player-back15',
      'player-toggle',
      'player-speed',
      'player-close'
    ]) {
      expect(find.byKey(Key(k)), findsOneWidget, reason: k);
    }
    // Back 15 sits just left of play/pause, where the thumb already is.
    expect(
        tester.getCenter(find.byKey(const Key('player-back15'))).dx,
        lessThan(tester.getCenter(find.byKey(const Key('player-toggle'))).dx));
    const rare = ['open-captures', 'open-queue', 'player-capture', 'player-fwd30'];
    for (final k in rare) {
      expect(find.byKey(Key(k)), findsNothing, reason: '$k is in the menu');
    }
    await tester.tap(find.byKey(const Key('player-menu')));
    await tester.pumpAndSettle();
    for (final k in rare) {
      expect(find.byKey(Key(k)), findsOneWidget, reason: k);
    }
    expect(find.byKey(const Key('player-back15')), findsOneWidget,
        reason: 'Back 15 is on the bar, not repeated in the menu');
  });

  testWidgets('Back 15 on the bar skips back', (tester) async {
    await controller.playWork(await seedEpisode());
    player.emitDuration(const Duration(minutes: 10));
    player.emitPosition(const Duration(minutes: 5));
    await pumpBar(tester, controller);

    await tester.tap(find.byKey(const Key('player-back15')));
    await tester.pump();

    expect(player.log.last, 'seek:${(5 * 60 - 15) * 1000}');
  });

  testWidgets('bar is slim: one row, at most 72 px at text scale 1.0',
      (tester) async {
    await controller.playWork(await seedEpisode());
    await pumpBar(tester, controller);
    final height = tester.getSize(find.byKey(const Key('mini-player'))).height;
    expect(height, lessThanOrEqualTo(72));
  });

  testWidgets('bar survives 320 dp at text scale 2.0', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await controller.playWork(
        await seedEpisode(title: 'A considerably long episode title here'));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        bottomNavigationBar: MiniPlayerBar(
          controller: controller,
          onOpenWork: () {},
          onOpenShow: () {},
          onOpenSyncedText: () {},
          onCapture: () {},
          onOpenCaptures: () {},
          onOpenQueue: () {},
          onOpenChapters: () {},
        ),
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    for (final k in [
      'player-back15',
      'player-toggle',
      'player-speed',
      'player-close',
      'player-menu',
      'player-open-work'
    ]) {
      expect(find.byKey(Key(k)).hitTestable(), findsOneWidget, reason: k);
    }
    // The art is decoration: it gives way before the title gets too narrow.
    final title = tester.getSize(
        find.text('A considerably long episode title here'));
    expect(title.width >= 48 || find.byKey(const Key('player-art')).evaluate().isEmpty,
        isTrue,
        reason: 'title ${title.width} px wide beside the art');
    await tester.tap(find.byKey(const Key('player-menu')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Go to show'), findsOneWidget);
  });
  group('the art says what is playing', () {
    for (final (kind, icon) in [
      ('episode', Icons.podcasts),
      ('audiobook', Icons.headphones_outlined),
      ('article', Icons.record_voice_over_outlined),
    ]) {
      testWidgets(kind, (tester) async {
        await controller.playWork(await seedEpisode(kind: kind));
        await pumpBar(tester, controller);
        expect(
            find.descendant(
                of: find.byKey(const Key('player-art')),
                matching: find.byIcon(icon)),
            findsOneWidget);
      });
    }
  });

  testWidgets('the title area reads as a button that opens the episode',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await controller.playWork(await seedEpisode(title: 'Aurora season'));
    player.emitDuration(const Duration(minutes: 60));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        bottomNavigationBar:
            MiniPlayerBar(controller: controller, onOpenWork: () {}),
      ),
    ));
    await tester.pump();

    expect(
        tester.getSemantics(find.byKey(const Key('player-open-work'))),
        containsSemantics(
            isButton: true,
            hasTapAction: true,
            label: 'Aurora season',
            hasScrollLeftAction: false,
            hasScrollRightAction: false));
    semantics.dispose();
  });

  group('scrubbing: drag along the title row', () {
    const title = 'Aurora season';

    /// Ten minutes into an hour.
    Future<int Function()> pumpPlaying(WidgetTester tester) async {
      var opened = 0;
      await controller.playWork(await seedEpisode(title: title));
      player.emitDuration(const Duration(minutes: 60));
      player.emitPosition(const Duration(minutes: 10));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: MiniPlayerBar(
              controller: controller, onOpenWork: () => opened++),
        ),
      ));
      await tester.pump();
      player.log.clear();
      return () => opened;
    }

    Rect line(WidgetTester tester) =>
        tester.getRect(find.byKey(const Key('player-slider')));

    List<String> seeks() =>
        [for (final e in player.log) if (e.startsWith('seek:')) e];

    double lineHeight(WidgetTester tester) => tester
        .widget<LinearProgressIndicator>(
            find.byKey(const Key('player-slider')))
        .minHeight!;

    testWidgets('the finger\'s place along the line is where it seeks, once, '
        'on letting go', (tester) async {
      final opened = await pumpPlaying(tester);
      final row = tester.getCenter(find.byKey(const Key('player-open-work')));
      final g = await tester.startGesture(row);
      await g.moveBy(const Offset(-30, 0));
      await g.moveTo(Offset(line(tester).left + line(tester).width / 4, row.dy));
      await tester.pump();

      expect(find.text('15:00 / 1:00:00'), findsOneWidget,
          reason: 'the title gives way to where the finger is');
      expect(find.text(title), findsNothing);
      expect(lineHeight(tester), greaterThan(3), reason: 'the line thickens');
      expect(find.byKey(const Key('player-scrub-thumb')), findsOneWidget);
      expect(seeks(), isEmpty, reason: 'no seek until the finger lifts');

      await g.up();
      await tester.pump();

      expect(seeks(), ['seek:900000']);
      expect(opened(), 0, reason: 'a drag is not a tap');
      expect(find.text(title), findsOneWidget);
      expect(lineHeight(tester), 3);
      expect(find.byKey(const Key('player-scrub-thumb')), findsNothing);
    });

    testWidgets('a tap still opens the episode', (tester) async {
      final opened = await pumpPlaying(tester);
      await tester.tap(find.text(title));
      await tester.pump();
      expect(opened(), 1);
      expect(seeks(), isEmpty);
    });

    testWidgets('a cancelled drag puts everything back and does not seek',
        (tester) async {
      await pumpPlaying(tester);
      final row = tester.getCenter(find.byKey(const Key('player-open-work')));
      final g = await tester.startGesture(row);
      await g.moveBy(const Offset(-30, 0));
      await g.moveBy(const Offset(-60, 0));
      await tester.pump();
      expect(find.text(title), findsNothing);

      await g.cancel();
      await tester.pump();

      expect(find.text(title), findsOneWidget);
      expect(lineHeight(tester), 3);
      expect(seeks(), isEmpty);
    });

    testWidgets('the line is a slider for a screen reader: +30 s, -15 s',
        (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpPlaying(tester);
      final node = tester.getSemantics(find.byKey(const Key('player-slider')));
      expect(
          node,
          containsSemantics(
              isSlider: true,
              isEnabled: true,
              hasIncreaseAction: true,
              hasDecreaseAction: true,
              value: '10:00 of 1:00:00'));

      tester.semantics.increase(find.semantics.byLabel('Position'));
      await tester.pump();
      tester.semantics.decrease(find.semantics.byLabel('Position'));
      await tester.pump();
      expect(seeks(), ['seek:630000', 'seek:615000']);
      semantics.dispose();
    });

    testWidgets('off while the length is unknown', (tester) async {
      final semantics = tester.ensureSemantics();
      var opened = 0;
      await controller.playWork(await seedEpisode(title: title));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          bottomNavigationBar: MiniPlayerBar(
              controller: controller, onOpenWork: () => opened++),
        ),
      ));
      await tester.pump();
      player.log.clear();

      await tester.drag(
          find.byKey(const Key('player-open-work')), const Offset(-120, 0));
      await tester.pump();

      expect(seeks(), isEmpty);
      expect(
          tester.getSemantics(find.byKey(const Key('player-slider'))),
          containsSemantics(
              isSlider: true,
              hasIncreaseAction: false,
              hasDecreaseAction: false));
      semantics.dispose();
    });

    testWidgets('off on a bar restored at launch, before anything loads',
        (tester) async {
      await controller.playWork(await seedEpisode(title: title));
      player.emitDuration(const Duration(minutes: 60));
      player.emitPosition(const Duration(minutes: 10));
      await controller.toggle();
      final restored = newController(FakeEpisodePlayer());
      addTearDown(restored.dispose);
      await restored.rehydrateLastPlayed();
      await pumpBar(tester, restored);

      final row = tester.getCenter(find.byKey(const Key('player-open-work')));
      final g = await tester.startGesture(row);
      await g.moveBy(const Offset(-30, 0));
      await g.moveBy(const Offset(-60, 0));
      await tester.pump();
      expect(find.text(title), findsOneWidget, reason: 'no readout');
      await g.up();
      await tester.pump();
      expect(restored.current, isNotNull);
      expect(restored.isLoaded(restored.current!.id), isFalse,
          reason: 'a drag on a restored bar neither loads nor seeks');
    });

    for (final (label, size, scale) in [
      ('320 dp at text scale 2.0', const Size(320, 640), 2.0),
      ('the default width at text scale 1.0', const Size(800, 600), 1.0),
    ]) {
      testWidgets('mid-drag the bar still fits: $label', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearAllTestValues);
        await pumpPlaying(tester);
        final row =
            tester.getCenter(find.byKey(const Key('player-open-work')));
        final g = await tester.startGesture(row);
        await g.moveBy(const Offset(30, 0));
        await g.moveBy(const Offset(20, 0));
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.textContaining(' / 1:00:00'), findsOneWidget);
        if (scale == 1.0) {
          expect(tester.getSize(find.byKey(const Key('mini-player'))).height,
              lessThanOrEqualTo(72));
        }
        await g.up();
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  });
}
