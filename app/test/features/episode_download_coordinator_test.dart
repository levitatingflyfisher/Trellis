import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/feeds/episode_download_coordinator.dart';
import 'package:trellis/services/device_services.dart';

import '../support/fake_services.dart';

/// The standalone "Download" action (Campaign 6, Part 2): the door onto
/// disk that isn't transcription. One consent chokepoint lives in the UI
/// (confirmDownload) — this coordinator is what runs after the user has
/// already said yes, over the fleet's one download engine (AudioFetcher).
/// No persisted job row: the `.part` file AudioFetcher's own resumable
/// engine leaves beside the target IS the resumability checkpoint, same
/// as the transcribe pipeline's own audio-fetch step.
void main() {
  late Directory dir;
  late DeviceServices services;
  const url = 'https://cast.test/1.mp3';
  const workId = 1;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('trellis-dl-coord');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test(
    'start downloads the audio and the file lands at audioFileFor\'s path',
    () async {
      final fetcher = FakeAudioFetcher();
      services = testServices(dir, audioFetcher: fetcher);
      final coordinator = EpisodeDownloadCoordinator(services: services);

      await coordinator.start(workId: workId, url: url);

      expect(fetcher.fetched, [url]);
      expect(services.audioFileFor(workId, url).existsSync(), isTrue);
      expect(coordinator.stateOf(workId).downloading, isFalse);
    },
  );

  test(
    'already on disk: start is a no-op, the fetcher is never called',
    () async {
      final fetcher = FakeAudioFetcher();
      services = testServices(dir, audioFetcher: fetcher);
      final target = services.audioFileFor(workId, url);
      target.parent.createSync(recursive: true);
      target.writeAsBytesSync([1, 2, 3]);

      final coordinator = EpisodeDownloadCoordinator(services: services);
      await coordinator.start(workId: workId, url: url);

      expect(fetcher.fetched, isEmpty);
    },
  );

  test(
    'isDownloaded reflects disk truth before and after a download',
    () async {
      final fetcher = FakeAudioFetcher();
      services = testServices(dir, audioFetcher: fetcher);
      final coordinator = EpisodeDownloadCoordinator(services: services);

      expect(coordinator.isDownloaded(workId, url), isFalse);
      await coordinator.start(workId: workId, url: url);
      expect(coordinator.isDownloaded(workId, url), isTrue);
    },
  );

  test('while in flight, stateOf reports downloading and progress', () async {
    final fetcher = ControllableAudioFetcher();
    services = testServices(dir, audioFetcher: fetcher);
    final coordinator = EpisodeDownloadCoordinator(services: services);
    var notifications = 0;
    coordinator.addListener(() => notifications++);

    final future = coordinator.start(workId: workId, url: url);
    expect(coordinator.stateOf(workId).downloading, isTrue);

    fetcher.emitProgress(500, 1000);
    expect(coordinator.stateOf(workId).receivedBytes, 500);
    expect(coordinator.stateOf(workId).totalBytes, 1000);

    fetcher.completeDownload();
    await future;

    expect(coordinator.stateOf(workId).downloading, isFalse);
    expect(notifications, greaterThan(0));
  });

  test('cancel stops the download; the state clears rather than sticking '
      'in "downloading"', () async {
    final fetcher = ControllableAudioFetcher();
    services = testServices(dir, audioFetcher: fetcher);
    final coordinator = EpisodeDownloadCoordinator(services: services);

    final future = coordinator.start(workId: workId, url: url);
    expect(coordinator.stateOf(workId).downloading, isTrue);

    coordinator.cancel(workId);
    await future;

    expect(coordinator.stateOf(workId).downloading, isFalse);
    expect(
      services.audioFileFor(workId, url).existsSync(),
      isFalse,
      reason: 'a cancelled fetch never promotes a partial into place',
    );
  });

  test(
    'a fetch error surfaces as an honest error state, never a crash',
    () async {
      final fetcher = ControllableAudioFetcher();
      services = testServices(dir, audioFetcher: fetcher);
      final coordinator = EpisodeDownloadCoordinator(services: services);

      final future = coordinator.start(workId: workId, url: url);
      fetcher.failDownload(Exception('the host closed the connection'));
      await future;

      expect(coordinator.stateOf(workId).downloading, isFalse);
      expect(
        coordinator.stateOf(workId).error,
        contains('closed the connection'),
      );
    },
  );

  test(
    'calling start twice while one is already in flight only fetches once',
    () async {
      final fetcher = ControllableAudioFetcher();
      services = testServices(dir, audioFetcher: fetcher);
      final coordinator = EpisodeDownloadCoordinator(services: services);

      final first = coordinator.start(workId: workId, url: url);
      final second = coordinator.start(workId: workId, url: url);
      fetcher.completeDownload();
      await first;
      await second;

      expect(fetcher.fetched, [url]);
    },
  );
}
