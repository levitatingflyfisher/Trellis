/// The just_audio adapter behind the [EpisodePlayer] seam. Deliberately a
/// thin declarative mapping — every behavior above it (projection writes,
/// promotion on finish, resume, speed law) is tested through the seam with
/// a scripted fake; this file adds no logic of its own.
///
/// Background playback (Campaign 9 Phase 2e, ADR-0015 Decision 3): a
/// [LockScreenTag] arriving on any of the three loaders below becomes a
/// just_audio_background `MediaItem` tag on the `AudioSource` — the ONLY
/// place [MediaItem] (a just_audio_background type) is ever constructed;
/// [EpisodePlayer] itself stays free of it, same as every other plugin
/// type this file alone imports. `JustAudioBackground.init()` itself lives
/// in bootstrap_io.dart, Android/iOS only — this file makes no platform
/// distinction of its own: tagging an AudioSource costs nothing on a
/// platform where init() was never called, since nothing consumes an
/// unused tag.
library;

import 'dart:async';

import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'episode_player.dart';
import 'media_item_mapping.dart';

class JustAudioEpisodePlayer implements EpisodePlayer {
  JustAudioEpisodePlayer({AudioPlayer? player})
      : _player = player ?? AudioPlayer();

  final AudioPlayer _player;

  static MediaItem? _tag(LockScreenTag? info) => info == null
      ? null
      : MediaItem(
          id: info.id,
          title: info.title,
          album: info.album,
          artUri: info.artUri,
        );

  @override
  Future<void> setUrl(String url, {LockScreenTag? mediaItem}) async {
    final tag = _tag(mediaItem);
    if (tag == null) {
      await _player.setUrl(url);
    } else {
      await _player.setAudioSource(AudioSource.uri(Uri.parse(url), tag: tag));
    }
  }

  @override
  Future<void> setFilePath(String path, {LockScreenTag? mediaItem}) async {
    final tag = _tag(mediaItem);
    if (tag == null) {
      await _player.setFilePath(path);
    } else {
      await _player
          .setAudioSource(AudioSource.uri(Uri.file(path), tag: tag));
    }
  }

  @override
  Future<void> setFilePaths(
    List<String> paths, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
    LockScreenTag? mediaItem,
  }) async {
    final tag = _tag(mediaItem);
    await _player.setAudioSources(
      [for (final p in paths) AudioSource.uri(Uri.file(p), tag: tag)],
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
