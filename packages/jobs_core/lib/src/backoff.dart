/// Bounded retry backoff as PURE state.
library;

import 'dart:math' as math;

/// A delay schedule for retrying a failed unit. No timers, no clock — the
/// runner asks "how long before retry n?" and sleeps through its injected
/// sleep seam. Deterministic by design (no jitter; a platform adapter that
/// wants jitter adds it at the sleep seam, where randomness belongs).
class BackoffPolicy {
  /// Total attempts per unit, the first one included. Always finite —
  /// unbounded retry is how a job pretends to run forever.
  final int maxAttempts;
  final int baseDelayMs;

  /// Growth factor per retry: delay(n) = baseDelayMs × multiplier^(n−1).
  final double multiplier;

  /// Hard ceiling on any single delay.
  final int maxDelayMs;

  const BackoffPolicy({
    this.maxAttempts = 4,
    this.baseDelayMs = 500,
    this.multiplier = 2.0,
    this.maxDelayMs = 15000,
  });

  /// Delay in ms before retry [retry] (1 = the delay before the second
  /// attempt). Pure; capped at [maxDelayMs].
  int delayForRetry(int retry) {
    if (retry < 1) {
      throw ArgumentError.value(retry, 'retry', 'retries are numbered from 1');
    }
    final raw = baseDelayMs * math.pow(multiplier, retry - 1);
    return math.min(maxDelayMs.toDouble(), raw).round();
  }
}
