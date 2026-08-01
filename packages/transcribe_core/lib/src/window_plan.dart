/// The window geometry of the transcription pipeline (proposal-2 §9):
/// 30-second windows, 5 seconds of overlap, so a stride of 25 seconds.
///
/// Pure arithmetic over `totalMs`. The resume law leans on this being a
/// deterministic function of the constructor parameters and nothing else —
/// two processes planning the same episode MUST see the same windows.
library;

class WindowPlan {
  /// Length of one transcription window.
  final int windowMs;

  /// How much of each window re-covers the previous one, so utterances cut
  /// by a window seam are heard whole by the next window.
  final int overlapMs;

  WindowPlan({this.windowMs = 30000, this.overlapMs = 5000}) {
    if (windowMs <= 0) {
      throw ArgumentError.value(windowMs, 'windowMs', 'must be positive');
    }
    if (overlapMs < 0) {
      throw ArgumentError.value(overlapMs, 'overlapMs', 'must not be negative');
    }
    if (overlapMs >= windowMs) {
      throw ArgumentError.value(
          overlapMs, 'overlapMs', 'must be shorter than the window');
    }
  }

  /// How far each successive window's start advances.
  int get strideMs => windowMs - overlapMs;

  /// How many windows cover [totalMs] of audio.
  ///
  /// A window exists only for audio past the previous window's overlap —
  /// otherwise the tail window would transcribe nothing new.
  int unitCount(int totalMs) {
    if (totalMs < 0) {
      throw ArgumentError.value(totalMs, 'totalMs', 'must not be negative');
    }
    if (totalMs == 0) return 0;
    final past = totalMs - overlapMs;
    if (past <= 0) return 1;
    final n = (past + strideMs - 1) ~/ strideMs; // ceil(past / stride)
    return n < 1 ? 1 : n;
  }

  /// Where window [unit] (0-based) starts.
  int startMsOf(int unit) => unit * strideMs;

  /// How long window [unit] is, clipped to the end of the audio.
  int lenMsOf(int unit, int totalMs) {
    final start = startMsOf(unit);
    final remaining = totalMs - start;
    return remaining < windowMs ? remaining : windowMs;
  }
}
