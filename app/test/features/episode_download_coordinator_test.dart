import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart' as dio;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jobs_core/jobs_core.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/feeds/episode_download_coordinator.dart';
import 'package:trellis/features/transcribe/audio_fetcher.dart';
import 'package:trellis/features/transcribe/foreground_gate.dart';
import 'package:trellis/services/device_services.dart';

import '../support/fake_services.dart';

/// The standalone "Download" action (Campaign 6, Part 2), now a job with
/// a row: the user can see it, pause it, walk away, and find it again
/// after the app was killed. The bytes themselves resume through the
/// engine's `.part` + HTTP Range law; the row is what remembers that a
/// download was ever under way.
void main() {
  late Directory dir;
  late DeviceServices services;
  late AppDatabase db;
  const url = 'https://cast.test/1.mp3';
  const workId = 1;
  const jobId = 'download-1';

  setUp(() {
    dir = Directory.systemTemp.createTempSync('trellis-dl-coord');
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  EpisodeDownloadCoordinator coordinatorWith(AudioFetcher fetcher,
      {RecordingForegroundGate? gate}) {
    services = testServices(dir, audioFetcher: fetcher, gate: gate);
    return EpisodeDownloadCoordinator(services: services, db: db);
  }

  Future<void> seedRow(JobState state, {int totalBytes = 0}) async {
    await db.jobsDao.save(Job(
        id: jobId,
        kind: 'download',
        state: state,
        checkpoint: null,
        totalUnits: totalBytes,
        doneUnits: 0,
        createdAtMs: 1));
    await db.jobsDao.setPayload(
        jobId, jsonEncode({'workId': workId, 'title': 'Episode one', 'url': url}));
  }

  void seedPartial(int bytes) {
    final part = File('${services.audioFileFor(workId, url).path}.part');
    part.parent.createSync(recursive: true);
    part.writeAsBytesSync(List.filled(bytes, 0));
  }

  test('start downloads the audio, and the finished job leaves no row',
      () async {
    final fetcher = FakeAudioFetcher();
    final coordinator = coordinatorWith(fetcher);

    final outcome = await coordinator.start(workId: workId, url: url);

    expect(outcome, DownloadOutcome.done);
    expect(fetcher.fetched, [url]);
    expect(services.audioFileFor(workId, url).existsSync(), isTrue);
    expect(coordinator.stateOf(workId).downloading, isFalse);
    expect(await db.jobsDao.load(jobId), isNull);
  });

  test('already on disk: start is a no-op, the fetcher is never called',
      () async {
    final fetcher = FakeAudioFetcher();
    final coordinator = coordinatorWith(fetcher);
    final target = services.audioFileFor(workId, url);
    target.parent.createSync(recursive: true);
    target.writeAsBytesSync([1, 2, 3]);

    expect(await coordinator.start(workId: workId, url: url),
        DownloadOutcome.done);
    expect(fetcher.fetched, isEmpty);
  });

  test('while in flight, a row records the job and stateOf reports bytes',
      () async {
    final fetcher = ControllableAudioFetcher();
    final coordinator = coordinatorWith(fetcher);

    final future =
        coordinator.start(workId: workId, url: url, title: 'Episode one');
    await pumpEventQueue();
    expect(coordinator.stateOf(workId).downloading, isTrue);
    final row = await db.jobsDao.load(jobId);
    expect(row!.kind, 'download');
    expect(row.state, JobState.running);

    fetcher.emitProgress(500, 1000);
    expect(coordinator.stateOf(workId).receivedBytes, 500);
    expect(coordinator.stateOf(workId).totalBytes, 1000);

    fetcher.completeDownload();
    await future;
    expect(coordinator.stateOf(workId).downloading, isFalse);
  });

  test('pause keeps the row as paused, for a later resume', () async {
    final fetcher = ControllableAudioFetcher();
    final coordinator = coordinatorWith(fetcher);

    final future = coordinator.start(workId: workId, url: url);
    await pumpEventQueue();
    coordinator.cancel(workId);

    expect(await future, DownloadOutcome.paused);
    expect(coordinator.stateOf(workId).downloading, isFalse);
    expect(coordinator.stateOf(workId).paused, isTrue);
    expect((await db.jobsDao.load(jobId))!.state, JobState.cancelled);
    expect(services.audioFileFor(workId, url).existsSync(), isFalse,
        reason: 'a paused fetch never promotes a partial into place');
  });

  test('a failure is kept with a reason a person can act on', () async {
    final fetcher = ControllableAudioFetcher();
    final coordinator = coordinatorWith(fetcher);

    final future = coordinator.start(workId: workId, url: url);
    await pumpEventQueue();
    final req = dio.RequestOptions(path: url);
    fetcher.failDownload(dio.DioException(
        requestOptions: req,
        type: dio.DioExceptionType.badResponse,
        response: dio.Response(requestOptions: req, statusCode: 404)));

    expect(await future, DownloadOutcome.failed);
    expect(coordinator.stateOf(workId).error, contains('isn’t there'));
    final row = (await db.jobsDao.unfinished()).single;
    expect(row.state, JobState.failed.name);
    expect(row.failureReason, contains('isn’t there'));
  });

  test('losing the connection says so, yet the job still resumes on the '
      'next launch', () async {
    final fetcher = ControllableAudioFetcher();
    final coordinator = coordinatorWith(fetcher);

    final future = coordinator.start(workId: workId, url: url);
    await pumpEventQueue();
    fetcher.failDownload(dio.DioException(
        requestOptions: dio.RequestOptions(path: url),
        type: dio.DioExceptionType.connectionError));

    expect(await future, DownloadOutcome.failed);
    expect(coordinator.stateOf(workId).error, contains('connection'));

    final online = FakeAudioFetcher();
    final relaunched = EpisodeDownloadCoordinator(
        services: testServices(dir, audioFetcher: online), db: db);
    await relaunched.restore();
    await relaunched.resumeInterrupted();
    expect(online.fetched, [url]);
  });

  test('a second start while one is in flight joins it, never a second fetch',
      () async {
    final fetcher = ControllableAudioFetcher();
    final coordinator = coordinatorWith(fetcher);

    final first = coordinator.start(workId: workId, url: url);
    final second = coordinator.start(workId: workId, url: url);
    await pumpEventQueue();
    fetcher.completeDownload();

    expect(await first, DownloadOutcome.done);
    expect(await second, DownloadOutcome.done);
    expect(fetcher.fetched, [url]);
  });

  test('a running download holds the screen-off service until it ends',
      () async {
    final gate = RecordingForegroundGate();
    final coordinator = coordinatorWith(FakeAudioFetcher(), gate: gate);

    await coordinator.start(workId: workId, url: url, title: 'Episode one');

    expect(gate.events.first, 'start:Episode one');
    expect(gate.events.last, 'finished');
  });

  test('a file already on disk clears a leftover row instead of leaving a '
      'ghost "paused" job', () async {
    final fetcher = FakeAudioFetcher();
    final coordinator = coordinatorWith(fetcher);
    await seedRow(JobState.cancelled);
    await coordinator.restore();
    // Killed after the rename but before the row was deleted.
    services.audioFileFor(workId, url)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]);

    expect(await coordinator.resume(workId), DownloadOutcome.done);

    expect(fetcher.fetched, isEmpty);
    expect(await db.jobsDao.load(jobId), isNull);
    expect(coordinator.entries, isEmpty);
  });

  test('a job that fails before it holds the screen-off service never '
      'releases it out from under another job', () async {
    final inner = RecordingForegroundGate();
    final shared = SharedJobForegroundGate(inner);
    services =
        testServices(dir, audioFetcher: FakeAudioFetcher(), gate: shared);
    final coordinator = EpisodeDownloadCoordinator(services: services, db: db);
    await shared.jobStarted('Another episode', 'Transcribing…');
    // The job's first write fails, before the gate is ever taken.
    await db.customStatement('DROP TABLE jobs');

    expect(await coordinator.start(workId: workId, url: url),
        DownloadOutcome.failed);

    expect(inner.events, isNot(contains('finished')));
  });

  group('after the app was killed', () {
    test('restore shows the interrupted download with its bytes on disk',
        () async {
      final coordinator = coordinatorWith(ControllableAudioFetcher());
      await seedRow(JobState.running, totalBytes: 1000);
      seedPartial(400);

      await coordinator.restore();

      final s = coordinator.stateOf(workId);
      expect(s.title, 'Episode one');
      expect(s.receivedBytes, 400);
      expect(s.totalBytes, 1000);
      expect(coordinator.entries.map((e) => e.workId), [workId]);
    });

    test('resumeInterrupted continues a killed download from its partial',
        () async {
      final fetcher = FakeAudioFetcher();
      final coordinator = coordinatorWith(fetcher);
      await seedRow(JobState.running, totalBytes: 1000);
      seedPartial(400);

      await coordinator.restore();
      await coordinator.resumeInterrupted();

      expect(fetcher.fetched, [url]);
      expect(services.audioFileFor(workId, url).existsSync(), isTrue);
      expect(await db.jobsDao.load(jobId), isNull);
    });

    test('a download the user paused stays paused', () async {
      final fetcher = FakeAudioFetcher();
      final coordinator = coordinatorWith(fetcher);
      await seedRow(JobState.cancelled);

      await coordinator.restore();
      await coordinator.resumeInterrupted();

      expect(fetcher.fetched, isEmpty);
      expect(coordinator.stateOf(workId).paused, isTrue);
    });

    test('a failed download waits for Try again, reason intact', () async {
      final fetcher = FakeAudioFetcher();
      final coordinator = coordinatorWith(fetcher);
      await seedRow(JobState.failed);
      await db.jobsDao.setFailureReason(jobId, 'No connection.');

      await coordinator.restore();
      await coordinator.resumeInterrupted();

      expect(fetcher.fetched, isEmpty);
      expect(coordinator.stateOf(workId).error, 'No connection.');
    });

    test('resume picks the job back up from its stored address', () async {
      final fetcher = FakeAudioFetcher();
      final coordinator = coordinatorWith(fetcher);
      await seedRow(JobState.cancelled);

      await coordinator.restore();
      expect(await coordinator.resume(workId), DownloadOutcome.done);
      expect(fetcher.fetched, [url]);
    });
  });

  test('dismiss forgets the row and deletes the partial', () async {
    final coordinator = coordinatorWith(FakeAudioFetcher());
    await seedRow(JobState.cancelled);
    seedPartial(400);
    await coordinator.restore();

    await coordinator.dismiss(workId);

    expect(await db.jobsDao.load(jobId), isNull);
    expect(File('${services.audioFileFor(workId, url).path}.part').existsSync(),
        isFalse);
    expect(coordinator.entries, isEmpty);
  });

  test('dropping a partial drops its saved validator too', () async {
    // The engine's If-Range sidecar names the bytes in the partial; left
    // behind, it would vouch for bytes that are gone.
    final coordinator = coordinatorWith(FakeAudioFetcher());
    await seedRow(JobState.cancelled);
    seedPartial(400);
    final sidecar =
        File('${services.audioFileFor(workId, url).path}.part.validator')
          ..writeAsStringSync('"etag"');
    await coordinator.restore();
    coordinator.discardAll();
    expect(sidecar.existsSync(), isFalse);

    seedPartial(400);
    sidecar.writeAsStringSync('"etag"');
    await seedRow(JobState.cancelled);
    await coordinator.restore();
    await coordinator.dismiss(workId);
    expect(sidecar.existsSync(), isFalse);
  });
}
