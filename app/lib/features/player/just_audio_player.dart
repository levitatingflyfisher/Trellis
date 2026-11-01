/// The just_audio adapter behind the [EpisodePlayer] seam. Deliberately a
/// thin declarative mapping — every behavior above it (projection writes,
/// promotion on finish, resume, speed law) is tested through the seam with
/// a scripted fake; this file adds no logic of its own beyond
/// [sessionStateOf].
///
/// Background playback (Campaign 9 Phase 2e, ADR-0015 Decision 3; its
/// own session since 1.6.0): a [LockScreenTag] arriving on any of the
/// three loaders below puts this player in the app's [PlaybackSession],
/// and from then on it reports what the engine does and answers the
/// session's buttons. The session's types stay behind that seam, same as
/// [EpisodePlayer] itself stays free of just_audio's. With no session
/// (the web build, tests) nothing is reported and nothing changes.
library;

import 'dart:async';

import 'package:just_audio/just_audio.dart';

import 'episode_player.dart';
import 'media_item_mapping.dart';
import 'playback_session.dart';

/// The engine's state as the session is told it (1.6.0). `playing` is the
/// engine's own flag, true at the end of a file too: the app pauses it
/// there or loads what follows, and the session says so only then.
SessionState sessionStateOf({
  required bool playing,
  required ProcessingState processingState,
  required Duration position,
  required Duration buffered,
  required double speed,
  required Duration? duration,
}) =>
    SessionState(
      playing: playing,
      phase: switch (processingState) {
        ProcessingState.idle => SessionPhase.idle,
        ProcessingState.loading => SessionPhase.loading,
        ProcessingState.buffering => SessionPhase.buffering,
        ProcessingState.ready => SessionPhase.ready,
        ProcessingState.completed => SessionPhase.completed,
      },
      position: position,
      buffered: buffered,
      speed: speed,
      duration: duration,
    );

class JustAudioEpisodePlayer implements EpisodePlayer, SessionClient {
  JustAudioEpisodePlayer({
    AudioPlayer? player,
    PlaybackSession session = const NoPlaybackSession(),
  })  : _player = player ?? AudioPlayer(),
        _session = session {
    // Every change of state, a seek included, and the play flag and speed,
    // which the engine reports apart from its events.
    _subs
      ..add(_player.playbackEventStream
          .listen((_) => _report(), onError: (Object _) => _report()))
      ..add(_player.playingStream.listen((_) => _report()))
      ..add(_player.speedStream.listen((_) => _report()));
  }

  final AudioPlayer _player;
  final PlaybackSession _session;
  final _subs = <StreamSubscription<Object?>>[];

  /// In the session: set by the first tagged load.
  bool _shown = false;

  /// What the session shows for what is loaded.
  LockScreenTag? _tag;

  void _show(LockScreenTag? tag) {
    if (tag == null) return;
    _tag = tag;
    _session.attach(this, tag);
    _shown = true;
    _report();
  }

  void _report() {
    if (!_shown) return;
    _session.report(
        this,
        sessionStateOf(
          playing: _player.playing,
          processingState: _player.processingState,
          position: _player.position,
          buffered: _player.bufferedPosition,
          speed: _player.speed,
          duration: _player.duration,
        ));
  }

  @override
  Future<void> setUrl(String url, {LockScreenTag? mediaItem}) async {
    _show(mediaItem);
    await _player.setUrl(url);
  }

  @override
  Future<void> setFilePath(String path, {LockScreenTag? mediaItem}) async {
    _show(mediaItem);
    await _player.setFilePath(path);
  }

  @override
  Future<void> setFilePaths(
    List<String> paths, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
    LockScreenTag? mediaItem,
  }) async {
    _show(mediaItem);
    await _player.setAudioSources(
      [for (final p in paths) AudioSource.uri(Uri.file(p))],
      initialIndex: initialIndex,
      initialPosition: initialPosition,
    );
  }

  @override
  Stream<int> get currentIndexStream =>
      _player.currentIndexStream.where((i) => i != null).cast<int>();

  @override
  int? get currentIndex => _player.currentIndex;

  @override
  Future<void> play() async {
    // Whoever plays is in the session: read aloud may have taken it
    // while this was paused, and its reports would then be ignored.
    final tag = _tag;
    if (tag != null) _session.attach(this, tag);
    // just_audio's play() future completes when playback STOPS; fire and
    // return like every UI integration of the package does.
    unawaited(_player.play());
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  /// The session's Stop (the notification's button): the engine lets go
  /// of its decoders and keeps its source and place, so Play in the app
  /// picks it up again. The controller hears it as playing going false.
  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Duration get position => _player.position;

  @override
  Duration? get duration => _player.duration;

  @override
  bool get playing => _player.playing;

  @override
  bool get idle => _player.processingState == ProcessingState.idle;

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Stream<Duration?> get durationStream => _player.durationStream;

  @override
  Stream<bool> get playingStream => _player.playingStream;

  @override
  Stream<void> get completedStream => _player.processingStateStream
      .where((s) => s == ProcessingState.completed);

  /// Leaving the session is what lets the lock screen and the
  /// notification go (the bar's X).
  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    if (_shown) {
      _shown = false;
      _session.detach(this);
    }
    await _player.dispose();
  }
}
