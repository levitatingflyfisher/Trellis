/// The seekable PCM seam the transcription task reads through.
///
/// `ml_runtime`'s `PcmChunkSource` is a forward-only stream — right for an
/// engine consuming audio once, wrong for a resumable job that must re-open
/// the episode at window 37 after a process kill. This seam is the
/// random-access counterpart: the decode step (proposal-2 §5: ffmpeg →
/// 16kHz mono PCM *file*, never a giant buffer in RAM) sits behind it in
/// the app; tests script it.
library;

import 'dart:typed_data';

abstract class PcmSource {
  /// Samples per second; the whisper pipeline expects 16000.
  int get sampleRate;

  /// Total length of the decoded audio.
  int get totalMs;

  /// The mono samples for `[startMs, startMs + lenMs)` —
  /// `lenMs * sampleRate / 1000` of them. Reading the same window twice
  /// MUST return the same samples: the resume law transcribes a window
  /// whose commit was lost a second time and expects identical output.
  Future<Float32List> readWindow(int startMs, int lenMs);
}
