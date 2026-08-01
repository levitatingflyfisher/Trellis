/// Honest ETA (proposal-2 §9): a moving average of MEASURED unit durations.
library;

import 'dart:collection';

/// Tracks recent unit durations and projects time remaining.
///
/// Honesty rules: no samples → null (never a made-up number); a slow unit
/// RAISES the estimate; durations come from the runner's injected clock and
/// include retry time — the user waits through retries too. Estimates are
/// not persisted across resume: a dead process's timings are stale evidence.
class EtaTracker {
  /// How many recent samples the average moves over.
  final int window;
  final Queue<int> _samples = Queue();

  EtaTracker({this.window = 5}) {
    if (window < 1) {
      throw ArgumentError.value(window, 'window', 'must be at least 1');
    }
  }

  void addSample(int durationMs) {
    _samples.addLast(durationMs);
    while (_samples.length > window) {
      _samples.removeFirst();
    }
  }

  /// Moving average over the window, or null before the first sample.
  double? get movingAverageMs {
    if (_samples.isEmpty) return null;
    var sum = 0;
    for (final s in _samples) {
      sum += s;
    }
    return sum / _samples.length;
  }

  /// Projected ms until done, or null before the first sample.
  /// [unitsRemaining] of 0 is always 0 — finished is finished.
  int? etaMsFor(int unitsRemaining) {
    if (unitsRemaining < 0) {
      throw ArgumentError.value(
          unitsRemaining, 'unitsRemaining', 'cannot be negative');
    }
    final avg = movingAverageMs;
    if (avg == null) return null;
    return (avg * unitsRemaining).round();
  }
}
