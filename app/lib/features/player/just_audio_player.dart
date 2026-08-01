/// The just_audio adapter behind the [EpisodePlayer] seam. Deliberately a
/// thin declarative mapping — every behavior above it (projection writes,
/// promotion on finish, resume, speed law) is tested through the seam with
/// a scripted fake; this file adds no logic of its own.
///
/// Background playback (audio_service, lock-screen controls) is P3 by
/// design — do not add it here.
library;

import 'dart:async';

import 'package:just_audio/just_audio.dart';

import 'episode_player.dart';

class JustAudioEpisodePlayer implements EpisodePlayer {
  JustAudioEpisodePlayer({AudioPlayer? player})
      : _player = player ?? AudioPlayer();

  final AudioPlayer _player;

  @override
  Future<void> setUrl(String url) async {
    await _player.setUrl(url);
  }

  @override
  Future<void> play() async {
    // just_audio's play() future completes when playback STOPS; fire and
    // return like every UI integration of the package does.
    unawaited(_player.play());
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  @override
  Duration get position => _player.position;

  @override
  Duration? get duration => _player.duration;

  @override
  bool get playing => _player.playing;

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Stream<Duration?> get durationStream => _player.durationStream;

  @override
  Stream<bool> get playingStream => _player.playingStream;

  @override
  Stream<void> get completedStream => _player.processingStateStream
      .where((s) => s == ProcessingState.completed);

  @override
  Future<void> dispose() => _player.dispose();
}
