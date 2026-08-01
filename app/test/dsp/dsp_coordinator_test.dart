import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/dsp/dsp_coordinator.dart';
import 'package:trellis/features/transcribe/transcribe_coordinator.dart'
    show transcribeJobId;
import 'package:jobs_core/jobs_core.dart' as jobs;

import '../support/fake_services.dart';

/// The DSP pipeline's orchestration (Campaign 6, ADR-0012), against a
/// FAKED ffmpeg boundary — success, failure, and garbage-output paths,
/// the atomic promote, and the transcript-exclusivity eligibility law.
/// No real ffmpeg runs here (mirrors the transcribe pipeline's own test
/// posture — FfmpegDecoder itself is never exercised by this suite).
void main() {
  late Directory dir;
  late AppDatabase db;
  const url = 'https://cast.test/1.mp3';

  setUp(() {
    dir = Directory.systemTemp.createTempSync('trellis-dsp-coord');
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<int> seedEpisode() async {
    final profileId = await db.profilesDao.create('Ada');
    final feedId = await db.feedsDao.insertFeed(
      profileId: profileId,
      url: 'https://cast.test/feed',
    );
    final workId = await db.spineDao.insertWork(
      profileId: profileId,
      kind: 'episode',
      title: 'Ep 1',
      persistence: 'ephemeron',
      firstSeenEpochDay: 100,
      sourceUrl: url,
    );
    await db.feedsDao.insertEpisode(
      workId: workId,
      feedId: feedId,
      guid: 'g',
      publishedAtMs: 1,
    );
    return workId;
  }

  test('happy path: measures, processes, promotes atomically, stores '
      'both durations, and cleans up the job row', () async {
    final workId = await seedEpisode();
    final fetcher = FakeAudioFetcher();
    final encoder = FakeDspEncoder(
      defaultOriginalMs: 600000,
      processedMs: 540000,
    );
    final services = testServices(
      dir,
      audioFetcher: fetcher,
      dspEncoder: encoder,
    );
    final audio = services.audioFileFor(workId, url);
    audio.parent.createSync(recursive: true);
    audio.writeAsBytesSync([1, 2, 3]);

    final coordinator = DspCoordinator(db: db, services: services);
    await coordinator.start(workId: workId, title: 'Ep 1', url: url);

    expect(encoder.processedInputs, [audio.path]);
    // The processed bytes landed at the SAME path playback/eviction use —
    // the atomic-promote law.
    expect(audio.existsSync(), isTrue);
    expect(audio.readAsBytesSync().length, encoder.outputBytes);

    final episode = await db.feedsDao.episodeOf(workId);
    expect(episode?.dspOriginalDurationMs, 600000);
    expect(episode?.dspProcessedDurationMs, 540000);

    expect(
      await db.jobsDao.load('dsp-$workId'),
      isNull,
      reason: 'a finished job row is cleaned up, like transcribe\'s',
    );
  });

  test('no downloaded audio: fails honestly, nothing promoted', () async {
    final workId = await seedEpisode();
    final services = testServices(dir, dspEncoder: FakeDspEncoder());

    final coordinator = DspCoordinator(db: db, services: services);
    await coordinator.start(workId: workId, title: 'Ep 1', url: url);

    expect(coordinator.stateOf(workId)?.phase, DspPhase.failed);
    final job = await db.jobsDao.load('dsp-$workId');
    expect(job?.state.name, jobs.JobState.failed.name);
  });

  test('ffmpeg itself throws: the original file is untouched, job marked '
      'failed', () async {
    final workId = await seedEpisode();
    final encoder = FakeDspEncoder()
      ..processError = Exception('ffmpeg crashed');
    final services = testServices(dir, dspEncoder: encoder);
    final audio = services.audioFileFor(workId, url);
    audio.parent.createSync(recursive: true);
    audio.writeAsBytesSync([9, 9, 9]);

    final coordinator = DspCoordinator(db: db, services: services);
    await coordinator.start(workId: workId, title: 'Ep 1', url: url);

    expect(
      audio.readAsBytesSync(),
      [9, 9, 9],
      reason: 'the original is kept until success is verified',
    );
    expect(coordinator.stateOf(workId)?.phase, DspPhase.failed);
  });

  test('garbage output (implausible shrink) fails the sanity check and is '
      'deleted; the original is promoted-over never happens', () async {
    final workId = await seedEpisode();
    // 600000ms original, 1000ms "processed" — nowhere near the 10% floor.
    final encoder = FakeDspEncoder(
      defaultOriginalMs: 600000,
      processedMs: 1000,
    );
    final services = testServices(dir, dspEncoder: encoder);
    final audio = services.audioFileFor(workId, url);
    audio.parent.createSync(recursive: true);
    audio.writeAsBytesSync([1, 2, 3]);

    final coordinator = DspCoordinator(db: db, services: services);
    await coordinator.start(workId: workId, title: 'Ep 1', url: url);

    expect(audio.readAsBytesSync(), [
      1,
      2,
      3,
    ], reason: 'a failed sanity check never promotes');
    expect(coordinator.stateOf(workId)?.phase, DspPhase.failed);
    final episode = await db.feedsDao.episodeOf(workId);
    expect(
      episode?.dspOriginalDurationMs,
      isNull,
      reason: 'no result is stored unless the promote actually happened',
    );
  });

  test('zero-byte output fails the sanity check the same way', () async {
    final workId = await seedEpisode();
    final encoder = FakeDspEncoder(outputBytes: 0);
    final services = testServices(dir, dspEncoder: encoder);
    final audio = services.audioFileFor(workId, url);
    audio.parent.createSync(recursive: true);
    audio.writeAsBytesSync([1, 2, 3]);

    final coordinator = DspCoordinator(db: db, services: services);
    await coordinator.start(workId: workId, title: 'Ep 1', url: url);

    expect(audio.readAsBytesSync(), [1, 2, 3]);
    expect(coordinator.stateOf(workId)?.phase, DspPhase.failed);
  });

  group('the transcript-exclusivity eligibility law', () {
    test('a transcript already exists: refuses without ever touching '
        'ffmpeg', () async {
      final workId = await seedEpisode();
      await db.spineDao.insertSegments(workId, const [
        (idx: 0, kind: 'prose', text: 'hi'),
      ]);
      await db.spineDao.insertAlignments(workId, const [
        (segmentIdx: 0, tStartMs: 0, tEndMs: 1000),
      ]);
      final encoder = FakeDspEncoder();
      final services = testServices(dir, dspEncoder: encoder);
      final audio = services.audioFileFor(workId, url);
      audio.parent.createSync(recursive: true);
      audio.writeAsBytesSync([1, 2, 3]);

      final coordinator = DspCoordinator(db: db, services: services);
      await coordinator.start(workId: workId, title: 'Ep 1', url: url);

      expect(coordinator.stateOf(workId)?.phase, DspPhase.ineligible);
      expect(encoder.processedInputs, isEmpty);
    });

    test(
      'a pending transcribe job (not yet a transcript): refuses too',
      () async {
        final workId = await seedEpisode();
        await db.jobsDao.save(
          jobs.Job(
            id: transcribeJobId(workId),
            kind: 'transcribe',
            state: jobs.JobState.running,
            checkpoint: null,
            totalUnits: 0,
            doneUnits: 0,
            createdAtMs: 0,
          ),
        );
        final encoder = FakeDspEncoder();
        final services = testServices(dir, dspEncoder: encoder);
        final audio = services.audioFileFor(workId, url);
        audio.parent.createSync(recursive: true);
        audio.writeAsBytesSync([1, 2, 3]);

        final coordinator = DspCoordinator(db: db, services: services);
        await coordinator.start(workId: workId, title: 'Ep 1', url: url);

        expect(coordinator.stateOf(workId)?.phase, DspPhase.ineligible);
        expect(encoder.processedInputs, isEmpty);
      },
    );

    test('an episode processed first is later still eligible to '
        'transcribe — the reverse direction is never blocked here (that\'s '
        'TranscribeCoordinator\'s own job, proven by construction: nothing '
        'about DspCoordinator writes a transcribe job row)', () async {
      final workId = await seedEpisode();
      final encoder = FakeDspEncoder();
      final services = testServices(dir, dspEncoder: encoder);
      final audio = services.audioFileFor(workId, url);
      audio.parent.createSync(recursive: true);
      audio.writeAsBytesSync([1, 2, 3]);

      final coordinator = DspCoordinator(db: db, services: services);
      await coordinator.start(workId: workId, title: 'Ep 1', url: url);

      // A successfully finished card disappears (the same law
      // TranscribeCoordinator's own success path follows) — the
      // episode's stored dspProcessedDurationMs, not a lingering card
      // phase, is what "done" means from here.
      expect(coordinator.stateOf(workId), isNull);
      expect(
        (await db.feedsDao.episodeOf(workId))?.dspProcessedDurationMs,
        isNotNull,
      );
      expect(await db.jobsDao.load(transcribeJobId(workId)), isNull);
    });
  });

  test('starting twice while one is already in flight is a no-op the '
      'second time', () async {
    final workId = await seedEpisode();
    final encoder = FakeDspEncoder();
    final services = testServices(dir, dspEncoder: encoder);
    final audio = services.audioFileFor(workId, url);
    audio.parent.createSync(recursive: true);
    audio.writeAsBytesSync([1, 2, 3]);

    final coordinator = DspCoordinator(db: db, services: services);
    final first = coordinator.start(workId: workId, title: 'Ep 1', url: url);
    final second = coordinator.start(workId: workId, title: 'Ep 1', url: url);
    await first;
    await second;

    expect(encoder.processedInputs, [audio.path]);
  });

  test('restore rebuilds a failed card from the persisted job row on '
      'reopen', () async {
    final workId = await seedEpisode();
    final encoder = FakeDspEncoder()..processError = Exception('boom');
    final services = testServices(dir, dspEncoder: encoder);
    final audio = services.audioFileFor(workId, url);
    audio.parent.createSync(recursive: true);
    audio.writeAsBytesSync([1, 2, 3]);
    final first = DspCoordinator(db: db, services: services);
    await first.start(workId: workId, title: 'Ep 1', url: url);

    final reopened = DspCoordinator(db: db, services: services);
    await reopened.restore();

    expect(reopened.stateOf(workId)?.phase, DspPhase.failed);
  });
}
