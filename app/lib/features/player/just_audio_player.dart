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
  Future<void> setFilePath(String path) async {
    await _player.setFilePath(path);
  }

  @override
  Future<void> setFilePaths(
    List<String> paths, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  }) async {
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
  Future<void> setVolume(double volume) => _player.setVolume(volume);

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
