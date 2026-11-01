import 'package:audio_service/audio_service.dart';
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show SizedBox;
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/bootstrap/bootstrap.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/player/trellis_audio_handler.dart';
import 'package:trellis/main.dart';

import '../../support/fake_player.dart';
import '../../support/scripted_fetcher.dart';

/// The Next episode and Previous episode a headset's keys can be set to
/// (1.6.0, owner: "Triple tap is skip forward episode"). The handler's
/// own tests give it stand-ins, so the last group boots the real app.
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
        db: db,
        profileId: profileId,
        // X lets the engine go; the next Play makes a fresh one.
        createPlayer: () =>
            player.disposed ? player = FakeEpisodePlayer() : player);
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
  });

  var seeded = 0;
  Future<Work> seed(String title, {bool queue = true}) async {
    final n = ++seeded;
    final feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://cast.test/f$n', title: 'Show');
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: title,
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/$n.mp3');
    await db.feedsDao.insertEpisode(
        workId: id,
        feedId: feedId,
        guid: 'g$n',
        enclosureUrl: 'https://cast.test/$n.mp3',
        publishedAtMs: 1000);
    if (queue) {
      await db.queueDao.playLast(profileId: profileId, workId: id, nowMs: n);
    }
    return (await db.spineDao.workById(id))!;
  }

  Future<List<int>> queue() async =>
      [for (final r in await db.queueDao.queueOf(profileId)) r.workId];

  group('Next episode', () {
    test('plays the next in the queue; the one left is neither played nor '
        'removed, because a stray press must lose nothing', () async {
      final a = await seed('A');
      final b = await seed('B');
      await controller.playWork(a);

      await controller.nextEpisode();

      expect(controller.current?.id, b.id);
      expect(player.loadedUrl, b.sourceUrl);
      expect(await queue(), [a.id, b.id]);
      expect((await db.feedsDao.episodeOf(a.id))!.finishedAtMs, isNull);
    });

    test('an episode passed over does not come back when the next one '
        'finishes: the queue goes on forward', () async {
      final a = await seed('A');
      final b = await seed('B');
      final c = await seed('C');
      await controller.playWork(a);
      await controller.nextEpisode();

      player.emitCompleted();
      await pumpEventQueue();

      expect(controller.current?.id, c.id);
      expect(await queue(), [a.id, c.id], reason: '${b.id} finished');
    });

    test('nothing further in the queue: the episode plays on', () async {
      final a = await seed('A');
      await controller.playWork(a);
      player.log.clear();

      await controller.nextEpisode();

      expect(controller.current?.id, a.id);
      expect(player.playing, isTrue);
      expect(player.log, isEmpty);
    });

    test('playing something outside the queue goes to the queue’s head',
        () async {
      final a = await seed('A');
      final x = await seed('X', queue: false);
      await controller.playWork(x);

      await controller.nextEpisode();

      expect(controller.current?.id, a.id);
    });

    test('Play pressed by hand forgets what was passed over', () async {
      final a = await seed('A');
      final b = await seed('B');
      final x = await seed('X', queue: false);
      await controller.playWork(a);
      await controller.nextEpisode();
      await controller.playWork(x);

      player.emitCompleted();
      await pumpEventQueue();

      expect(controller.current?.id, a.id);
      expect(await queue(), [a.id, b.id]);
    });
  });

  group('Previous episode', () {
    test('some way in: back to the start of this episode', () async {
      final a = await seed('A');
      final b = await seed('B');
      await controller.playWork(a);
      await controller.nextEpisode();
      player.emitPosition(const Duration(minutes: 3));

      await controller.previousEpisode();

      expect(controller.current?.id, b.id);
      expect(player.position, Duration.zero);
      expect(player.playing, isTrue);
    });

    test('just started: back to the episode left, at its own place',
        () async {
      final a = await seed('A');
      await seed('B');
      await controller.playWork(a);
      player.emitPosition(const Duration(minutes: 7));
      await controller.nextEpisode();
      player.emitPosition(const Duration(seconds: 2));

      await controller.previousEpisode();
      await pumpEventQueue();

      expect(controller.current?.id, a.id);
      expect(player.position, const Duration(minutes: 7));
    });

    test('walks back one episode a press, and does not bounce', () async {
      final a = await seed('A');
      final b = await seed('B');
      final c = await seed('C');
      await controller.playWork(a);
      await controller.nextEpisode();
      await controller.nextEpisode();
      expect(controller.current?.id, c.id);

      await controller.previousEpisode();
      expect(controller.current?.id, b.id);
      await controller.previousEpisode();
      expect(controller.current?.id, a.id);
    });

    test('an episode that finished by itself is the one behind', () async {
      final a = await seed('A');
      await seed('B');
      await controller.playWork(a);
      player.emitCompleted();
      await pumpEventQueue();

      await controller.previousEpisode();
      await pumpEventQueue();

      expect(controller.current?.id, a.id);
    });

    test('nothing behind: the start of this episode', () async {
      final a = await seed('A');
      await controller.playWork(a);
      player.emitPosition(const Duration(seconds: 2));

      await controller.previousEpisode();

      expect(controller.current?.id, a.id);
      expect(player.position, Duration.zero);
    });

    test('after a restart, with the audio not yet loaded: it loads and goes '
        'to the start', () async {
      final a = await seed('A');
      await db.feedsDao.savePlayerPosition(
          profileId: profileId, workId: a.id, tMs: 180000);
      await db.profilesDao.recordLastPlayed(profileId, a.id);
      await controller.rehydrateLastPlayed();
      expect(controller.isLoaded(a.id), isFalse);

      await controller.previousEpisode();

      expect(controller.isLoaded(a.id), isTrue);
      expect(player.position, Duration.zero);
      expect(player.playing, isTrue);
    });

    test('X forgets what was behind', () async {
      final a = await seed('A');
      final b = await seed('B');
      await controller.playWork(a);
      await controller.nextEpisode();
      await controller.stop();
      await controller.playWork(b);
      player.emitPosition(const Duration(seconds: 1));

      await controller.previousEpisode();

      expect(controller.current?.id, b.id);
    });
  });

  group('the real app wires the keys', () {
    late TrellisAudioHandler session;
    setUp(() {
      session = TrellisAudioHandler();
      debugPlaybackSession = session;
    });
    tearDown(() => debugPlaybackSession = null);

    Future<void> boot(WidgetTester tester) async {
      await tester.pumpWidget(TrellisApp(
          db: db,
          fetcher: ScriptedFetcher((url, _) => throw UnimplementedError()),
          createPlayer: () => player));
      await tester.pumpAndSettle();
    }

    testWidgets('with no setup, the Previous key (a triple tap on most '
        'earbuds) moves on to the next episode', (tester) async {
      final a = await tester.runAsync(() => seed('A'));
      await boot(tester);

      await tester.runAsync(() async {
        await session.click(MediaButton.previous);
        await pumpEventQueue();
      });
      await tester.pump();

      expect(player.loadedUrl, a!.sourceUrl);
    });

    testWidgets('both episode keys are bound, and let go with the shell',
        (tester) async {
      await boot(tester);
      expect(session.onNextEpisode, isNotNull);
      expect(session.onPreviousEpisode, isNotNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(session.onNextEpisode, isNull,
          reason: 'a key must not reach a player that has been let go');
      expect(session.onPreviousEpisode, isNull);
    });
  });
}
