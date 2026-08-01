/// Fake for the SpeechAudioQueue seam — records every append/play/pause/
/// clear call and lets a test drive [currentIndexStream] by hand, so
/// SpeechPlaybackPipeline tests never touch just_audio or a platform
/// channel.
library;

import 'dart:async';

import 'package:trellis/features/reader/speech/speech_audio_queue.dart';

class FakeSpeechAudioQueue implements SpeechAudioQueue {
  final List<String> appended = [];
  int playCalls = 0;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int clearCalls = 0;
  bool disposed = false;

  bool _playing = false;
  final _indexController = StreamController<int>.broadcast();
  final _completedController = StreamController<void>.broadcast();

  @override
  Future<void> append(String filePath) async => appended.add(filePath);

  @override
  Future<void> play() async {
    playCalls++;
    _playing = true;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    _playing = false;
  }

  @override
  Future<void> resume() async {
    resumeCalls++;
    _playing = true;
  }

  @override
  Future<void> clear() async {
    clearCalls++;
    appended.clear();
    _playing = false;
  }

  @override
  bool get playing => _playing;

  @override
  Stream<int> get currentIndexStream => _indexController.stream;

  /// Test hook: simulates the real player actually starting clip [i].
  void emitIndex(int i) => _indexController.add(i);

  @override
  Stream<void> get completedStream => _completedController.stream;

  /// Test hook: simulates the real player reaching the end of everything
  /// appended so far and stopping on its own.
  void emitCompleted() => _completedController.add(null);

  @override
  Future<void> dispose() async {
    disposed = true;
    await _indexController.close();
    await _completedController.close();
  }
}
