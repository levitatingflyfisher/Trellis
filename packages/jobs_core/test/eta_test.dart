import 'package:jobs_core/jobs_core.dart';
import 'package:test/test.dart';

/// Honest ETA: a moving average of measured unit durations, nothing fancier.
/// No samples → no claim (null), never a made-up number.
void main() {
  group('EtaTracker', () {
    test('makes NO claim before the first sample', () {
      final eta = EtaTracker();
      expect(eta.movingAverageMs, isNull);
      expect(eta.etaMsFor(7), isNull);
    });

    test('one sample: eta = sample × unitsRemaining', () {
      final eta = EtaTracker()..addSample(100);
      expect(eta.movingAverageMs, 100.0);
      expect(eta.etaMsFor(3), 300);
    });

    test('zero units remaining is always eta 0', () {
      final eta = EtaTracker()..addSample(100);
      expect(eta.etaMsFor(0), 0);
    });

    test('the average MOVES: old samples fall out of the window', () {
      final eta = EtaTracker(window: 3);
      for (final ms in [100, 100, 100, 400, 400, 400]) {
        eta.addSample(ms);
      }
      // Only the last 3 samples count — the early fast units no longer
      // flatter the estimate.
      expect(eta.movingAverageMs, 400.0);
      expect(eta.etaMsFor(2), 800);
    });

    test('fractional averages round to the nearest ms', () {
      final eta = EtaTracker()
        ..addSample(100)
        ..addSample(101);
      expect(eta.etaMsFor(2), 201); // 100.5 × 2
    });

    test('negative remaining is a caller bug', () {
      final eta = EtaTracker()..addSample(100);
      expect(() => eta.etaMsFor(-1), throwsArgumentError);
    });

    test('a slow spike raises the estimate — honesty over comfort', () {
      final eta = EtaTracker(window: 5);
      for (final ms in [100, 100, 100]) {
        eta.addSample(ms);
      }
      final before = eta.etaMsFor(4)!;
      eta.addSample(2000); // one brutal unit
      final after = eta.etaMsFor(3)!;
      // Fewer units remain, yet the honest estimate GREW.
      expect(after, greaterThan(before));
    });
  });
}
