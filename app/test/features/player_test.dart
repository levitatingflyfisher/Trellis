import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/mini_player_bar.dart';
import 'package:trellis/features/player/player_controller.dart';

import '../support/fake_player.dart';

/// Episode playback under the cursor law (ADR-0002): when alignments exist,
/// listening progress writes the SAME Position row the reader reads via a
/// time→segmentIdx projection; without alignments the honest fallback is a
/// raw tMs in player_positions. Finishing an episode is the user's hand —
/// it promotes the ephemeron (ADR-0003 law 2).
void main() {
  late AppDatabase db;
  late FakeEpisodePlayer player;
  late PlayerController controller;
  late int profileId;
  late int feedId;
  final nowMs = DateTime.utc(2026, 8, 6, 9).millisecondsSinceEpoch;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    player = FakeEpisodePlayer();
    profileId = await db.profilesDao.create('Ada');
    feedId = await db.feedsDao
        .insertFeed(profileId: profileId, url: 'https://cast.test/feed');
    controller = PlayerController(
        db: db,
        profileId: profileId,
        createPlayer: () => player,
        now: () => DateTime.fromMillisecondsSinceEpoch(nowMs));
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
  });

  Future<Work> seedEpisode(
      {String title = 'Ep 1',
      String enclosure = 'https://cast.test/1.mp3',
      bool withAlignments = false}) async {
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
        guid: 'guid-$title',
        enclosureUrl: enclosure,
        publishedAtMs: 1000);
    if (withAlignments) {
      await db.spineDao.insertSegments(workId, const [
        (idx: 0, kind: 'prose', text: 'First sentence.'),
        (idx: 1, kind: 'prose', text: 'Second sentence.'),
      ]);
      await db.spineDao.insertAlignments(workId, const [
        (segmentIdx: 0, tStartMs: 0, tEndMs: 10000),
        (segmentIdx: 1, tStartMs: 10000, tEndMs: 20000),
      ]);
    }
    return (await db.spineDao.worksOf(profileId))
        .firstWhere((w) => w.id == workId);
  }

  group('PlayerController', () {
    test('playWork loads the enclosure (work.sourceUrl), plays, marks read',
        () async {
      final work = await seedEpisode();
      await controller.playWork(work);

      expect(player.loadedUrl, 'https://cast.test/1.mp3');
      expect(player.playing, isTrue);
      expect(controller.current?.id, work.id);
      expect((await db.feedsDao.episodeOf(work.id))!.readAtMs, nowMs);
    });

    test('playWork on the current episode toggles pause/resume', () async {
      final work = await seedEpisode();
      await controller.playWork(work);
      await controller.playWork(work);
      expect(player.playing, isFalse);
      await controller.playWork(work);
      expect(player.playing, isTrue);
    });

    test('WITHOUT alignments, pause stores raw tMs in player_positions '
        '— and never invents a Position row', () async {
      final work = await seedEpisode();
      await controller.playWork(work);
      player.emitPosition(const Duration(seconds: 90));

      await controller.toggle(); // pause

      final raw = await db.feedsDao
          .playerPosition(profileId: profileId, workId: work.id);
      expect(raw!.tMs, 90000);
      expect(await db.spineDao.position(profileId: profileId, workId: work.id),
          isNull);
    });

    test('WITH alignments, pause projects time→segmentIdx and writes the '
        'SAME Position row the reader reads', () async {
      final work = await seedEpisode(withAlignments: true);
      await controller.playWork(work);
      player.emitPosition(const Duration(seconds: 15)); // inside segment 1

      await controller.toggle();

      final pos = await db.spineDao
          .position(profileId: profileId, workId: work.id);
      expect(pos!.segmentIdx, 1);
      expect(pos.lastModality, 'listen');
      expect(await db.feedsDao.allPlayerPositions(), isEmpty,
          reason: 'the projection replaces the raw fallback');
    });

    test('resume WITHOUT alignments seeks to the stored tMs', () async {
      final work = await seedEpisode();
      await db.feedsDao.savePlayerPosition(
          profileId: profileId, workId: work.id, tMs: 60000);

      await controller.playWork(work);
      expect(player.log, contains('seek:60000'));
    });

    test('resume WITH alignments projects the reader\'s Position row back '
        'to audio time (stop reading → resume listening)', () async {
      final work = await seedEpisode(withAlignments: true);
      await db.spineDao.savePosition(
          profileId: profileId,
          workId: work.id,
          segmentIdx: 1,
          wordIdx: 0,
          lastModality: 'read');

      await controller.playWork(work);
      expect(player.log, contains('seek:10000'),
          reason: 'segment 1 starts at 10000ms');
    });

    test('completion is a finish: the ephemeron is promoted and stamped',
        () async {
      final work = await seedEpisode();
      await controller.playWork(work);
      player.emitCompleted();
      await pumpEventQueue();

      final after = (await db.spineDao.worksOf(profileId)).single;
      expect(after.persistence, 'work',
          reason: 'finishing is the user\'s hand (ADR-0003 law 2)');
      expect(after.finishedEpochDay, nowMs ~/ Duration.millisecondsPerDay);
      expect(controller.playing, isFalse);
    });

    test('a learned duration is written back onto the episode row',
        () async {
      final work = await seedEpisode();
      await controller.playWork(work);
      player.emitDuration(const Duration(minutes: 31));
      await pumpEventQueue();

      expect((await db.feedsDao.episodeOf(work.id))!.durationMs,
          31 * 60 * 1000);
    });

    test('speed cycles 1.0 → 1.25 → 1.5 → 1.75 → 2.0 → 1.0', () async {
      final work = await seedEpisode();
      await controller.playWork(work);
      final seen = <double>[];
      for (var i = 0; i < 5; i++) {
        await controller.cycleSpeed();
        seen.add(controller.speed);
      }
      expect(seen, [1.25, 1.5, 1.75, 2.0, 1.0]);
      expect(player.lastSpeed, 1.0);
    });

    test('seekBy clamps into [0, duration]', () async {
      final work = await seedEpisode();
      await controller.playWork(work);
      player.emitDuration(const Duration(seconds: 100));
      player.emitPosition(const Duration(seconds: 5));

      await controller.seekBy(const Duration(seconds: -15));
      expect(player.position, Duration.zero);

      player.emitPosition(const Duration(seconds: 95));
      await controller.seekBy(const Duration(seconds: 30));
      expect(player.position, const Duration(seconds: 100));
    });

    test('switching episodes saves the outgoing progress first', () async {
      final first = await seedEpisode(title: 'One');
      final second = await seedEpisode(
          title: 'Two', enclosure: 'https://cast.test/2.mp3');
      await controller.playWork(first);
      player.emitPosition(const Duration(seconds: 42));

      await controller.playWork(second);

      final saved = await db.feedsDao
          .playerPosition(profileId: profileId, workId: first.id);
      expect(saved!.tMs, 42000);
      expect(player.loadedUrl, 'https://cast.test/2.mp3');
    });

    test('stop saves progress and clears the bar', () async {
      final work = await seedEpisode();
      await controller.playWork(work);
      player.emitPosition(const Duration(seconds: 30));

      await controller.stop();

      expect(controller.current, isNull);
      expect((await db.feedsDao
              .playerPosition(profileId: profileId, workId: work.id))!
          .tMs, 30000);
    });
  });

  group('MiniPlayerBar', () {
    Future<void> pumpBar(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: MiniPlayerBar(controller: controller),
        ),
      ));
      await tester.pump();
    }

    testWidgets('hidden while nothing plays; appears with the episode title',
        (tester) async {
      await pumpBar(tester);
      expect(find.byKey(const Key('mini-player')), findsNothing);

      final work = await seedEpisode(title: 'Aurora season');
      await controller.playWork(work);
      await tester.pump();

      expect(find.byKey(const Key('mini-player')), findsOneWidget);
      expect(find.text('Aurora season'), findsOneWidget);
    });

    testWidgets('transport controls drive the seam', (tester) async {
      final work = await seedEpisode();
      await controller.playWork(work);
      await pumpBar(tester);
      player.emitDuration(const Duration(minutes: 10));
      player.emitPosition(const Duration(minutes: 5));
      await tester.pump();

      await tester.tap(find.byKey(const Key('player-toggle')));
      await tester.pump();
      expect(player.playing, isFalse);

      await tester.tap(find.byKey(const Key('player-back15')));
      await tester.pump();
      expect(player.log, contains('seek:${(5 * 60 - 15) * 1000}'));

      await tester.tap(find.byKey(const Key('player-fwd30')));
      await tester.pump();

      await tester.tap(find.byKey(const Key('player-speed')));
      await tester.pump();
      expect(find.text('1.25×'), findsOneWidget);

      await tester.tap(find.byKey(const Key('player-close')));
      await tester.pump();
      expect(find.byKey(const Key('mini-player')), findsNothing);
    });

    testWidgets('the seek slider maps its full range onto the duration',
        (tester) async {
      final work = await seedEpisode();
      await controller.playWork(work);
      await pumpBar(tester);
      player.emitDuration(const Duration(minutes: 10));
      await tester.pump();

      final slider = find.byKey(const Key('player-slider'));
      expect(slider, findsOneWidget);
      await tester.drag(slider, const Offset(400, 0));
      await tester.pump();
      expect(player.position, const Duration(minutes: 10),
          reason: 'dragging to the far right seeks to the end');
    });
  });
}
