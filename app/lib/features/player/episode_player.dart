/// The audio seam. The app talks to this; just_audio lives behind it
/// (just_audio_player.dart) and tests drive a scripted fake — no platform
/// channel is ever reachable from a widget test.
library;

abstract class EpisodePlayer {
  Future<void> setUrl(String url);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);

  /// 1.0–2.0; values outside are the caller's bug.
  Future<void> setSpeed(double speed);

  Duration get position;
  Duration? get duration;
  bool get playing;

  Stream<Duration> get positionStream;
  Stream<Duration?> get durationStream;
  Stream<bool> get playingStream;

  /// Emits once when the loaded episode plays to its end.
  Stream<void> get completedStream;

  Future<void> dispose();
}
