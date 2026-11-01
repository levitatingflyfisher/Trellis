import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/player/headset_keys.dart';
import 'package:trellis/features/player/media_item_mapping.dart';
import 'package:trellis/features/player/playback_session.dart';
import 'package:trellis/features/player/trellis_audio_handler.dart';

class _Client implements SessionClient {
  final log = <String>[];
  @override
  Future<void> play() async => log.add('play');
  @override
  Future<void> pause() async => log.add('pause');
  @override
  Future<void> seek(Duration position) async =>
      log.add('seek:${position.inMilliseconds}');
  @override
  Future<void> stop() async => log.add('stop');
}

/// Trellis's own media session (1.6.0): what the lock screen, the
/// notification and a headset show and do. What they render is the
/// device's; what reaches them is pinned here.
void main() {
  late TrellisAudioHandler handler;
  late _Client client;
  const tag = LockScreenTag(id: '7', title: 'Episode seven', album: 'A Show');

  setUp(() {
    handler = TrellisAudioHandler();
    client = _Client();
  });

  test('attaching shows the work: id, title, show and art', () {
    final art = Uri.file('/art/7.png');
    handler.attach(
        client,
        LockScreenTag(
            id: '7', title: 'Episode seven', album: 'A Show', artUri: art));

    final item = handler.mediaItem.value!;
    expect(item.id, '7');
    expect(item.title, 'Episode seven');
    expect(item.album, 'A Show');
    expect(item.artUri, art);
  });

  test('playing: a Pause button, the seek bar, and Stop kept out of the '
      'compact view', () {
    handler.attach(client, tag);
    handler.report(
        client,
        const SessionState(
            playing: true,
            phase: SessionPhase.ready,
            position: Duration(seconds: 30),
            buffered: Duration(seconds: 60),
            speed: 1.5,
            duration: Duration(minutes: 5)));

    final s = handler.playbackState.value;
    expect(s.playing, isTrue);
    expect(s.processingState, AudioProcessingState.ready);
    expect(s.controls.map((c) => c.action),
        [MediaAction.pause, MediaAction.stop]);
    expect(s.androidCompactActionIndices, [0]);
    expect(
        s.systemActions,
        containsAll([
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        ]));
    expect(s.updatePosition, const Duration(seconds: 30));
    expect(s.bufferedPosition, const Duration(seconds: 60));
    expect(s.speed, 1.5);
    expect(handler.mediaItem.value!.duration, const Duration(minutes: 5),
        reason: 'the seek bar shows only once the length is known');
  });

  test('paused: a Play button', () {
    handler.attach(client, tag);
    handler.report(client, const SessionState(phase: SessionPhase.ready));

    final s = handler.playbackState.value;
    expect(s.playing, isFalse);
    expect(s.controls.map((c) => c.action),
        [MediaAction.play, MediaAction.stop]);
  });

  test('at the end of a file the session still says playing, until '
      'something pauses it: "not playing" there is what took the playback '
      'service out of the foreground between queued episodes (1.5.10)', () {
    handler.attach(client, tag);
    handler.report(client,
        const SessionState(playing: true, phase: SessionPhase.completed));

    final s = handler.playbackState.value;
    expect(s.playing, isTrue);
    expect(s.processingState, AudioProcessingState.completed);
  });

  test('loading the next thing while playing is still playing', () {
    handler.attach(client, tag);
    handler.report(client,
        const SessionState(playing: true, phase: SessionPhase.loading));
    expect(handler.playbackState.value.playing, isTrue);
    expect(handler.playbackState.value.processingState,
        AudioProcessingState.loading);
  });

  test('idle is never playing, whatever the engine’s flag says', () {
    handler.attach(client, tag);
    handler.report(
        client, const SessionState(playing: true, phase: SessionPhase.idle));

    final s = handler.playbackState.value;
    expect(s.playing, isFalse);
    expect(s.processingState, AudioProcessingState.idle);
  });

  test('the buttons reach whoever is in the session', () async {
    handler.attach(client, tag);
    await handler.play();
    await handler.pause();
    await handler.seek(const Duration(seconds: 42));

    expect(client.log, ['play', 'pause', 'seek:42000']);
  });

  test('Stop reaches the client and empties the session: idle, which is '
      'what lets the service and its notification go', () async {
    handler.attach(client, tag);
    handler.report(client,
        const SessionState(playing: true, phase: SessionPhase.ready));

    await handler.stop();

    expect(client.log, ['stop']);
    final s = handler.playbackState.value;
    expect(s.playing, isFalse);
    expect(s.processingState, AudioProcessingState.idle);
  });

  test('fast-forward and rewind skip ten seconds, kept within the work',
      () async {
    handler.attach(client, tag);
    handler.report(
        client,
        const SessionState(
            phase: SessionPhase.ready,
            position: Duration(seconds: 30),
            duration: Duration(seconds: 35)));
    await handler.rewind();
    await handler.fastForward();
    handler.report(
        client,
        const SessionState(
            phase: SessionPhase.ready,
            position: Duration(seconds: 5),
            duration: Duration(seconds: 35)));
    await handler.rewind();

    expect(client.log, ['seek:20000', 'seek:35000', 'seek:0']);
  });

  test('with nobody in the session the buttons do nothing', () async {
    await handler.play();
    await handler.pause();
    await handler.seek(const Duration(seconds: 1));
    await handler.fastForward();
    await handler.rewind();
    await handler.stop();
    expect(handler.playbackState.value.playing, isFalse);
  });

  test('whoever is no longer in the session cannot change it: a player '
      'being let go must not clear what its successor shows', () async {
    final old = _Client();
    handler.attach(old, const LockScreenTag(id: '1', title: 'Old'));
    handler.attach(client, tag);
    handler.report(client,
        const SessionState(playing: true, phase: SessionPhase.ready));

    handler.report(old, SessionState.idle);
    handler.detach(old);

    expect(handler.playbackState.value.playing, isTrue);
    expect(handler.mediaItem.value!.id, '7');
    await handler.pause();
    expect(client.log, ['pause']);
    expect(old.log, isEmpty);
  });

  group('a headset’s keys (1.6.0, user: "Double tap is skip forward 30 '
      'seconds. Triple tap is skip forward episode.")', () {
    const window = Duration(milliseconds: 40);
    late int nextEpisodes;
    late int previousEpisodes;

    // Paused unless a test is about play and pause: a playing session's
    // place moves with the clock, and the skips below are exact.
    TrellisAudioHandler withKeys(HeadsetKeys keys, {bool playing = false}) {
      nextEpisodes = previousEpisodes = 0;
      final h = TrellisAudioHandler(clickWindow: window)
        ..headsetKeys = (() async => keys)
        ..onNextEpisode = (() async => nextEpisodes++)
        ..onPreviousEpisode = (() async => previousEpisodes++)
        ..attach(client, tag);
      h.report(
          client,
          SessionState(
              playing: playing,
              phase: SessionPhase.ready,
              position: const Duration(minutes: 2),
              duration: const Duration(minutes: 10)));
      return h;
    }

    Future<void> settle() => Future<void>.delayed(window * 3);

    test('the Next key (a double tap on most earbuds) skips forward 30 '
        'seconds; the Previous key (a triple tap) goes to the next '
        'episode: the owner’s defaults', () async {
      final h = withKeys(const HeadsetKeys());

      await h.click(MediaButton.next);
      expect(client.log, ['seek:150000']);
      expect(nextEpisodes, 0);

      await h.click(MediaButton.previous);
      expect(nextEpisodes, 1);
      expect(client.log, ['seek:150000'], reason: 'no seek for an episode');
    });

    test('each key does what its setting says', () async {
      final h = withKeys(const HeadsetKeys(
          next: HeadsetAction.back15,
          previous: HeadsetAction.previousEpisode));

      await h.click(MediaButton.next);
      await h.click(MediaButton.previous);

      expect(client.log, ['seek:105000']);
      expect(previousEpisodes, 1);
      expect(nextEpisodes, 0);
    });

    test('a skip stays within the episode', () async {
      final h = withKeys(const HeadsetKeys(previous: HeadsetAction.back30));
      h.report(
          client,
          const SessionState(
              phase: SessionPhase.ready,
              position: Duration(seconds: 12),
              duration: Duration(seconds: 20)));

      await h.click(MediaButton.next);
      await h.click(MediaButton.previous);

      expect(client.log, ['seek:20000', 'seek:0']);
    });

    test('a car’s or a notification’s skip buttons are the same two keys',
        () async {
      final h = withKeys(const HeadsetKeys());

      await h.skipToNext();
      await h.skipToPrevious();

      expect(client.log, ['seek:150000']);
      expect(nextEpisodes, 1);
    });

    test('settings that cannot be read fall back to the defaults', () async {
      final h = withKeys(const HeadsetKeys())
        ..headsetKeys = (() async => throw StateError('database closed'));

      await h.click(MediaButton.next);

      expect(client.log, ['seek:150000']);
    });

    test('the play/pause button acts at once when clicks are not counted: '
        'an earbud’s single tap must not wait', () async {
      final h = withKeys(const HeadsetKeys(), playing: true);

      await h.click();
      expect(client.log, ['pause']);

      h.report(client, const SessionState(phase: SessionPhase.ready));
      await h.click();
      expect(client.log, ['pause', 'play']);
    });

    group('a one-button headset, clicks counted', () {
      const counted = HeadsetKeys(countClicks: true);

      test('one click plays or pauses, once no second click has come',
          () async {
        final h = withKeys(counted, playing: true);

        await h.click();
        expect(client.log, isEmpty, reason: 'still waiting for a second');
        await settle();

        expect(client.log, ['pause']);
      });

      test('two clicks are the Next key, with no play or pause', () async {
        final h = withKeys(counted);

        await h.click();
        await h.click();
        await settle();

        expect(client.log, ['seek:150000']);
      });

      test('three clicks are the Previous key', () async {
        final h = withKeys(counted);

        await h.click();
        await h.click();
        await h.click();
        await settle();

        expect(nextEpisodes, 1);
        expect(client.log, isEmpty);
      });

      test('clicks a while apart are two presses, not a double', () async {
        final h = withKeys(counted, playing: true);

        await h.click();
        await settle();
        h.report(client, const SessionState(phase: SessionPhase.ready));
        await h.click();
        await settle();

        expect(client.log, ['pause', 'play']);
      });

      test('the Next and Previous keys themselves never wait', () async {
        final h = withKeys(counted);

        await h.click(MediaButton.next);

        expect(client.log, ['seek:150000']);
      });
    });
  });

  test('whoever attaches again has the session back: an episode resumed '
      'after read aloud took its place', () async {
    final readAloud = _Client();
    handler.attach(client, tag);
    handler.attach(
        readAloud, const LockScreenTag(id: 'read-aloud-3', title: 'Essay'));
    handler.report(readAloud,
        const SessionState(playing: true, phase: SessionPhase.ready));

    handler.attach(client, tag);
    handler.report(client,
        const SessionState(playing: true, phase: SessionPhase.ready));
    handler.detach(readAloud);

    expect(handler.mediaItem.value!.id, '7');
    expect(handler.playbackState.value.playing, isTrue);
    await handler.pause();
    expect(client.log, ['pause']);
    expect(readAloud.log, isEmpty);
  });

  test('detaching empties the session', () async {
    handler.attach(client, tag);
    handler.report(client,
        const SessionState(playing: true, phase: SessionPhase.ready));

    handler.detach(client);

    expect(handler.playbackState.value.processingState,
        AudioProcessingState.idle);
    expect(handler.playbackState.value.playing, isFalse);
    await handler.play();
    expect(client.log, isEmpty);
  });
}
