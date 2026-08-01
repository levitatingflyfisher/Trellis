/// Honest ETA for byte transfers (proposal-2 §9: "honest cumulative MB/% +
/// ETA"): throughput measured over a recent window of real samples. No
/// samples → null, never a made-up number; a stall raises the estimate and
/// eventually withdraws it (rate 0 → null, not infinity).
library;

import 'dart:collection';

class DownloadEta {
  /// How far back the rate window reaches.
  final int windowMs;

  final Queue<({int atMs, int bytes})> _samples = Queue();

  DownloadEta({this.windowMs = 15000}) {
    if (windowMs < 1) {
      throw ArgumentError.value(windowMs, 'windowMs', 'must be positive');
    }
  }

  void addSample({required int atMs, required int receivedBytes}) {
    _samples.addLast((atMs: atMs, bytes: receivedBytes));
    // Keep one sample older than the window so the rate always spans it.
    while (_samples.length > 2 &&
        _samples.first.atMs < atMs - windowMs &&
        _samples.elementAt(1).atMs <= atMs - windowMs) {
      _samples.removeFirst();
    }
  }

  /// Projected ms until [remainingBytes] arrive, or null when there is no
  /// honest evidence of a rate.
  int? etaMs({required int remainingBytes}) {
    if (remainingBytes < 0) {
      throw ArgumentError.value(
          remainingBytes, 'remainingBytes', 'cannot be negative');
    }
    if (remainingBytes == 0) return 0;
    if (_samples.length < 2) return null;
    final first = _samples.first;
    final last = _samples.last;
    final dBytes = last.bytes - first.bytes;
    final dMs = last.atMs - first.atMs;
    if (dBytes <= 0 || dMs <= 0) return null;
    return (remainingBytes * dMs / dBytes).round();
  }
}
