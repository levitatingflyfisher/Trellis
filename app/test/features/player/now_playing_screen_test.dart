import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/mini_player_bar.dart';
import 'package:trellis/features/player/mini_player_host.dart';
import 'package:trellis/features/player/now_playing_screen.dart';
import 'package:trellis/features/player/player_controller.dart';

import '../../support/fake_player.dart';

/// The big player (owner, 14 Nov: "the little horizontal card that shows
/// what is playing needs to become a big screen when I click it, so I can
/// drag the play bar; it's too tiny a target right now").
void main() {
  late AppDatabase db;
  late FakeEpisodePlayer player;
  late PlayerController controller;
  late int profileId;
  late int feedId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    player = FakeEpisodePlayer();
    profileId = await db.profilesDao.create('Ada');
    feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://cast.test/feed', title: 'A Show');
    var made = 0;
    controller = PlayerController(
        db: db,
        profileId: profileId,
        createPlayer: () =>
            made++ == 0 ? player : player = FakeEpisodePlayer());
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
  });

  const title = 'Aurora season';

  /// Ten minutes into an hour.
  Future<void> playing() async {
    const enclosure = 'https://cast.test/aurora.mp3';
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: title,
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: enclosure);
    await db.feedsDao.insertEpisode(
        workId: workId,
        feedId: feedId,
        guid: 'guid-aurora',
        enclosureUrl: enclosure,
        publishedAtMs: 1000);
    await controller.playWork((await db.spineDao.workById(workId))!);
    player.emitDuration(const Duration(minutes: 60));
    player.emitPosition(const Duration(minutes: 10));
    player.log.clear();
  }

  List<int> seeks() => [
        for (final e in player.log)
          if (e.startsWith('seek:')) int.parse(e.substring(5))
      ];

  /// A phone: 360 × 740 dp.
  Future<void> phone(WidgetTester tester, {double textScale = 1}) async {
    tester.view.physicalSize = const Size(1080, 2220);
    tester.view.devicePixelRatio = 3;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  /// The bar on a home screen, its tap opening the big player.
  Future<List<String>> pumpApp(WidgetTester tester) async {
    final opened = <String>[];
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: key,
      home: Builder(
        builder: (context) => Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: MiniPlayerBar(
            controller: controller,
            onOpenWork: () => opened.add('work'),
            onOpenNowPlaying: () => openNowPlaying(
              key.currentContext!,
              controller: controller,
              onOpenWork: () => opened.add('work'),
              onOpenQueue: () => opened.add('queue'),
              onOpenSyncedText: () => opened.add('page'),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    return opened;
  }

  testWidgets('a tap on the bar opens the big player, not the episode',
      (tester) async {
    await phone(tester);
    await playing();
    final opened = await pumpApp(tester);
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('now-playing')), findsOneWidget);
    expect(opened, isEmpty);
  });

  testWidgets('the scrub bar is big: nearly the screen wide, a thumb tall',
      (tester) async {
    await phone(tester);
    await playing();
    await pumpApp(tester);
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
    final bar = tester.getRect(find.byKey(const Key('now-playing-scrub')));
    expect(bar.width, greaterThan(300));
    expect(bar.height, greaterThanOrEqualTo(48));
    expect(find.byKey(const Key('now-playing-elapsed')), findsOneWidget);
    expect(find.text('10:00'), findsOneWidget);
    expect(find.text('-50:00'), findsOneWidget);
  });

  testWidgets('dragging the scrub bar seeks once, where the finger lifts',
      (tester) async {
    await phone(tester);
    await playing();
    await pumpApp(tester);
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
    final bar = tester.getRect(find.byKey(const Key('now-playing-scrub')));
    final g = await tester.startGesture(bar.centerLeft + const Offset(40, 0));
    await g.moveTo(Offset(bar.left + bar.width * 0.75, bar.center.dy));
    await tester.pump();
    expect(seeks(), isEmpty, reason: 'no seek until the finger lifts');
    expect(find.text('10:00'), findsNothing,
        reason: 'the time follows the finger');
    await g.up();
    await tester.pump();
    expect(seeks(), hasLength(1));
    // About three quarters of an hour (the thumb's margin aside).
    expect(seeks().single, inInclusiveRange(40 * 60000, 50 * 60000));
  });

  testWidgets('play, back 15 and forward 30', (tester) async {
    await phone(tester);
    await playing();
    await pumpApp(tester);
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('now-playing-back15')));
    await tester.tap(find.byKey(const Key('now-playing-fwd30')));
    await tester.pump();
    expect(seeks(), [10 * 60000 - 15000, 10 * 60000 + 30000 - 15000]);
    expect(controller.playing, isTrue);
    await tester.tap(find.byKey(const Key('now-playing-toggle')));
    await tester.pump();
    expect(controller.playing, isFalse);
  });

  testWidgets('the down arrow takes it back to the bar', (tester) async {
    await phone(tester);
    await playing();
    await pumpApp(tester);
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('now-playing-down')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('now-playing')), findsNothing);
    expect(find.byKey(const Key('mini-player')), findsOneWidget);
  });

  testWidgets('a swipe down takes it back to the bar too', (tester) async {
    await phone(tester);
    await playing();
    await pumpApp(tester);
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
    await tester.fling(find.byKey(const Key('now-playing-art')),
        const Offset(0, 400), 1500);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('now-playing')), findsNothing);
  });

  testWidgets('the episode, Page and the Queue close the big player first',
      (tester) async {
    await phone(tester);
    await playing();
    final opened = await pumpApp(tester);
    for (final (key, what) in [
      ('now-playing-open-work', 'work'),
      ('now-playing-page', 'page'),
      ('now-playing-queue', 'queue'),
    ]) {
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      // Page shows only with a transcript; this episode has none.
      if (what == 'page') {
        expect(find.byKey(Key(key)), findsNothing);
        await tester.tap(find.byKey(const Key('now-playing-down')));
        await tester.pumpAndSettle();
        continue;
      }
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('now-playing')), findsNothing);
      expect(opened.last, what);
    }
  });

  testWidgets('it fits a small phone at twice the text size', (tester) async {
    tester.view.physicalSize = const Size(640, 1136);
    tester.view.devicePixelRatio = 2;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await playing();
    await pumpApp(tester);
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('now-playing-toggle')), findsOneWidget);
  });

  testWidgets('on a phone, the scrub bar, Play and every door show unscrolled',
      (tester) async {
    for (final (size, scale) in [
      (const Size(1080, 2220), 1.0), // 360 × 740
      (const Size(1080, 2220), 1.3),
      (const Size(960, 1920), 1.0), // 320 × 640
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 3;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      if (controller.current == null) await playing();
      await pumpApp(tester);
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      for (final key in [
        'now-playing-scrub',
        'now-playing-toggle',
        'now-playing-queue',
      ]) {
        final r = tester.getRect(find.byKey(Key(key)));
        expect(r.bottom, lessThanOrEqualTo(screen.height),
            reason: '$key at $size × $scale');
      }
      await tester.tap(find.byKey(const Key('now-playing-down')));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('the episode’s languages switch where it plays, at the same '
      'paragraph (1.6.18: they live together)', (tester) async {
    await phone(tester);
    final dir = Directory.systemTemp.createTempSync('trellis-np-lang');
    addTearDown(() => dir.deleteSync(recursive: true));
    File fileFor(int id, String url) => File('${dir.path}/$id.audio');

    late int original, es;
    await tester.runAsync(() async {
      original = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: title,
          persistence: 'ephemeron',
          firstSeenEpochDay: 100,
          sourceUrl: 'https://cast.test/aurora.mp3',
          lang: 'en');
      await db.feedsDao.insertEpisode(
          workId: original,
          feedId: feedId,
          guid: 'guid-aurora',
          enclosureUrl: 'https://cast.test/aurora.mp3',
          publishedAtMs: 1000);
      await db.spineDao.insertSegments(original, const [
        (idx: 0, kind: 'prose', text: 'Hello.'),
        (idx: 1, kind: 'prose', text: 'Goodbye.'),
      ]);
      await db.spineDao.insertAlignments(original, const [
        (segmentIdx: 0, tStartMs: 0, tEndMs: 600000),
        (segmentIdx: 1, tStartMs: 600000, tEndMs: 3600000),
      ]);
      for (final (seg, text, body) in [
        (0, 'Hello.', 'Hola.'),
        (1, 'Goodbye.', 'Adiós.'),
      ]) {
        await db.spineDao.upsertTranslationSentence(
            workId: original,
            segmentIdx: seg,
            sentenceIdx: 0,
            lang: 'es',
            sourceText: text,
            body: body);
      }
      es = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'version',
          title: '$title (Spanish)',
          persistence: 'ephemeron',
          firstSeenEpochDay: 100,
          sourceUrl: 'https://spoken.trellis.invalid/$original-es.ogg',
          lang: 'es');
      await db.versionsDao.put(workId: es, originalId: original, lang: 'es');
      await db.spineDao.insertSegments(es, const [
        (idx: 0, kind: 'prose', text: 'Hola.'),
        (idx: 1, kind: 'prose', text: 'Adiós.'),
      ]);
      await db.spineDao.insertAlignments(es, const [
        (segmentIdx: 0, tStartMs: 0, tEndMs: 2000),
        (segmentIdx: 1, tStartMs: 2000, tEndMs: 5000),
      ]);
      fileFor(es, '').writeAsBytesSync([1]);
      await controller.playWork((await db.spineDao.workById(original))!);
    });
    player.emitDuration(const Duration(minutes: 60));
    player.emitPosition(const Duration(minutes: 20));

    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: key,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => openNowPlaying(context,
                controller: controller, audioFileFor: fileFor),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
    }

    expect(find.byKey(const Key('now-playing-lang-en')), findsOneWidget);
    final spanish = find.byKey(const Key('now-playing-lang-es'));
    expect(find.descendant(of: spanish, matching: find.text('Spanish')),
        findsOneWidget);
    player.log.clear();
    await tester.tap(spanish);
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
    }
    expect(controller.current?.id, es);
    expect(player.log, contains('seek:2000'),
        reason: 'twenty minutes in is the second paragraph, which starts '
            'two seconds into the Spanish');
  });

  testWidgets('with one language there is no language row', (tester) async {
    await phone(tester);
    await playing();
    await pumpApp(tester);
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('now-playing-languages')), findsNothing);
  });

  test('the host hides its bar while the big player is on top', () {
    final routes = MiniPlayerRoutes();
    final home = MaterialPageRoute<void>(builder: (_) => const SizedBox());
    final page = MaterialPageRoute<void>(builder: (_) => const SizedBox());
    final big = MaterialPageRoute<void>(
        settings: const RouteSettings(name: NowPlayingScreen.routeName),
        builder: (_) => const SizedBox());
    routes.didPush(home, null);
    routes.didPush(page, home);
    expect(routes.pageOverRoot, isTrue);
    expect(routes.nowPlayingOnTop, isFalse);
    routes.didPush(big, page);
    expect(routes.nowPlayingOnTop, isTrue);
    routes.didPop(big, page);
    expect(routes.nowPlayingOnTop, isFalse);
  });
}
