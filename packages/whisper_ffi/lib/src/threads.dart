/// How many worker threads one whisper run should use.
library;

import 'dart:math' as math;

/// ggml's thread pool waits at a barrier after every op, so a run goes
/// at the pace of its slowest thread. On a phone that mixes fast and slow
/// cores, a thread per core ties every op to a slow core (Trellis 1.5.1
/// used cores − 1: seven threads on a Pixel 6a's four slow and four fast
/// cores). So: only the cores faster than the slowest tier, and never more
/// than four, which is whisper.cpp's own default.
///
/// [maxFreqsKhz] is each core's top frequency, one per core; anything
/// shorter than [cores] counts as unknown, and unknown or uniform cores
/// fall back to cores − 1 so the UI keeps one.
int whisperThreadsFor({required int cores, required List<int> maxFreqsKhz}) {
  const cap = 4;
  if (maxFreqsKhz.length == cores && cores > 0) {
    final slowest = maxFreqsKhz.reduce(math.min);
    final fast = maxFreqsKhz.where((f) => f > slowest).length;
    if (fast > 0) return math.min(fast, cap);
  }
  return (cores - 1).clamp(1, cap);
}
