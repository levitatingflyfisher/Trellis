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

class FakeEpisodePlayer implements EpisodePlayer {
  final List<String> log = [];

  String? loadedUrl;
  String? loadedFilePath;
  List<String>? loadedFilePaths;
  int? loadedInitialIndex;
  Duration? loadedInitialPosition;
  int? _currentIndex;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration? _duration;
  double lastSpeed = 1.0;
  double lastVolume = 1.0;
  bool disposed = false;

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

  // ── seam ──
  @override
  Future<void> setUrl(String url) async {
    loadedUrl = url;
    log.add('setUrl:$url');
  }

  @override
  Future<void> setFilePath(String path) async {
    loadedFilePath = path;
    log.add('setFilePath:$path');
  }

  @override
  Future<void> setFilePaths(
    List<String> paths, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  }) async {
    loadedFilePaths = paths;
    loadedInitialIndex = initialIndex;
    loadedInitialPosition = initialPosition;
    _currentIndex = initialIndex;
    _position = initialPosition;
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
    _playing = true;
    log.add('play');
    _playingCtrl.add(true);
  }

  @override
  Future<void> pause() async {
    _playing = false;
    log.add('pause');
    _playingCtrl.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    _position = position;
    log.add('seek:${position.inMilliseconds}');
    _positionCtrl.add(position);
  }

  @override
  Future<void> setSpeed(double speed) async {
    lastSpeed = speed;
    log.add('speed:$speed');
  }

  @override
  Future<void> setVolume(double volume) async {
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
  }
}
