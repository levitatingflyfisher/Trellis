/// The just_audio adapter behind [SpeechAudioQueue]: the same native
/// player (ExoPlayer on Android) the podcast player uses, reached one
/// layer lower than `just_audio_player.dart` does.
///
/// Why not an `AudioPlayer`: until 1.5.10 just_audio_background (the
/// lock-screen controls then) took over [JustAudioPlatform.instance] and
/// served ONE player, the episode player. Any second `AudioPlayer` failed
/// its init with "supports only a single player instance". 1.5.8 read
/// aloud with the neural voice through one, so wherever the episode
/// player had started first (always, on a podcast transcript) the voice
/// never sounded; and when the voice started first, the episode could
/// not play. So this talks to the native plugin directly
/// ([MethodChannelJustAudio]): its own player id, its own channel. Since
/// 1.6.0 the app has its own media session and that plugin is gone, so a
/// second `AudioPlayer` would work; this stays as it is, proven, until
/// read aloud is given its place in the session.
///
/// Talking to the plugin directly means sending what `AudioPlayer` would
/// have sent; the Android side unboxes and looks up without null checks
/// (see the citations below), and a missing field is a failed call.
///
/// Audio focus: before each play the app's audio session is activated,
/// as `AudioPlayer.play` does (audio_session's `setActive`; with no
/// configuration of the app's own it requests full focus, so other apps'
/// music pauses). A refused request (a call under way) plays nothing.
/// Losing focus, or the headphones, pauses the voice and tells the reader
/// ([interruptionStream]), as `AudioPlayer` does for the podcast.
library;

import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:just_audio_platform_interface/method_channel_just_audio.dart';

import 'speech_audio_queue.dart';

class JustAudioSpeechQueue implements SpeechAudioQueue {
  JustAudioSpeechQueue({
    JustAudioPlatform? platform,
    Future<bool> Function()? requestFocus,
    Stream<AudioInterruptionEvent>? interruptions,
    Stream<void>? becomingNoisy,
  })  : _platform = platform ?? MethodChannelJustAudio(),
        _requestFocus = requestFocus ?? _activateAudioSession,
        _interruptionsIn = interruptions,
        _becomingNoisyIn = becomingNoisy;

  final JustAudioPlatform _platform;
  final Future<bool> Function() _requestFocus;
  final Stream<AudioInterruptionEvent>? _interruptionsIn;
  final Stream<void>? _becomingNoisyIn;

  static int _nextId = 0;

  /// One native player per run: [clear] lets it go, the next [append]
  /// makes a fresh one, so no run ever inherits another's playlist.
  AudioPlayerPlatform? _player;
  Future<AudioPlayerPlatform>? _opening;
  StreamSubscription<PlaybackEventMessage>? _events;
  int _length = 0;
  int? _lastIndex;
  ProcessingStateMessage _state = ProcessingStateMessage.idle;
  bool _playing = false;
  double _speed = 1.0;
  bool _disposed = false;

  /// Paused by an interruption that may hand the speaker back, the way
  /// just_audio's `AudioPlayer` keeps `_playInterrupted`.
  bool _interrupted = false;
  bool _watchingSession = false;
  final _sessionSubs = <StreamSubscription<Object?>>[];

  final _index = StreamController<int>.broadcast();
  final _completed = StreamController<void>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  final _interruptions = StreamController<SpeechInterruption>.broadcast();

  static Future<bool> _activateAudioSession() async {
    final session = await AudioSession.instance;
    return session.setActive(true);
  }

  Future<AudioPlayerPlatform> _open() {
    final opening = _opening;
    if (opening != null) return opening;
    late final Future<AudioPlayerPlatform> mine;
    mine = () async {
      final id = 'speech-${DateTime.now().microsecondsSinceEpoch}-'
          '${_nextId++}';
      final player = await _platform.init(InitRequest(
          id: id,
          // Android unboxes this whenever no offload preferences are sent
          // (just_audio 0.10.6 AudioPlayer.java:165): null is an NPE and
          // a player that never exists. AudioPlayer always sends it.
          androidOffloadSchedulingEnabled: false));
      // Cleared while it opened: [clear] lets this one go.
      if (!identical(_opening, mine)) return player;
      _listen(player);
      if (_speed != 1.0) {
        try {
          await player.setSpeed(SetSpeedRequest(speed: _speed));
        } catch (_) {
          // The pace is no reason for silence.
        }
        // Cleared while the speed was set: the same, one await later.
        if (!identical(_opening, mine)) return player;
      }
      return _player = player;
    }();
    return _opening = mine;
  }

  void _listen(AudioPlayerPlatform player) {
    late final StreamSubscription<PlaybackEventMessage> sub;
    // Only the run's own player may end the run: [clear] cancels this
    // before it lets the player go, so the dispose's end of stream and
    // anything after it never reach here.
    void fail(Object error) {
      if (!identical(_events, sub)) return;
      _playing = false;
      _errors.add(error);
    }

    sub = player.playbackEventMessageStream.listen(_onEvent,
        // A playback error arrives as an error on the event channel
        // (AudioPlayer.java:943-948 sendError).
        onError: fail,
        onDone: () => fail(StateError('the speech player went away')));
    _events = sub;
  }

  void _onEvent(PlaybackEventMessage e) {
    final index = e.currentIndex;
    if (index != null && index != _lastIndex) {
      _lastIndex = index;
      _index.add(index);
    }
    final was = _state;
    _state = e.processingState;
    if (_state == ProcessingStateMessage.completed &&
        was != ProcessingStateMessage.completed) {
      _completed.add(null);
    }
  }

  /// Follows the session the way just_audio's `AudioPlayer` does when it
  /// handles interruptions (just_audio.dart:370-412), so the voice and the
  /// podcast answer a call or a pulled plug alike.
  void _watchSession() {
    if (_watchingSession) return;
    _watchingSession = true;
    final interruptions = _interruptionsIn;
    final noisy = _becomingNoisyIn;
    if (interruptions != null && noisy != null) {
      _subscribe(interruptions, noisy);
      return;
    }
    unawaited(AudioSession.instance.then<void>((session) {
      if (_disposed) return;
      _subscribe(interruptions ?? session.interruptionEventStream,
          noisy ?? session.becomingNoisyEventStream);
    }, onError: (Object _) {}));
  }

  void _subscribe(
      Stream<AudioInterruptionEvent> interruptions, Stream<void> noisy) {
    _sessionSubs
      ..add(interruptions.listen(_onInterruption))
      ..add(noisy.listen((_) {
        if (!_playing) return;
        _interrupted = false;
        _halt(SpeechInterruption.noisy);
      }));
  }

  void _onInterruption(AudioInterruptionEvent e) {
    if (e.begin) {
      // A duck lowers only a game's volume in AudioPlayer; speech plays on.
      if (e.type == AudioInterruptionType.duck) {
        _interrupted = false;
        return;
      }
      if (!_playing) return;
      _halt(SpeechInterruption.began);
      _interrupted = true;
      return;
    }
    final resume = _interrupted && e.type == AudioInterruptionType.pause;
    _interrupted = false;
    if (resume) _interruptions.add(SpeechInterruption.ended);
  }

  void _halt(SpeechInterruption why) {
    _playing = false;
    final player = _player;
    if (player != null) {
      unawaited(player.pause(PauseRequest()).then<void>((_) {},
          onError: (Object _) {}));
    }
    _interruptions.add(why);
  }

  @override
  Future<void> append(String filePath) async {
    final player = await _open();
    // A clear while the player was opening let it go: nothing to add to.
    if (!identical(player, _player)) return;
    final clip = ProgressiveAudioSourceMessage(
        id: 'clip-$_length', uri: Uri.file(filePath).toString());
    // The playlist's id is '', as just_audio's own playlist's is
    // (just_audio.dart:2948): Android's load registers only the children
    // (AudioPlayer.java:443), and concatenatingInsertAll reads '' as the
    // player's own playlist (:499-501) and looks any other id up as a
    // source it never registered (:504, :577-578), an NPE.
    if (_length == 0) {
      _length = 1;
      await player.load(LoadRequest(
          audioSourceMessage: ConcatenatingAudioSourceMessage(
              id: '',
              children: [clip],
              useLazyPreparation: false,
              shuffleOrder: const [0])));
      return;
    }
    final at = _length++;
    await player.concatenatingInsertAll(ConcatenatingInsertAllRequest(
        id: '',
        index: at,
        children: [clip],
        shuffleOrder: [for (var i = 0; i < _length; i++) i]));
    // Playback that caught up with synthesis has ended at the old tail;
    // the new clip would wait forever unless the player is moved onto it.
    if (_playing && _state == ProcessingStateMessage.completed) {
      await player.seek(SeekRequest(position: Duration.zero, index: at));
      unawaited(player.play(PlayRequest()).catchError((Object _) =>
          PlayResponse()));
    }
  }

  @override
  Future<void> play() async {
    final player = _player;
    if (player == null) return;
    _playing = true;
    _interrupted = false;
    _watchSession();
    var granted = true;
    try {
      granted = await _requestFocus();
    } catch (_) {
      // A platform with no audio session to ask is no reason for silence.
    }
    // Paused or cleared while focus was asked for.
    if (!_playing || !identical(player, _player)) return;
    if (!granted) {
      _playing = false;
      _interruptions.add(SpeechInterruption.began);
      return;
    }
    // The native play call answers only when playback stops.
    unawaited(
        player.play(PlayRequest()).catchError((Object _) => PlayResponse()));
  }

  @override
  Future<void> pause() async {
    _playing = false;
    await _player?.pause(PauseRequest());
  }

  @override
  Future<void> resume() => play();

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
    await _player?.setSpeed(SetSpeedRequest(speed: speed));
  }

  @override
  Future<void> clear() async {
    _playing = false;
    final opening = _opening;
    final events = _events;
    _opening = null;
    _events = null;
    _player = null;
    _length = 0;
    _lastIndex = null;
    _state = ProcessingStateMessage.idle;
    if (opening == null) return;
    await events?.cancel();
    final AudioPlayerPlatform player;
    try {
      player = await opening;
    } catch (_) {
      // It never opened: nothing to let go, and the run is ending anyway.
      return;
    }
    try {
      await _platform.disposePlayer(DisposePlayerRequest(id: player.id));
    } catch (_) {
      // Already gone.
    }
  }

  @override
  bool get playing => _playing;

  @override
  Stream<int> get currentIndexStream => _index.stream;

  @override
  Stream<void> get completedStream => _completed.stream;

  @override
  Stream<Object> get errorStream => _errors.stream;

  @override
  Stream<SpeechInterruption> get interruptionStream => _interruptions.stream;

  @override
  Future<void> dispose() async {
    _disposed = true;
    for (final sub in _sessionSubs) {
      await sub.cancel();
    }
    _sessionSubs.clear();
    await clear();
    await _index.close();
    await _completed.close();
    await _errors.close();
    await _interruptions.close();
  }
}
