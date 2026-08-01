/// Scripted fake for the EpisodePlayer seam — tests drive position,
/// duration and completion by hand; no audio, no platform channels.
library;

import 'dart:async';

import 'package:trellis/features/player/episode_player.dart';

class FakeEpisodePlayer implements EpisodePlayer {
  final List<String> log = [];

  String? loadedUrl;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration? _duration;
  double lastSpeed = 1.0;
  bool disposed = false;

  final _positionCtrl = StreamController<Duration>.broadcast(sync: true);
  final _durationCtrl = StreamController<Duration?>.broadcast(sync: true);
  final _playingCtrl = StreamController<bool>.broadcast(sync: true);
  final _completedCtrl = StreamController<void>.broadcast(sync: true);

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

  // ── seam ──
  @override
  Future<void> setUrl(String url) async {
    loadedUrl = url;
    log.add('setUrl:$url');
  }

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
