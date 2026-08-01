/// The audio seam. The app talks to this; just_audio lives behind it
/// (just_audio_player.dart) and tests drive a scripted fake — no platform
/// channel is ever reachable from a widget test.
library;

abstract class EpisodePlayer {
  Future<void> setUrl(String url);

  /// Loads audio from a local file rather than the network (Campaign 6):
  /// the downloaded/processed copy at [path] IS the episode once one
  /// exists — the caller decides when to prefer this over [setUrl], this
  /// method only ever loads what it's told.
  Future<void> setFilePath(String path);

  /// Loads a GAPLESS playlist of local files (Campaign 7, ADR-0013) — an
  /// audiobook's files, in playback order. [initialIndex]/[initialPosition]
  /// resume mid-book without a seek-after-load flash. The underlying
  /// engine (not this app) is what makes file-to-file advance gapless and
  /// silent: [completedStream] only fires once, after the LAST file, and
  /// [position]/[duration] are relative to whichever file is current, not
  /// the playlist as a whole — see [currentIndexStream].
  Future<void> setFilePaths(
    List<String> paths, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  });

  /// Which playlist entry is current, 0-based — meaningless (and never
  /// read) outside a [setFilePaths] load. Fires exactly on each file
  /// boundary the underlying engine advances through on its own.
  Stream<int> get currentIndexStream;

  /// A synchronous read of the same value [currentIndexStream] emits —
  /// null before anything has loaded. For a plain [setUrl]/[setFilePath]
  /// load (every non-audiobook caller) this is always null; callers that
  /// care use it only after a [setFilePaths] load.
  int? get currentIndex;

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);

  /// 1.0–2.0; values outside are the caller's bug.
  Future<void> setSpeed(double speed);

  /// 0.0 (silent) – 1.0 (full); the sleep timer's fade lives above this,
  /// this just applies the number.
  Future<void> setVolume(double volume);

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
