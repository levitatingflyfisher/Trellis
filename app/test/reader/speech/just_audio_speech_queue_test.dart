import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:trellis/features/reader/speech/just_audio_speech_queue.dart';
import 'package:trellis/features/reader/speech/speech_audio_queue.dart';

/// just_audio_background (the lock-screen controls, bootstrap_io.dart)
/// replaces [JustAudioPlatform.instance] with a plugin that serves ONE
/// player: the episode player's. A second player's init throws
/// "supports only a single player instance". On a transcript the episode
/// player always holds that slot, so the neural voice, which plays its
/// sentences through a queue of its own, must never ask for it.
class _ClaimedBackgroundPlatform extends JustAudioPlatform {
  int inits = 0;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    inits++;
    throw PlatformException(
        code: 'error',
        message: 'just_audio_background supports only a single player '
            'instance');
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
          DisposePlayerRequest request) async =>
      DisposePlayerResponse();

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
          DisposeAllPlayersRequest request) async =>
      DisposeAllPlayersResponse();
}

/// A Java exception thrown inside a method call handler comes back to Dart
/// as a PlatformException (Flutter's MethodChannel replies "error").
Never _javaThrows(String what) =>
    throw PlatformException(code: 'error', message: what);

/// One Android `AudioPlayer` (just_audio 0.10.6,
/// android/src/main/java/com/ryanheise/just_audio/AudioPlayer.java), as far
/// as the speech queue's messages reach it.
class _NativePlayer {
  _NativePlayer(this.id);

  final String id;
  final calls = <MethodCall>[];

  /// Every message that reached this player after its dispose.
  final afterDispose = <String>[];
  bool disposed = false;

  /// Children registered by id (AudioPlayer.java:602-609 getAudioSource).
  /// A concatenating source's own id is never registered by load: load
  /// unpacks only its children (AudioPlayer.java:443).
  final mediaSources = <String>{};
  int length = 0;
  ProcessingStateMessage state = ProcessingStateMessage.idle;
  bool playWhenReady = false;
  Completer<Map<String, dynamic>>? playResult;
  MockStreamHandlerEventSink? events;

  /// Holds setSpeed's answer, so a test can act while it is in flight.
  Completer<void>? speedGate;

  Iterable<MethodCall> called(String method) =>
      calls.where((c) => c.method == method);

  void emit(int index, ProcessingStateMessage s) {
    state = s;
    events!.success(<String, dynamic>{
      'processingState': s.index,
      'updateTime': 0,
      'updatePosition': 0,
      'bufferedPosition': 0,
      'duration': null,
      'icyMetadata': null,
      'currentIndex': index,
      'androidAudioSessionId': null,
    });
  }

  /// AudioPlayer.java:943-948 sendError: a playback error is an error on
  /// the event channel.
  void failPlayback() =>
      events!.error(code: '0', message: 'Source error', details: null);

  void _settle() {
    final r = playResult;
    playResult = null;
    r?.complete(<String, dynamic>{});
  }

  /// AudioPlayer.java:1049-1068 dispose: answers a pending play, releases
  /// ExoPlayer, ends both event streams.
  void dispose() {
    disposed = true;
    _settle();
    events?.endOfStream();
  }

  Future<Object?> handle(MethodCall call) async {
    // AudioPlayer.java:1049-1068 never unregisters the player's method
    // channel, and every call starts with ensurePlayerInitialized
    // (AudioPlayer.java:435), so on a device a call after dispose quietly
    // builds a fresh ExoPlayer that nobody will ever release. Make it loud.
    if (disposed) {
      afterDispose.add(call.method);
      _javaThrows('player $id was disposed');
    }
    calls.add(call);
    final args = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'load':
        final source = args['audioSource'] as Map;
        // AudioPlayer.java:444 → 566 decodeShuffleOrder(null) NPEs.
        if (source['shuffleOrder'] == null) {
          _javaThrows('NullPointerException: shuffleOrder');
        }
        final children = (source['children'] as List).cast<Map>();
        for (final c in children) {
          mediaSources.add(c['id'] as String);
        }
        length = children.length;
        state = ProcessingStateMessage.ready;
        return <String, dynamic>{'duration': 1000000};
      case 'concatenatingInsertAll':
        final id = args['id'] as String;
        // AudioPlayer.java:504 + 577-578: a non-empty id is looked up as a
        // ConcatenatingMediaSource; load never registers one (:443), so
        // the lookup is null (NPE) or a child (ClassCastException).
        if (id.isNotEmpty) {
          _javaThrows('NullPointerException: concatenating($id)');
        }
        // AudioPlayer.java:499-501: '' means the player's own playlist.
        final children = (args['children'] as List).cast<Map>();
        final order = args['shuffleOrder'] as List?;
        if (order == null) {
          _javaThrows('NullPointerException: shuffleOrder');
        }
        for (final c in children) {
          mediaSources.add(c['id'] as String);
        }
        length += children.length;
        // ExoPlayer.setShuffleOrder (AudioPlayer.java:501) checks the
        // order covers the whole playlist.
        if (order.length != length) {
          _javaThrows('IllegalArgumentException: shuffle order length');
        }
        return <String, dynamic>{};
      case 'seek':
        // AudioPlayer.java:1032-1035: before load there is nothing to seek.
        if (state == ProcessingStateMessage.idle ||
            state == ProcessingStateMessage.loading) {
          return <String, dynamic>{};
        }
        final index = args['index'] as int?;
        // AudioPlayer.java:1041 seekTo: IllegalSeekPositionException.
        if (index != null && (index < 0 || index >= length)) {
          _javaThrows('IllegalSeekPositionException: $index');
        }
        return <String, dynamic>{};
      case 'play':
        // AudioPlayer.java:971-986: answers at once when already playing
        // or completed, otherwise only when playback stops.
        if (playWhenReady) return <String, dynamic>{};
        _settle();
        playWhenReady = true;
        if (state == ProcessingStateMessage.completed) {
          return <String, dynamic>{};
        }
        final r = playResult = Completer<Map<String, dynamic>>();
        return r.future;
      case 'pause':
        // AudioPlayer.java:988-997.
        playWhenReady = false;
        _settle();
        return <String, dynamic>{};
      case 'setSpeed':
        // AudioPlayer.java:461 casts to Double.
        if (args['speed'] is! double) {
          _javaThrows('ClassCastException: speed');
        }
        await speedGate?.future;
        return <String, dynamic>{};
      default:
        throw MissingPluginException(call.method);
    }
  }
}

/// The Android side of just_audio 0.10.6 over its method channels
/// (MainMethodCallHandler.java + AudioPlayer.java), faithful for every
/// message the speech queue sends: a call Android would fail fails here.
class _AndroidJustAudio {
  final players = <_NativePlayer>[];
  final mainCalls = <String>[];

  /// Holds init's answer, so a test can act while the player opens.
  Completer<void>? initGate;
  Completer<void>? nextSpeedGate;

  /// The next inits fail the way any of the refusals below would.
  bool refuseInit = false;

  _NativePlayer get single => players.single;

  Iterable<_NativePlayer> get disposed => players.where((p) => p.disposed);

  void install() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.ryanheise.just_audio.methods'), (call) async {
      mainCalls.add(call.method);
      final args = call.arguments as Map;
      switch (call.method) {
        case 'init':
          await initGate?.future;
          final id = args['id'] as String;
          if (refuseInit) _javaThrows('init refused');
          // MainMethodCallHandler.java:32-34.
          if (players.any((p) => p.id == id && !p.disposed)) {
            _javaThrows('Platform player $id already exists');
          }
          // MainMethodCallHandler.java:47 unboxes it into a boolean.
          if (args['useLazyPreparation'] == null) {
            _javaThrows('NullPointerException: useLazyPreparation');
          }
          // AudioPlayer.java:165 unboxes it when no offload preferences
          // were sent (line 153's null check does not cover 165).
          if (args['androidAudioOffloadPreferences'] == null &&
              args['androidOffloadSchedulingEnabled'] == null) {
            _javaThrows('NullPointerException: offloadSchedulingEnabled');
          }
          // AudioPlayer.java:225 iterates it once ExoPlayer has a session.
          if (args['androidAudioEffects'] == null) {
            _javaThrows('NullPointerException: rawAudioEffects');
          }
          final p = _NativePlayer(id)..speedGate = nextSpeedGate;
          players.add(p);
          messenger.setMockMethodCallHandler(
              MethodChannel('com.ryanheise.just_audio.methods.$id'), p.handle);
          messenger.setMockStreamHandler(
              EventChannel('com.ryanheise.just_audio.events.$id'),
              MockStreamHandler.inline(
                  onListen: (_, sink) => p.events = sink,
                  onCancel: (_) => p.events = null));
          messenger.setMockStreamHandler(
              EventChannel('com.ryanheise.just_audio.data.$id'),
              MockStreamHandler.inline(onListen: (_, _) {}));
          return null;
        case 'disposePlayer':
          // MainMethodCallHandler.java:53-61: an unknown id is a no-op.
          for (final p in players) {
            if (p.id == args['id'] && !p.disposed) p.dispose();
          }
          return <String, dynamic>{};
        default:
          throw MissingPluginException(call.method);
      }
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late JustAudioPlatform saved;
  setUp(() => saved = JustAudioPlatform.instance);
  tearDown(() => JustAudioPlatform.instance = saved);

  test('speech plays while the episode player holds the background slot',
      () async {
    final background = _ClaimedBackgroundPlatform();
    JustAudioPlatform.instance = background;
    final android = _AndroidJustAudio()..install();

    final queue = JustAudioSpeechQueue(
        requestFocus: () async => true,
        interruptions: const Stream.empty(),
        becomingNoisy: const Stream.empty());
    await queue.append('/speech/sentence-0.wav');
    await queue.play();
    await pumpEventQueue();

    expect(background.inits, 0,
        reason: 'the lock-screen player slot is the episode player’s');
    expect(android.players, hasLength(1));
    expect(android.mainCalls, ['init']);
    expect(android.single.calls.map((c) => c.method),
        containsAllInOrder(['load', 'play']));
    await queue.dispose();
  });

  group('over the Android plugin', () {
    late _AndroidJustAudio android;
    late JustAudioSpeechQueue queue;
    late StreamController<AudioInterruptionEvent> interruptions;
    late StreamController<void> noisy;
    late Completer<void>? focusGate;
    late bool focusGranted;

    setUp(() {
      android = _AndroidJustAudio()..install();
      interruptions = StreamController<AudioInterruptionEvent>.broadcast();
      noisy = StreamController<void>.broadcast();
      focusGate = null;
      focusGranted = true;
      queue = JustAudioSpeechQueue(
          requestFocus: () async {
            await focusGate?.future;
            return focusGranted;
          },
          interruptions: interruptions.stream,
          becomingNoisy: noisy.stream);
    });

    tearDown(() async {
      await queue.dispose();
      for (final p in android.players) {
        expect(p.afterDispose, isEmpty,
            reason: 'nothing may reach a player after its dispose');
      }
    });

    test('a new clip index is a sentence start, reported once', () async {
      final starts = <int>[];
      queue.currentIndexStream.listen(starts.add);
      await queue.append('/s/0.wav');
      await queue.append('/s/1.wav');
      await queue.append('/s/2.wav');
      await queue.play();
      await pumpEventQueue();
      final p = android.single;
      p.emit(0, ProcessingStateMessage.ready);
      p.emit(0, ProcessingStateMessage.ready);
      p.emit(1, ProcessingStateMessage.ready);
      p.emit(2, ProcessingStateMessage.ready);
      await pumpEventQueue();
      expect(starts, [0, 1, 2]);
      expect(p.called('load'), hasLength(1));
      expect(p.length, 3, reason: 'every sentence reached the playlist');
    });

    test('completion is reported once per end of playback', () async {
      var completed = 0;
      queue.completedStream.listen((_) => completed++);
      await queue.append('/s/0.wav');
      await queue.play();
      await pumpEventQueue();
      final p = android.single;
      p.emit(0, ProcessingStateMessage.completed);
      p.emit(0, ProcessingStateMessage.completed);
      await pumpEventQueue();
      expect(completed, 1);
    });

    test('a clip added after playback caught up is played, not stranded',
        () async {
      await queue.append('/s/0.wav');
      await queue.play();
      await pumpEventQueue();
      final p = android.single;
      p.emit(0, ProcessingStateMessage.completed);
      await pumpEventQueue();
      await queue.append('/s/1.wav');
      await pumpEventQueue();
      final seek = p.called('seek').single;
      expect((seek.arguments as Map)['index'], 1);
      expect(p.calls.last.method, 'play');
    });

    test('clear lets the native player go; the next run opens a fresh one '
        'at the same speed', () async {
      await queue.setSpeed(1.5);
      await queue.append('/s/0.wav');
      await queue.clear();
      expect(android.disposed, [android.players.first]);
      await queue.append('/s/0.wav');
      expect(android.players, hasLength(2));
      final second = android.players.last;
      expect((second.called('setSpeed').single.arguments as Map)['speed'],
          1.5);
      expect(second.called('load'), hasLength(1));
    });

    test('a clear while the player opens leaves nothing behind', () async {
      android.initGate = Completer<void>();
      final appending = queue.append('/s/0.wav');
      final clearing = queue.clear();
      android.initGate!.complete();
      await appending;
      await clearing;
      final p = android.single;
      expect(p.disposed, isTrue);
      expect(p.calls, isEmpty);
      expect(p.events, isNull, reason: 'no one listens to a let-go player');
    });

    test('a clear while the opening player takes its speed leaves it let go',
        () async {
      await queue.setSpeed(1.5);
      android.nextSpeedGate = Completer<void>();
      final appending = queue.append('/s/0.wav');
      await pumpEventQueue();
      final first = android.single;
      expect(first.called('setSpeed'), hasLength(1));
      final clearing = queue.clear();
      android.nextSpeedGate!.complete();
      android.nextSpeedGate = null;
      await appending;
      await clearing;
      expect(first.disposed, isTrue);
      expect(first.called('load'), isEmpty);

      await queue.append('/s/0.wav');
      expect(android.players, hasLength(2));
      expect(android.players.last.called('load'), hasLength(1));
    });

    test('a player that would not open fails the append, and clear still '
        'succeeds', () async {
      android.refuseInit = true;
      await expectLater(queue.append('/s/0.wav'), throwsA(anything));
      await queue.clear(); // must not throw: the run is ending anyway
      android.refuseInit = false;
      await queue.append('/s/0.wav');
      expect(android.single.called('load'), hasLength(1));
    });

    test('pause during the focus request means no play reaches the player',
        () async {
      await queue.append('/s/0.wav');
      focusGate = Completer<void>();
      final playing = queue.play();
      await queue.pause();
      focusGate!.complete();
      await playing;
      await pumpEventQueue();
      expect(android.single.called('play'), isEmpty);
      expect(queue.playing, isFalse);
    });

    test('focus refused (a call under way): nothing sounds, and the reader '
        'hears why', () async {
      final seen = <SpeechInterruption>[];
      queue.interruptionStream.listen(seen.add);
      focusGranted = false;
      await queue.append('/s/0.wav');
      await queue.play();
      await pumpEventQueue();
      expect(android.single.called('play'), isEmpty);
      expect(queue.playing, isFalse);
      expect(seen, [SpeechInterruption.began]);
    });

    test('a playback error ends the run: the queue reports it', () async {
      final errors = <Object>[];
      queue.errorStream.listen(errors.add);
      await queue.append('/s/0.wav');
      await queue.play();
      await pumpEventQueue();
      android.single.failPlayback();
      await pumpEventQueue();
      expect(errors, hasLength(1));
    });

    test('the player vanishing under a run is a failure; letting it go is '
        'not', () async {
      final errors = <Object>[];
      queue.errorStream.listen(errors.add);
      await queue.append('/s/0.wav');
      await pumpEventQueue();
      android.single.events!.endOfStream();
      await pumpEventQueue();
      expect(errors, hasLength(1));

      await queue.clear();
      await queue.append('/s/0.wav');
      await queue.clear(); // dispose ends its stream: expected, no error
      await pumpEventQueue();
      expect(errors, hasLength(1));
    });

    group('interruptions', () {
      late List<SpeechInterruption> seen;
      setUp(() async {
        seen = [];
        queue.interruptionStream.listen(seen.add);
        await queue.append('/s/0.wav');
        await queue.play();
        await pumpEventQueue();
      });

      test('a call pauses the voice and its end offers it back', () async {
        interruptions
            .add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
        await pumpEventQueue();
        expect(seen, [SpeechInterruption.began]);
        expect(android.single.called('pause'), hasLength(1));
        expect(queue.playing, isFalse);

        interruptions
            .add(AudioInterruptionEvent(false, AudioInterruptionType.pause));
        await pumpEventQueue();
        expect(seen, [SpeechInterruption.began, SpeechInterruption.ended]);
      });

      test('focus lost for good pauses and is never offered back', () async {
        interruptions
            .add(AudioInterruptionEvent(true, AudioInterruptionType.unknown));
        await pumpEventQueue();
        interruptions
            .add(AudioInterruptionEvent(false, AudioInterruptionType.unknown));
        await pumpEventQueue();
        expect(seen, [SpeechInterruption.began]);
      });

      test('a duck leaves the voice alone', () async {
        interruptions
            .add(AudioInterruptionEvent(true, AudioInterruptionType.duck));
        interruptions
            .add(AudioInterruptionEvent(false, AudioInterruptionType.duck));
        await pumpEventQueue();
        expect(seen, isEmpty);
        expect(android.single.called('pause'), isEmpty);
      });

      test('headphones pulled out pause the voice for good', () async {
        noisy.add(null);
        await pumpEventQueue();
        expect(seen, [SpeechInterruption.noisy]);
        expect(android.single.called('pause'), hasLength(1));
      });

      test('a voice already paused is not interrupted', () async {
        await queue.pause();
        interruptions
            .add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
        noisy.add(null);
        interruptions
            .add(AudioInterruptionEvent(false, AudioInterruptionType.pause));
        await pumpEventQueue();
        expect(seen, isEmpty);
      });
    });
  });
}
