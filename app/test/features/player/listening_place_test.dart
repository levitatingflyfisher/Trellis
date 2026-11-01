import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/episode_player.dart';
import 'package:trellis/features/player/player_controller.dart';

import '../../support/fake_player.dart';

/// 1.5.9, user: "I'll listen for 30 minutes, leave, come back, and I've
/// lost my place because I'm back to where I started." The place was only
/// written by the app's own verbs (its Pause, its X, the next episode); a
/// pause from the lock screen, the notification, a headset or the widget
/// went straight to the engine, so a process the system later killed took
/// the whole session with it.
void main() {
  late AppDatabase db;
  late FakeEpisodePlayer player;
  late int profileId;
  late int feedId;
  late int clockMs;
  final controllers = <PlayerController>[];

  EpisodePlayer nextPlayer() {
    player = FakeEpisodePlayer();
    return player;
  }

  PlayerController newController() {
    final c = PlayerController(
      db: db,
      profileId: profileId,
      createPlayer: nextPlayer,
      now: () => DateTime.fromMillisecondsSinceEpoch(clockMs),
      haptic: () async {},
    );
    controllers.add(c);
    return c;
  }

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
    feedId = await db.feedsDao
        .insertFeed(profileId: profileId, url: 'https://cast.test/feed');
    clockMs = DateTime.utc(2026, 11, 5, 9).millisecondsSinceEpoch;
  });
  tearDown(() async {
    for (final c in controllers) {
      c.dispose();
    }
    controllers.clear();
    await db.close();
  });

  Future<Work> seedEpisode({bool withAlignments = false}) async {
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Ep 1',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/1.mp3');
    await db.feedsDao.insertEpisode(
        workId: workId,
        feedId: feedId,
        guid: 'guid-1',
        enclosureUrl: 'https://cast.test/1.mp3',
        publishedAtMs: 1000);
    if (withAlignments) {
      await db.spineDao.insertSegments(workId, [
        for (var i = 0; i < 60; i++)
          (idx: i, kind: 'prose', text: 'Minute $i.'),
      ]);
      await db.spineDao.insertAlignments(workId, [
        for (var i = 0; i < 60; i++)
          (segmentIdx: i, tStartMs: i * 60000, tEndMs: (i + 1) * 60000),
      ]);
    }
    return (await db.spineDao.workById(workId))!;
  }

  Future<int> savedMs(int workId) async =>
      (await db.feedsDao.playerPosition(profileId: profileId, workId: workId))
          ?.tMs ??
      0;

  /// Plays on for [d], one engine tick a second, the clock keeping pace:
  /// what a real session does with no hand on the app.
  Future<void> listen(Duration d) async {
    final end = player.position + d;
    while (player.position < end) {
      clockMs += 1000;
      player.emitPosition(player.position + const Duration(seconds: 1));
      await pumpEventQueue();
    }
  }

  group('position saved periodically while playing regardless of entry '
      'point', () {
    // Each entry point, as it reaches the controller. The process then
    // dies with no pause, stop or dispose: no goodbye is ever said.
    final entries = <String, Future<void> Function(PlayerController, Work)>{
      'in-app Play': (c, w) => c.playWork(w),
      'the bar restored at launch': (c, w) async {
        await db.profilesDao.recordLastPlayed(profileId, w.id);
        await c.rehydrateLastPlayed();
        await c.toggle();
      },
      'the home-screen widget after X': (c, w) async {
        await db.profilesDao.recordLastPlayed(profileId, w.id);
        await db.profilesDao.recordPlayerClosed(profileId);
        await c.rehydrateLastPlayed(evenIfClosed: true);
        await c.toggle();
      },
      'the lock screen resuming a paused player': (c, w) async {
        await c.playWork(w);
        await c.toggle();
        // The media session's play goes straight to the engine.
        await player.play();
      },
    };
    for (final MapEntry(key: name, value: start) in entries.entries) {
      test(name, () async {
        final work = await seedEpisode();
        final c = newController();
        await start(c, work);
        expect(player.playing, isTrue);

        await listen(const Duration(minutes: 30));
        // Killed here: no save on the way out.
        final lost = player.position.inMilliseconds - await savedMs(work.id);
        expect(lost, lessThanOrEqualTo(15000),
            reason: 'at most 15 s of a 30-minute session may be lost');
      });
    }

    test('on a transcribed episode the shared Position row keeps up too',
        () async {
      final work = await seedEpisode(withAlignments: true);
      final c = newController();
      await c.playWork(work);
      await listen(const Duration(minutes: 30));
      final pos = await db.spineDao
          .position(profileId: profileId, workId: work.id);
      expect(pos?.segmentIdx, inInclusiveRange(29, 30));
    });

    test('a paused player writes nothing on its own', () async {
      final work = await seedEpisode();
      final c = newController();
      await c.playWork(work);
      await listen(const Duration(minutes: 1));
      await c.toggle();
      final before = await db.feedsDao
          .playerPosition(profileId: profileId, workId: work.id);
      clockMs += 60000;
      player.emitPosition(player.position); // a stray tick while paused
      await pumpEventQueue();
      final after = await db.feedsDao
          .playerPosition(profileId: profileId, workId: work.id);
      expect(after?.updatedAtMs, before?.updatedAtMs);
    });
  });

  group('media-session pause and stop persist the position', () {
    test('pause from the lock screen / notification / headset', () async {
      final work = await seedEpisode();
      final c = newController();
      await c.playWork(work);
      player.emitPosition(const Duration(minutes: 12, seconds: 3));
      // The media session pauses the engine; the app hears only that it
      // stopped playing.
      await player.pause();
      await pumpEventQueue();
      expect(await savedMs(work.id), 723000);
    });

    test('stop from the notification', () async {
      final work = await seedEpisode();
      final c = newController();
      await c.playWork(work);
      player.emitPosition(const Duration(minutes: 7));
      player.externalStop();
      await pumpEventQueue();
      expect(await savedMs(work.id), 420000);
    });

    // just_audio reports where this stretch of playing began once the
    // notification's Stop has let the engine go: the reported place was
    // "back to where I started" without any process dying.
    test('stop from the notification after a stretch of listening keeps '
        'where it ended, not where it began', () async {
      final work = await seedEpisode();
      await db.feedsDao.savePlayerPosition(
          profileId: profileId, workId: work.id, tMs: 52000);
      final c = newController();
      await c.playWork(work);
      await listen(const Duration(seconds: 45));
      player.externalStop(snapBackTo: const Duration(seconds: 52));
      await pumpEventQueue();
      expect(await savedMs(work.id), 97000);

      // Play in the app afterwards picks up there too, back a breath
      // (smart resume, which an outside stop now gets as well).
      player.log.clear();
      await c.toggle();
      expect(player.log, contains('seek:95000'));
      expect(player.playing, isTrue);
    });

    test('X after the notification\'s Stop keeps where it ended', () async {
      final work = await seedEpisode();
      await db.feedsDao.savePlayerPosition(
          profileId: profileId, workId: work.id, tMs: 52000);
      final c = newController();
      await c.playWork(work);
      await listen(const Duration(seconds: 45));
      player.externalStop(snapBackTo: const Duration(seconds: 52));
      await c.stop();
      expect(await savedMs(work.id), 97000);
    });

    test('a skip from the lock screen or the bar is kept at once', () async {
      final work = await seedEpisode();
      final c = newController();
      await c.playWork(work);
      await c.toggle();
      await c.seekBy(const Duration(seconds: 30));
      expect(await savedMs(work.id), 30000);
      await c.seekTo(const Duration(minutes: 20));
      expect(await savedMs(work.id), 1200000);
    });
  });

  // 1.5.9 review (I1): the media session's seek bar works while paused
  // too. A scrub there is the engine speaking, not a snap-back, and the
  // place heard before it must not win over it.
  group('a scrub from outside while paused sticks', () {
    Future<(PlayerController, Work)> pausedOutsideAfterScrub() async {
      final work = await seedEpisode();
      final c = newController();
      await c.playWork(work);
      await listen(const Duration(minutes: 2));
      player.externalPause(snapBackTo: Duration.zero);
      await pumpEventQueue();
      player.externalSeek(const Duration(seconds: 30));
      await pumpEventQueue();
      return (c, work);
    }

    test('Play in the app starts from the scrub, not the older place',
        () async {
      final (c, _) = await pausedOutsideAfterScrub();
      player.log.clear();
      await c.toggle();
      expect(player.playing, isTrue);
      expect(player.position, lessThanOrEqualTo(const Duration(seconds: 30)));
      expect(player.position,
          greaterThanOrEqualTo(const Duration(seconds: 20)));
    });

    test('X saves the scrubbed place', () async {
      final (c, work) = await pausedOutsideAfterScrub();
      await c.stop();
      expect(await savedMs(work.id), 30000);
    });

    test('a skip starts from the scrubbed place', () async {
      final (c, work) = await pausedOutsideAfterScrub();
      await c.seekBy(const Duration(seconds: 10));
      expect(player.position, const Duration(seconds: 40));
      expect(await savedMs(work.id), 40000);
    });

    test('the scrub is saved at once: a kill keeps it', () async {
      final (_, work) = await pausedOutsideAfterScrub();
      expect(await savedMs(work.id), 30000);
    });

    test('an in-app seek back while paused sticks too', () async {
      final work = await seedEpisode();
      final c = newController();
      await c.playWork(work);
      await listen(const Duration(minutes: 2));
      await c.toggle();
      await c.seekTo(const Duration(seconds: 30));
      expect(await savedMs(work.id), 30000);
      await c.toggle();
      expect(player.position, lessThanOrEqualTo(const Duration(seconds: 30)));
    });

    test('the engine\'s idle report as the notification\'s Stop lets it go '
        'is no scrub', () async {
      final work = await seedEpisode();
      await db.feedsDao.savePlayerPosition(
          profileId: profileId, workId: work.id, tMs: 52000);
      final c = newController();
      await c.playWork(work);
      await listen(const Duration(seconds: 45));
      player.externalStop(
          snapBackTo: const Duration(seconds: 52), releasedAt: Duration.zero);
      await pumpEventQueue();
      expect(await savedMs(work.id), 97000);
      await c.stop();
      expect(await savedMs(work.id), 97000);
    });
  });

  group('an outside pause', () {
    test('snapped back, Play in the app resumes from the place heard',
        () async {
      final work = await seedEpisode();
      await db.feedsDao.savePlayerPosition(
          profileId: profileId, workId: work.id, tMs: 52000);
      final c = newController();
      await c.playWork(work);
      await listen(const Duration(seconds: 45));
      player.externalPause(snapBackTo: const Duration(seconds: 52));
      await pumpEventQueue();
      expect(await savedMs(work.id), 97000);
      player.log.clear();
      await c.toggle();
      // Back a breath from where it stopped (smart resume), never to the
      // start of the stretch.
      expect(player.log, contains('seek:95000'));
    });

    test('ExoPlayer\'s later report of where it paused is kept', () async {
      final work = await seedEpisode();
      await db.feedsDao.savePlayerPosition(
          profileId: profileId, workId: work.id, tMs: 52000);
      final c = newController();
      await c.playWork(work);
      await listen(const Duration(seconds: 45));
      player.externalPause(snapBackTo: const Duration(seconds: 52));
      await pumpEventQueue();
      player.emitPosition(const Duration(milliseconds: 97400));
      await pumpEventQueue();
      expect(await savedMs(work.id), 97400);
      await c.stop();
      expect(await savedMs(work.id), 97400);
    });

    test('gets the smart-resume rewind, as the app\'s own Pause does',
        () async {
      final work = await seedEpisode();
      final c = newController();
      await c.playWork(work);
      await listen(const Duration(minutes: 5));
      player.externalPause();
      await pumpEventQueue();
      clockMs += const Duration(minutes: 10).inMilliseconds;
      player.log.clear();
      await c.toggle();
      expect(player.log, contains('seek:295000'));
    });
  });

  test('a save that fails from a stream is logged, not thrown', () async {
    final work = await seedEpisode();
    final c = newController();
    await c.playWork(work);
    await db.close(); // every write now fails
    final logged = <String?>[];
    final saved = debugPrint;
    debugPrint = (m, {wrapWidth}) => logged.add(m);
    try {
      player.externalPause();
      await listen(Duration.zero);
      await pumpEventQueue();
    } finally {
      debugPrint = saved;
    }
    expect(logged, contains(startsWith('Player: saving')));
  });

  test('periodic saves go on when the clock steps back', () async {
    final work = await seedEpisode();
    final c = newController();
    await c.playWork(work);
    await listen(const Duration(minutes: 1));
    clockMs -= const Duration(hours: 1).inMilliseconds;
    await listen(const Duration(minutes: 5));
    final lost = player.position.inMilliseconds - await savedMs(work.id);
    expect(lost, lessThanOrEqualTo(15000));
  });

  test('an audiobook\'s place stays in the file the engine moved on to',
      () async {
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'audiobook',
        title: 'A Book',
        persistence: 'work',
        firstSeenEpochDay: 100);
    await db.audiobooksDao.insertAudiobook(workId);
    await db.audiobooksDao
        .insertFiles(workId, const ['/books/1/0.mp3', '/books/1/1.mp3']);
    final work = (await db.spineDao.workById(workId))!;
    final c = newController();
    await c.playAudiobook(work);
    player.emitPosition(const Duration(minutes: 5));
    // The engine crosses into the next file and is paused from outside
    // before its first tick there.
    player.emitCurrentIndex(1);
    player.movePositionQuietly(const Duration(seconds: 1));
    player.externalPause();
    await pumpEventQueue();
    final row =
        await db.feedsDao.playerPosition(profileId: profileId, workId: workId);
    expect((row?.fileIdx, row?.tMs), (1, 1000));
  });

  test('a tick during an episode switch never marks the new one played',
      () async {
    final first = await seedEpisode();
    final secondId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Ep 2',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/2.mp3');
    await db.feedsDao.insertEpisode(
        workId: secondId,
        feedId: feedId,
        guid: 'guid-2',
        enclosureUrl: 'https://cast.test/2.mp3',
        publishedAtMs: 2000);
    final second = (await db.spineDao.workById(secondId))!;
    final c = newController();
    await c.playWork(first);
    player.emitDuration(const Duration(minutes: 30));
    player.emitPosition(const Duration(minutes: 10));
    player.loadGate = Completer<void>();
    final loading = c.playWork(second);
    while (c.current?.id != secondId) {
      await Future<void>.delayed(Duration.zero);
    }
    // The engine still on the first episode's last minute.
    player.emitPosition(const Duration(minutes: 29, seconds: 50));
    await pumpEventQueue();
    expect((await db.feedsDao.episodeOf(secondId))?.finishedAtMs, isNull);
    player.loadGate!.complete();
    await loading;
    expect(second.id, secondId);
  });

  test('resume from any entry point reads the persisted position, not a '
      'cached one', () async {
    final work = await seedEpisode();
    await db.feedsDao
        .savePlayerPosition(profileId: profileId, workId: work.id, tMs: 300000);
    await db.profilesDao.recordLastPlayed(profileId, work.id);
    final c = newController();
    await c.rehydrateLastPlayed();
    expect(c.rehydratedPositionMs, 300000);
    // Meanwhile the place moved on (the reader, the last session's final
    // save): the bar's snapshot is stale.
    await db.feedsDao.savePlayerPosition(
        profileId: profileId, workId: work.id, tMs: 1500000);
    await c.toggle(); // the widget's Play and the bar's Play both land here
    expect(player.log, contains('seek:1500000'));
    expect(player.position, const Duration(minutes: 25));
  });

  test('an older position never overwrites a newer one', () async {
    final work = await seedEpisode(withAlignments: true);
    final c = newController();
    await c.playWork(work);
    player.emitPosition(const Duration(minutes: 10, seconds: 30));
    // X: the place is read now, but written only once the engine has
    // let go, and the engine is slow about it.
    player.pauseGate = Completer<void>();
    final closing = c.stop();
    await pumpEventQueue();
    // Meanwhile the reader moves the place on, to minute 40.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await db.spineDao.savePosition(
        profileId: profileId,
        workId: work.id,
        segmentIdx: 40,
        wordIdx: 0,
        lastModality: 'read');
    player.pauseGate!.complete();
    await closing;
    final pos =
        await db.spineDao.position(profileId: profileId, workId: work.id);
    expect(pos?.segmentIdx, 40);
  });

  test('a late write of an older place leaves a newer raw place alone',
      () async {
    final work = await seedEpisode();
    final readAt = DateTime.now().millisecondsSinceEpoch - 1000;
    await db.feedsDao.savePlayerPosition(
        profileId: profileId, workId: work.id, tMs: 900000);
    await db.feedsDao.savePlayerPosition(
        profileId: profileId, workId: work.id, tMs: 60000, readAtMs: readAt);
    expect(await savedMs(work.id), 900000);
    // Nothing newer meanwhile: the late write lands, stamped when read.
    await db.feedsDao.savePlayerPosition(
        profileId: profileId,
        workId: work.id,
        tMs: 960000,
        readAtMs: readAt + 5000);
    final row = await db.feedsDao
        .playerPosition(profileId: profileId, workId: work.id);
    expect(row?.tMs, 960000);
    expect(row?.updatedAtMs, readAt + 5000);
  });
}
