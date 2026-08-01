/// The just_audio adapter behind [SpeechAudioQueue] — deliberately a thin
/// declarative mapping onto [AudioPlayer]'s own playlist methods
/// (`addAudioSource`/`clearAudioSources` — `ConcatenatingAudioSource` is
/// deprecated as of this pinned just_audio version), the same shape as
/// `just_audio_player.dart`'s `JustAudioEpisodePlayer`: every behavior
/// above it is tested through the seam with `FakeSpeechAudioQueue`; this
/// file adds no logic of its own, and (matching that file's precedent) is
/// not unit-tested directly — a platform channel has nothing to fake here.
library;

import 'dart:async';

import 'package:just_audio/just_audio.dart';

import 'speech_audio_queue.dart';

class JustAudioSpeechQueue implements SpeechAudioQueue {
  JustAudioSpeechQueue({AudioPlayer? player}) : _player = player ?? AudioPlayer();

  final AudioPlayer _player;

  @override
  Future<void> append(String filePath) =>
      _player.addAudioSource(AudioSource.uri(Uri.file(filePath)));

  @override
  Future<void> play() async {
    // just_audio's play() future completes when playback STOPS; fire and
    // return like every UI integration of the package does (matches
    // JustAudioEpisodePlayer.play()).
    unawaited(_player.play());
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> resume() async => unawaited(_player.play());

  @override
  Future<void> clear() => _player.clearAudioSources();

  @override
  bool get playing => _player.playing;

  @override
  Stream<int> get currentIndexStream =>
      _player.currentIndexStream.where((i) => i != null).cast<int>();

  @override
  Stream<void> get completedStream => _player.processingStateStream
      .where((s) => s == ProcessingState.completed);

  @override
  Future<void> dispose() => _player.dispose();
}
