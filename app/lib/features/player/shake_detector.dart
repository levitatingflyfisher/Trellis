/// A pure-Dart shake detector for "shake to extend" (the sleep timer):
/// watches a stream of acceleration samples and emits once per shake, with
/// a cooldown so a single physical shake never fires twice. No platform
/// channel lives here — the accelerometer stream is handed in, so tests
/// drive a fake one and the real wiring (sensors_plus) is a thin adapter
/// elsewhere that never needs its own test.
library;

import 'dart:async';
import 'dart:math' as math;

/// One accelerometer reading, in the same units sensors_plus reports
/// (m/s^2). Gravity is NOT subtracted out here — a phone at rest already
/// reads roughly 9.8 on one axis, and [threshold] is chosen with that
/// baseline in mind.
class AccelerationSample {
  final double x;
  final double y;
  final double z;
  const AccelerationSample(this.x, this.y, this.z);

  double get magnitude => math.sqrt(x * x + y * y + z * z);
}

class ShakeDetector {
  ShakeDetector({
    required Stream<AccelerationSample> samples,
    this.threshold = 25.0,
    this.cooldown = const Duration(seconds: 2),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _sub = samples.listen(_onSample);
  }

  /// Magnitude a sample must clear to count as a shake. 25 m/s^2 sits well
  /// above resting gravity (~9.8) and ordinary handling, comfortably below
  /// a deliberate shake.
  final double threshold;

  /// Two crossings inside this window count as one gesture, not a burst of
  /// triggers while the hand is still moving.
  final Duration cooldown;

  final DateTime Function() _now;
  late final StreamSubscription<AccelerationSample> _sub;
  final _shakeCtrl = StreamController<void>.broadcast(sync: true);
  DateTime? _lastShakeAt;

  Stream<void> get shakes => _shakeCtrl.stream;

  void _onSample(AccelerationSample s) {
    if (s.magnitude < threshold) return;
    final now = _now();
    final last = _lastShakeAt;
    if (last != null && now.difference(last) < cooldown) return;
    _lastShakeAt = now;
    if (!_shakeCtrl.isClosed) _shakeCtrl.add(null);
  }

  Future<void> dispose() async {
    await _sub.cancel();
    await _shakeCtrl.close();
  }
}
