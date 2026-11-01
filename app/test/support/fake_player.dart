/// Scripted fake for the EpisodePlayer seam — tests drive position,
/// duration and completion by hand; no audio, no platform channels.
///
/// [setFilePaths] models just_audio's own gapless-playlist trust contract
/// (Campaign 7, ADR-0013), which is the whole point of testing against it
/// here rather than a real player: nothing in this fake advances
/// [currentIndex] or fires [completedStream] on its own when playback
/// "plays through" a file — a test must call [emitCurrentIndex] for each
/// file boundary and [emitCompleted] exactly once, at the true end of the
/// playlist. A test that calls [emitCompleted] after loading only the
/// first file would pass against a completion law that fires once per
/// FILE — which is not what the real engine does, and not what
/// [PlayerController]'s "finish" hand should react to for a multi-file
/// book.
library;

import 'dart:async';

import 'package:trellis/features/player/episode_player.dart';
import 'package:trellis/features/player/media_item_mapping.dart';

class FakeEpisodePlayer implements EpisodePlayer {
  final List<String> log = [];

  String? loadedUrl;
  String? loadedFilePath;
  List<String>? loadedFilePaths;
  int? loadedInitialIndex;
  Duration? loadedInitialPosition;

  /// Campaign 9 Phase 2e: whatever [LockScreenTag] the last `setUrl`/
  /// `setFilePath`/`setFilePaths` call was given — null on a call that
  /// passed none, exactly like a real un-tagged just_audio load.
  LockScreenTag? loadedMediaItem;
  int? _currentIndex;
  bool _playing = false;

  /// just_audio's processing state is idle until a source loads, and again
  /// once the engine is let go.
  bool _idle = true;
  Duration _position = Duration.zero;
  Duration? _duration;
  double lastSpeed = 1.0;
  double lastVolume = 1.0;
  bool disposed = false;

  /// True once [dispose] has finished, not merely begun: what a second
  /// real player (one per process, under background audio) must wait for.
  bool disposeDone = false;

  /// Holds [setUrl]/[setFilePath] open until completed: a load still in
  /// flight (buffering) when the test acts.
  Completer<void>? loadGate;

  /// Holds [seek] open until completed: a skip the engine has not yet
  /// carried out when the test acts.
  Completer<void>? seekGate;

  /// Holds [pause] open until completed: an engine slow to stop.
  Completer<void>? pauseGate;

  /// Holds [dispose] open until completed: a release still going on.
  Completer<void>? disposeGate;

  /// A real player refuses work once disposed; so does this one, so a
  /// controller that keeps using a released player fails loudly.
  void _live(String what) {
    if (disposed) throw StateError('$what on a disposed player');
  }

  final _positionCtrl = StreamController<Duration>.broadcast(sync: true);
  final _durationCtrl = StreamController<Duration?>.broadcast(sync: true);
  final _playingCtrl = StreamController<bool>.broadcast(sync: true);
  final _completedCtrl = StreamController<void>.broadcast(sync: true);
  final _currentIndexCtrl = StreamController<int>.broadcast(sync: true);

  // ── test steering ──
  void emitPosition(Duration p) {
    _position = p;
    _positionCtrl.add(p);
  }

  /// Moves the playhead without a stream tick: what a real player's
  /// position getter reports between its (at most five a second) ticks.
  void movePositionQuietly(Duration p) => _position = p;

  void emitDuration(Duration? d) {
    _duration = d;
    _durationCtrl.add(d);
  }

  void emitCompleted() {
    _playing = false;
    _completedCtrl.add(null);
  }

  /// Simulates the underlying engine silently advancing to playlist entry
  /// [i] — the ONLY way [currentIndex]/[currentIndexStream] change in
  /// this fake, matching a real gapless engine never asking the app to
  /// drive the transition.
  void emitCurrentIndex(int i) {
    _currentIndex = i;
    _currentIndexCtrl.add(i);
  }

  /// The notification's Stop: the media session lets the engine go
  /// behind the app's back; the app hears only that it stopped playing.
  /// just_audio then reports [snapBackTo], its last event's position
  /// (where this stretch of playing began), and no later event corrects
  /// it: what a real engine did on the emulator (1.5.9).
  ///
  /// [releasedAt]: the engine's last word as just_audio_background lets
  /// it go (ExoPlayer's dispose broadcasts an idle event): a position
  /// reported while [idle], which is not where the listener is.
  void externalStop({Duration? snapBackTo, Duration? releasedAt}) {
    _playing = false;
    if (snapBackTo != null) _position = snapBackTo;
    log.add('externalStop');
    _playingCtrl.add(false);
    if (snapBackTo != null) _positionCtrl.add(snapBackTo);
    if (releasedAt != null) {
      _idle = true;
      _position = releasedAt;
      _positionCtrl.add(releasedAt);
    }
  }

  /// A pause from the lock screen, the notification or a headset:
  /// just_audio_background flips playing off and just_audio reports
  /// [snapBackTo], its last event's position (where this stretch began).
  /// ExoPlayer's own report of where it paused comes later, as a separate
  /// event: a test sends it with [emitPosition].
  void externalPause({Duration? snapBackTo}) {
    _playing = false;
    if (snapBackTo != null) _position = snapBackTo;
    log.add('externalPause');
    _playingCtrl.add(false);
    if (snapBackTo != null) _positionCtrl.add(snapBackTo);
  }

  /// A scrub on the lock screen or the notification's seek bar: the media
  /// session seeks the engine directly, paused or not, and the app hears
  /// only the engine's new position.
  void externalSeek(Duration to) {
    _position = to;
    log.add('externalSeek:${to.inMilliseconds}');
    _positionCtrl.add(to);
  }

  // ── seam ──
  @override
  Future<void> setUrl(String url, {LockScreenTag? mediaItem}) async {
    _live('setUrl');
    // A real engine starts a new source at zero; the saved place is only
    // reached by the seek that follows the load.
    _position = Duration.zero;
    _idle = false;
    loadedUrl = url;
    loadedMediaItem = mediaItem;
    log.add('setUrl:$url');
    await loadGate?.future;
  }

  @override
  Future<void> setFilePath(String path, {LockScreenTag? mediaItem}) async {
    _live('setFilePath');
    _position = Duration.zero;
    _idle = false;
    loadedFilePath = path;
    loadedMediaItem = mediaItem;
    log.add('setFilePath:$path');
    await loadGate?.future;
  }

  @override
  Future<void> setFilePaths(
    List<String> paths, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
    LockScreenTag? mediaItem,
  }) async {
    _live('setFilePaths');
    loadedFilePaths = paths;
    loadedInitialIndex = initialIndex;
    loadedInitialPosition = initialPosition;
    loadedMediaItem = mediaItem;
    _currentIndex = initialIndex;
    _position = initialPosition;
    _idle = false;
    log.add(
      'setFilePaths:${paths.join(",")}@$initialIndex+'
      '${initialPosition.inMilliseconds}',
    );
  }

  @override
  Stream<int> get currentIndexStream => _currentIndexCtrl.stream;

  @override
  int? get currentIndex => _currentIndex;

  @override
  Future<void> play() async {
    _live('play');
    _playing = true;
    log.add('play');
    _playingCtrl.add(true);
  }

  /// The next [pause] throws and leaves it playing: an engine that
  /// failed to pause.
  bool failNextPause = false;

  @override
  Future<void> pause() async {
    _live('pause');
    if (failNextPause) {
      failNextPause = false;
      throw StateError('pause failed');
    }
    await pauseGate?.future;
    _playing = false;
    log.add('pause');
    _playingCtrl.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    _live('seek');
    log.add('seek:${position.inMilliseconds}');
    await seekGate?.future;
    _position = position;
    _positionCtrl.add(position);
  }

  @override
  Future<void> setSpeed(double speed) async {
    _live('setSpeed');
    lastSpeed = speed;
    log.add('speed:$speed');
  }

  @override
  Future<void> setVolume(double volume) async {
    _live('setVolume');
    lastVolume = volume;
    log.add('volume:$volume');
  }

  @override
  Duration get position => _position;

  @override
  Duration? get duration => _duration;

  @override
  bool get playing => _playing;

  @override
  bool get idle => _idle;

  @override
  Stream<Duration> get positionStream => _positionCtrl.stream;

  @override
  Stream<Duration?> get durationStream => _durationCtrl.stream;

  @override
  Stream<bool> get playingStream => _playingCtrl.stream;

  @override
  Stream<void> get completedStream => _completedCtrl.stream;

  @override
  Future<void> dispose() async {
    disposed = true;
    _idle = true;
    await disposeGate?.future;
    disposeDone = true;
  }
}
