import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loom_core/loom_core.dart' as core;
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/mini_player_bar.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/player/shake_detector.dart';
import 'package:trellis/features/player/sleep_timer.dart';

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
  // A mutable clock for the smart-resume tests, which need to advance time
  // between pause and resume. Every other test never touches it, so it
  // stays equal to the fixed nowMs above and their assertions are unaffected.
  late int clockMs;
  // Counts the sleep timer's haptic-before-stop calls; no test but the
  // sleep timer ones ever triggers it, so this stays 0 for everyone else.
  late int hapticCalls;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    player = FakeEpisodePlayer();
    profileId = await db.profilesDao.create('Ada');
    feedId = await db.feedsDao
        .insertFeed(profileId: profileId, url: 'https://cast.test/feed');
    clockMs = nowMs;
    hapticCalls = 0;
    controller = PlayerController(
        db: db,
        profileId: profileId,
        createPlayer: () => player,
        now: () => DateTime.fromMillisecondsSinceEpoch(clockMs),
        haptic: () async {
          hapticCalls++;
        });
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

    group('listenFrom — the study crown\'s "Listen from here" verb', () {
      test('a work not yet playing: starts it and jumps straight to the '
          'projected audio time (not the stored resume position)', () async {
        final work = await seedEpisode(withAlignments: true);
        await db.spineDao.savePosition(
            profileId: profileId,
            workId: work.id,
            segmentIdx: 0,
            wordIdx: 0,
            lastModality: 'listen'); // a stale resume point at segment 0

        await controller.listenFrom(
            work,
            const core.Position(
                segmentIdx: 1, wordIdx: 3, lastModality: core.Modality.read));

        expect(player.loadedUrl, work.sourceUrl);
        expect(player.log.last, 'seek:10000',
            reason: 'segment 1 starts at 10000ms — the jump wins over the '
                'stale resume seek that ran first inside playWork');
      });

      test('the SAME work already playing: always jumps (never toggles '
          'play/pause the way a re-tapped playWork would)', () async {
        final work = await seedEpisode(withAlignments: true);
        await controller.playWork(work);
        expect(player.playing, isTrue);

        await controller.listenFrom(
            work,
            const core.Position(
                segmentIdx: 1, wordIdx: 0, lastModality: core.Modality.read));

        expect(player.playing, isTrue,
            reason: 'a deliberate jump, never a toggle');
        expect(player.log.last, 'seek:10000');
      });

      test('a work with no alignments: still starts playback, but there is '
          'nothing to project through, so no seek is forced', () async {
        final work = await seedEpisode(); // no alignments
        await controller.listenFrom(
            work,
            const core.Position(
                segmentIdx: 0, wordIdx: 0, lastModality: core.Modality.read));

        expect(player.playing, isTrue);
        expect(player.log.any((l) => l.startsWith('seek:')), isFalse);
      });
    });

    group('capture — the study crown\'s "Capture" verb', () {
      test('saves a capture at the current playback position, sentence-'
          'bound immediately when the work is already aligned', () async {
        final work = await seedEpisode(withAlignments: true);
        await controller.playWork(work);
        player.emitPosition(const Duration(seconds: 12)); // inside segment 1

        final id = await controller.capture();

        expect(id, isNotNull);
        final saved = (await db.capturesDao.capturesOf(work.id)).single;
        expect(saved.positionMs, 12000);
        expect(saved.segmentIdx, 1);
      });

      test('a work with no transcript yet: still saves, unbound', () async {
        final work = await seedEpisode();
        await controller.playWork(work);
        player.emitPosition(const Duration(seconds: 12));

        await controller.capture();

        final saved = (await db.capturesDao.capturesOf(work.id)).single;
        expect(saved.segmentIdx, isNull);
      });

      test('nothing playing: a no-op, never throws', () async {
        expect(await controller.capture(), isNull);
      });
    });

    test('smart resume: a pause under a minute rewinds 2s on resume',
        () async {
      final work = await seedEpisode();
      await controller.playWork(work);
      player.emitPosition(const Duration(seconds: 100));
      await controller.toggle(); // pause
      clockMs += 30000; // 30s later, still under a minute

      await controller.toggle(); // resume

      expect(player.log, contains('seek:${100000 - 2000}'));
      expect(player.playing, isTrue);
    });

    test('smart resume: a pause of an hour or more rewinds 10s on resume',
        () async {
      final work = await seedEpisode();
      await controller.playWork(work);
      player.emitPosition(const Duration(minutes: 5));
      await controller.toggle(); // pause
      clockMs += const Duration(hours: 2).inMilliseconds;

      await controller.toggle(); // resume

      expect(player.log, contains('seek:${5 * 60 * 1000 - 10000}'));
    });

    test('smart resume never rewinds past zero', () async {
      final work = await seedEpisode();
      await controller.playWork(work);
      player.emitPosition(const Duration(seconds: 3));
      await controller.toggle(); // pause
      clockMs += const Duration(hours: 2).inMilliseconds;

      await controller.toggle(); // resume

      expect(player.log, contains('seek:0'));
    });

    test('a zero-length pause still rewinds — the <1min bracket has no '
        'floor', () async {
      final work = await seedEpisode();
      await controller.playWork(work);
      player.emitPosition(const Duration(seconds: 50));

      await controller.toggle(); // pause
      await controller.toggle(); // resume, no time elapsed either way

      expect(player.log, contains('seek:${50000 - 2000}'));
    });
  });

  group('per-podcast playback settings', () {
    test('a feed speed override wins over the global speed on start',
        () async {
      final work = await seedEpisode();
      await db.feedsDao.updatePlaybackSettings(feedId, speedOverride: 1.75);

      await controller.playWork(work);

      expect(player.lastSpeed, 1.75);
      expect(controller.speed, 1.0,
          reason: 'the global speed itself is untouched by a feed override');
    });

    test('no override defers to the global speed, unchanged', () async {
      final work = await seedEpisode();

      await controller.playWork(work);

      expect(player.lastSpeed, 1.0);
    });

    test('auto-seeks past the intro only when starting fresh (position 0)',
        () async {
      final work = await seedEpisode();
      await db.feedsDao
          .updatePlaybackSettings(feedId, skipIntroSeconds: 12);

      await controller.playWork(work);

      expect(player.log, contains('seek:12000'));
    });

    test('never auto-seeks past the intro when resuming a saved position',
        () async {
      final work = await seedEpisode();
      await db.feedsDao
          .updatePlaybackSettings(feedId, skipIntroSeconds: 12);
      await db.feedsDao.savePlayerPosition(
          profileId: profileId, workId: work.id, tMs: 60000);

      await controller.playWork(work);

      expect(player.log, contains('seek:60000'));
      expect(player.log, isNot(contains('seek:12000')));
    });

    test('stops/finishes at duration-minus-outro, exactly once even '
        'across repeated ticks past the cutoff', () async {
      final work = await seedEpisode();
      await db.feedsDao
          .updatePlaybackSettings(feedId, skipOutroSeconds: 30);
      await controller.playWork(work);
      player.emitDuration(const Duration(minutes: 10));

      // Three ticks past the cutoff (10:00 - 0:30 = 9:30) — a naive
      // listener re-fires the finish on every one of these.
      for (final s in [9 * 60 + 30, 9 * 60 + 45, 10 * 60]) {
        player.emitPosition(Duration(seconds: s));
        await pumpEventQueue();
      }

      expect(player.log.where((l) => l == 'pause'), hasLength(1),
          reason: 'the outro cutoff pauses playback exactly once');
      final after = (await db.spineDao.worksOf(profileId)).single;
      expect(after.persistence, 'work');
      expect(after.finishedEpochDay, nowMs ~/ Duration.millisecondsPerDay);
    });

    test('no outro setting: playback runs to the true end untouched',
        () async {
      final work = await seedEpisode();
      await controller.playWork(work);
      player.emitDuration(const Duration(minutes: 10));

      player.emitPosition(const Duration(minutes: 9, seconds: 59));
      await pumpEventQueue();

      expect(player.log, isNot(contains('pause')));
      expect(controller.current, isNotNull,
          reason: 'nothing finished it early');
    });
  });

  group('Up Next auto-advance', () {
    test('finishing removes the episode from the queue by default, then '
        'auto-advances to the new head', () async {
      final first = await seedEpisode(title: 'One');
      final second = await seedEpisode(
          title: 'Two', enclosure: 'https://cast.test/2.mp3');
      await db.queueDao
          .playLast(profileId: profileId, workId: first.id, nowMs: 1);
      await db.queueDao
          .playLast(profileId: profileId, workId: second.id, nowMs: 2);
      await controller.playWork(first);

      player.emitCompleted();
      await pumpEventQueue();

      expect(controller.current?.id, second.id);
      expect(player.loadedUrl, 'https://cast.test/2.mp3');
      final remaining = await db.queueDao.queueOf(profileId);
      expect(remaining.map((r) => r.workId), [second.id],
          reason: 'the finished episode is gone; the one it advanced to '
              'is still there, waiting for ITS turn to finish');
    });

    test('the household setting keeps a finished episode in the queue '
        'instead of removing it', () async {
      await db.profilesDao.setKeepFinishedInQueue(profileId, true);
      final first = await seedEpisode(title: 'One');
      final second = await seedEpisode(
          title: 'Two', enclosure: 'https://cast.test/2.mp3');
      await db.queueDao
          .playLast(profileId: profileId, workId: first.id, nowMs: 1);
      await db.queueDao
          .playLast(profileId: profileId, workId: second.id, nowMs: 2);
      await controller.playWork(first);

      player.emitCompleted();
      await pumpEventQueue();

      final remaining = await db.queueDao.queueOf(profileId);
      expect(remaining.map((r) => r.workId), contains(first.id),
          reason: 'kept, per the household setting');
    });

    test('an empty queue after finishing just stops — no crash, nothing '
        'to advance to', () async {
      final work = await seedEpisode();
      await controller.playWork(work);

      player.emitCompleted();
      await pumpEventQueue();

      expect(controller.current, isNotNull,
          reason: 'the finished work stays "current" (mirrors today\'s '
              'no-queue behavior) — nothing pulls it away');
    });

    test('the outro cutoff also auto-advances — both finish paths funnel '
        'through the same queue law', () async {
      final first = await seedEpisode(title: 'One');
      final second = await seedEpisode(
          title: 'Two', enclosure: 'https://cast.test/2.mp3');
      await db.feedsDao
          .updatePlaybackSettings(feedId, skipOutroSeconds: 30);
      await db.queueDao
          .playLast(profileId: profileId, workId: second.id, nowMs: 1);
      await controller.playWork(first);
      player.emitDuration(const Duration(minutes: 10));

      player.emitPosition(const Duration(minutes: 9, seconds: 30));
      await pumpEventQueue();

      expect(controller.current?.id, second.id);
    });

    test('auto-advance applies the next episode\'s own per-feed settings',
        () async {
      final otherFeedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://other.test/feed');
      final first = await seedEpisode(title: 'One');
      final secondWorkId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: 'Two',
          persistence: 'ephemeron',
          firstSeenEpochDay: 100,
          sourceUrl: 'https://other.test/2.mp3');
      await db.feedsDao.insertEpisode(
          workId: secondWorkId,
          feedId: otherFeedId,
          guid: 'guid-two',
          enclosureUrl: 'https://other.test/2.mp3',
          publishedAtMs: 1000);
      await db.feedsDao
          .updatePlaybackSettings(otherFeedId, speedOverride: 1.75);
      await db.queueDao
          .playLast(profileId: profileId, workId: secondWorkId, nowMs: 1);
      await controller.playWork(first);

      player.emitCompleted();
      await pumpEventQueue();

      expect(player.lastSpeed, 1.75);
    });
  });

  group('sleep timer', () {
    test('duration mode: remaining counts down from the armed duration',
        () async {
      final work = await seedEpisode();
      await controller.playWork(work);

      controller.startSleepTimer(duration: const Duration(minutes: 30));

      expect(controller.sleepTimerMode, SleepTimerMode.duration);
      clockMs += const Duration(minutes: 10).inMilliseconds;
      player.emitPosition(const Duration(minutes: 10));
      await pumpEventQueue();
      expect(controller.sleepTimerRemaining, const Duration(minutes: 20));
    });

    test('fades volume over the final 20 seconds', () async {
      final work = await seedEpisode();
      await controller.playWork(work);
      controller.startSleepTimer(duration: const Duration(minutes: 1));

      clockMs += const Duration(seconds: 50).inMilliseconds; // 10s left
      player.emitPosition(const Duration(seconds: 1));
      await pumpEventQueue();

      expect(player.lastVolume, closeTo(0.5, 1e-9));
    });

    test('duration mode pauses playback and resets volume when it fires',
        () async {
      final work = await seedEpisode();
      await controller.playWork(work);
      controller.startSleepTimer(duration: const Duration(minutes: 1));

      clockMs += const Duration(minutes: 1).inMilliseconds;
      player.emitPosition(const Duration(seconds: 1));
      await pumpEventQueue();

      expect(player.playing, isFalse);
      expect(player.lastVolume, 1.0);
      expect(controller.sleepTimerMode, isNull,
          reason: 'the timer is consumed once it fires');
    });

    test('a haptic fires once, shortly before stop', () async {
      final work = await seedEpisode();
      await controller.playWork(work);
      controller.startSleepTimer(duration: const Duration(minutes: 1));

      // Three ticks inside the final 3 seconds — the haptic must fire once,
      // not once per tick.
      for (final elapsedS in [58, 59, 60]) {
        clockMs = nowMs + Duration(seconds: elapsedS).inMilliseconds;
        player.emitPosition(const Duration(seconds: 1));
        await pumpEventQueue();
      }

      expect(hapticCalls, 1);
    });

    test('cancelSleepTimer clears the mode and remaining immediately', () async {
      final work = await seedEpisode();
      await controller.playWork(work);
      controller.startSleepTimer(duration: const Duration(minutes: 30));

      controller.cancelSleepTimer();

      expect(controller.sleepTimerMode, isNull);
      expect(controller.sleepTimerRemaining, isNull);
    });

    test('extendSleepTimer (shake) adds 10 minutes in duration mode',
        () async {
      final work = await seedEpisode();
      await controller.playWork(work);
      controller.startSleepTimer(duration: const Duration(minutes: 15));

      controller.extendSleepTimer();
      player.emitPosition(const Duration(seconds: 1));
      await pumpEventQueue();

      expect(controller.sleepTimerRemaining, const Duration(minutes: 25));
    });

    test('extendSleepTimer is a no-op in end-of-episode mode', () async {
      final work = await seedEpisode();
      await controller.playWork(work);
      player.emitDuration(const Duration(minutes: 40));
      controller.startSleepTimer(); // null duration == end of episode

      controller.extendSleepTimer();

      expect(controller.sleepTimerMode, SleepTimerMode.endOfEpisode);
    });

    test('end-of-episode mode: remaining tracks duration minus position',
        () async {
      final work = await seedEpisode();
      await controller.playWork(work);
      player.emitDuration(const Duration(minutes: 20));
      controller.startSleepTimer();

      player.emitPosition(const Duration(minutes: 18));
      await pumpEventQueue();

      expect(controller.sleepTimerRemaining, const Duration(minutes: 2));
    });

    test('end-of-episode mode never explicitly pauses — natural completion '
        'stops it and clears the timer', () async {
      final work = await seedEpisode();
      await controller.playWork(work);
      player.emitDuration(const Duration(seconds: 5));
      controller.startSleepTimer();

      player.emitPosition(const Duration(seconds: 5)); // 0 remaining
      await pumpEventQueue();
      expect(player.log, isNot(contains('pause')),
          reason: 'end-of-episode has no target of its own to pause at — '
              'natural completion is the only stop');

      player.emitCompleted();
      await pumpEventQueue();

      expect(controller.sleepTimerMode, isNull);
      expect(player.lastVolume, 1.0);
    });

    test('a duration-mode timer survives natural completion of the '
        'episode it was armed on', () async {
      final work = await seedEpisode();
      await controller.playWork(work);
      controller.startSleepTimer(duration: const Duration(hours: 1));

      player.emitCompleted();
      await pumpEventQueue();

      expect(controller.sleepTimerMode, SleepTimerMode.duration,
          reason: 'a 1-hour bedtime timer should keep running into '
              'whatever plays next, not die with this episode');
    });

    test('a fresh playWork resets volume to full', () async {
      final work = await seedEpisode();
      await controller.playWork(work);
      controller.startSleepTimer(duration: const Duration(seconds: 20));
      clockMs += const Duration(seconds: 15).inMilliseconds; // 5s left, fading
      player.emitPosition(const Duration(seconds: 1));
      await pumpEventQueue();
      expect(player.lastVolume, lessThan(1.0));

      final second = await seedEpisode(
          title: 'Two', enclosure: 'https://cast.test/2.mp3');
      await controller.playWork(second);

      expect(player.lastVolume, 1.0);
    });

    test('a real shake (fed through the injected accelerometer stream) '
        'extends the timer by 10 minutes', () async {
      final shakes = StreamController<AccelerationSample>.broadcast(sync: true);
      addTearDown(shakes.close);
      final shaky = PlayerController(
          db: db,
          profileId: profileId,
          createPlayer: () => player,
          now: () => DateTime.fromMillisecondsSinceEpoch(clockMs),
          accelerometerSamples: () => shakes.stream);
      addTearDown(shaky.dispose);
      final work = await seedEpisode();
      await shaky.playWork(work);
      shaky.startSleepTimer(duration: const Duration(minutes: 15));

      shakes.add(const AccelerationSample(30, 0, 0));

      expect(shaky.sleepTimerRemaining, const Duration(minutes: 25));
    });

    test('no accelerometer wired (the default) means shaking is simply '
        'unavailable — never a crash', () async {
      final work = await seedEpisode();
      await controller.playWork(work);
      controller.startSleepTimer(duration: const Duration(minutes: 15));
      // No accelerometerSamples was given to the shared `controller`; if
      // arming the timer tried to read a real sensor here, this test would
      // hang or throw under the plain VM test runner.
      expect(controller.sleepTimerRemaining, const Duration(minutes: 15));
    });

    test('cancelling the timer stops listening for shakes — a shake after '
        'cancel does nothing', () async {
      final shakes = StreamController<AccelerationSample>.broadcast(sync: true);
      addTearDown(shakes.close);
      final shaky = PlayerController(
          db: db,
          profileId: profileId,
          createPlayer: () => player,
          now: () => DateTime.fromMillisecondsSinceEpoch(clockMs),
          accelerometerSamples: () => shakes.stream);
      addTearDown(shaky.dispose);
      final work = await seedEpisode();
      await shaky.playWork(work);
      shaky.startSleepTimer(duration: const Duration(minutes: 15));
      shaky.cancelSleepTimer();

      shakes.add(const AccelerationSample(30, 0, 0));

      expect(shaky.sleepTimerMode, isNull);
    });
  });

  group('local file playback (Campaign 6)', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('trellis-local-play'));
    tearDown(() => dir.deleteSync(recursive: true));

    PlayerController withLocalFile(File Function(int, String) resolver) {
      final c = PlayerController(
          db: db,
          profileId: profileId,
          createPlayer: () => player,
          now: () => DateTime.fromMillisecondsSinceEpoch(clockMs),
          localAudioFileFor: resolver);
      addTearDown(c.dispose);
      return c;
    }

    test('a downloaded episode plays from the local file, not the URL',
        () async {
      final local = File('${dir.path}/1.mp3')..writeAsStringSync('bytes');
      final fromFile = withLocalFile((workId, url) => local);
      final work = await seedEpisode();

      await fromFile.playWork(work);

      expect(player.loadedFilePath, local.path);
      expect(player.loadedUrl, isNull);
    });

    test('an episode with no local file streams the URL exactly as before',
        () async {
      final missing = File('${dir.path}/never-downloaded.mp3');
      final streamer = withLocalFile((workId, url) => missing);
      final work = await seedEpisode();

      await streamer.playWork(work);

      expect(player.loadedUrl, 'https://cast.test/1.mp3');
      expect(player.loadedFilePath, isNull);
    });

    test('per-feed speed override and resume-from-position hold exactly '
        'the same when the source is a local file — the swap changes '
        'nothing downstream of loading', () async {
      final local = File('${dir.path}/1.mp3')..writeAsStringSync('bytes');
      final fromFile = withLocalFile((workId, url) => local);
      final work = await seedEpisode();
      await db.feedsDao.updatePlaybackSettings(feedId, speedOverride: 1.75);
      await db.feedsDao.savePlayerPosition(
          profileId: profileId, workId: work.id, tMs: 42000);

      await fromFile.playWork(work);

      expect(player.loadedFilePath, local.path);
      expect(player.lastSpeed, 1.75);
      expect(player.log, contains('seek:42000'));
    });

    test('eviction composes: once the local file is gone, playback falls '
        'back to streaming — "re-download" keeps meaning what it says',
        () async {
      final local = File('${dir.path}/1.mp3')..writeAsStringSync('bytes');
      final fallsBack = withLocalFile((workId, url) => local);
      final work = await seedEpisode();

      // The file existed at plan time, then eviction (or any other cause)
      // removed it before playback actually started.
      local.deleteSync();
      await fallsBack.playWork(work);

      expect(player.loadedUrl, 'https://cast.test/1.mp3');
      expect(player.loadedFilePath, isNull);
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

    testWidgets(
        'capture and captures-list doors are hidden without callbacks — '
        'never a dead button', (tester) async {
      final work = await seedEpisode();
      await controller.playWork(work);
      await pumpBar(tester);

      expect(find.byKey(const Key('player-capture')), findsNothing);
      expect(find.byKey(const Key('open-captures')), findsNothing);
    });

    testWidgets('the capture door calls onCapture', (tester) async {
      final work = await seedEpisode();
      await controller.playWork(work);
      var captured = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          bottomNavigationBar: MiniPlayerBar(
              controller: controller, onCapture: () => captured = true),
        ),
      ));
      await tester.pump();

      expect(find.byKey(const Key('player-capture')), findsOneWidget);
      await tester.tap(find.byKey(const Key('player-capture')));
      await tester.pump();
      expect(captured, isTrue);
    });

    testWidgets('the captures-list door calls onOpenCaptures', (tester) async {
      final work = await seedEpisode();
      await controller.playWork(work);
      var opened = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          bottomNavigationBar: MiniPlayerBar(
              controller: controller, onOpenCaptures: () => opened = true),
        ),
      ));
      await tester.pump();

      expect(find.byKey(const Key('open-captures')), findsOneWidget);
      await tester.tap(find.byKey(const Key('open-captures')));
      await tester.pump();
      expect(opened, isTrue);
    });

    testWidgets(
        'the sleep timer sheet: picking a duration arms it and closes',
        (tester) async {
      final work = await seedEpisode();
      await controller.playWork(work);
      await pumpBar(tester);

      await tester.tap(find.byKey(const Key('open-sleep-timer')));
      await tester.pumpAndSettle();
      expect(find.text('Sleep timer'), findsOneWidget);
      expect(find.byKey(const Key('sleep-timer-30')), findsOneWidget);

      await tester.tap(find.byKey(const Key('sleep-timer-30')));
      await tester.pumpAndSettle();

      expect(controller.sleepTimerMode, SleepTimerMode.duration);
      expect(controller.sleepTimerRemaining, const Duration(minutes: 30));
      expect(find.text('Sleep timer'), findsNothing,
          reason: 'the sheet closes once a choice is made');
    });

    testWidgets('the sleep timer sheet: "end of episode" arms that mode',
        (tester) async {
      final work = await seedEpisode();
      await controller.playWork(work);
      await pumpBar(tester);

      await tester.tap(find.byKey(const Key('open-sleep-timer')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sleep-timer-end-of-episode')));
      await tester.pumpAndSettle();

      expect(controller.sleepTimerMode, SleepTimerMode.endOfEpisode);
    });

    testWidgets(
        'reopening the sheet while a timer is active shows remaining time '
        'and cancels it', (tester) async {
      final work = await seedEpisode();
      await controller.playWork(work);
      controller.startSleepTimer(duration: const Duration(minutes: 30));
      await pumpBar(tester);

      await tester.tap(find.byKey(const Key('open-sleep-timer')));
      await tester.pumpAndSettle();
      expect(find.textContaining('30:00'), findsOneWidget,
          reason: 'the same sheet shows what was set');

      await tester.tap(find.byKey(const Key('sleep-timer-cancel')));
      await tester.pumpAndSettle();

      expect(controller.sleepTimerMode, isNull);
    });

    testWidgets('the sleep timer sheet: a custom duration', (tester) async {
      final work = await seedEpisode();
      await controller.playWork(work);
      await pumpBar(tester);

      await tester.tap(find.byKey(const Key('open-sleep-timer')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sleep-timer-custom')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('sleep-timer-custom-minutes')), '22');
      await tester.tap(find.byKey(const Key('sleep-timer-custom-confirm')));
      await tester.pumpAndSettle();

      expect(controller.sleepTimerMode, SleepTimerMode.duration);
      expect(controller.sleepTimerRemaining, const Duration(minutes: 22));
    });

    testWidgets('the queue button opens whatever the shell wires it to',
        (tester) async {
      final work = await seedEpisode();
      await controller.playWork(work);
      var opened = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: MiniPlayerBar(
              controller: controller, onOpenQueue: () => opened = true),
        ),
      ));
      await tester.pump();

      await tester.tap(find.byKey(const Key('open-queue')));
      await tester.pump();

      expect(opened, isTrue);
    });

    testWidgets('no onOpenQueue given: the button simply is not offered',
        (tester) async {
      final work = await seedEpisode();
      await controller.playWork(work);
      await pumpBar(tester);

      expect(find.byKey(const Key('open-queue')), findsNothing);
    });
  });
}
