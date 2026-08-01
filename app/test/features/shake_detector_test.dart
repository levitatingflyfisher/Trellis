import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/player/shake_detector.dart';

/// The shake-to-extend gesture behind a pure threshold detector: a fake
/// accelerometer stream in, a shake event out — no platform channel, no
/// sensors_plus type, ever touched by a test.
void main() {
  group('ShakeDetector', () {
    late StreamController<AccelerationSample> samples;
    late int clockMs;

    setUp(() {
      samples = StreamController<AccelerationSample>.broadcast(sync: true);
      clockMs = 0;
    });
    tearDown(() => samples.close());

    ShakeDetector detector({double threshold = 25.0}) => ShakeDetector(
        samples: samples.stream,
        threshold: threshold,
        now: () => DateTime.fromMillisecondsSinceEpoch(clockMs));

    test('gentle handling under the threshold never shakes', () async {
      final d = detector();
      var shakes = 0;
      d.shakes.listen((_) => shakes++);

      samples.add(const AccelerationSample(9.8, 0, 0)); // resting gravity
      samples.add(const AccelerationSample(11, 2, 1)); // picked up, not shaken

      expect(shakes, 0);
      await d.dispose();
    });

    test('a sample past the threshold fires one shake', () async {
      final d = detector();
      var shakes = 0;
      d.shakes.listen((_) => shakes++);

      samples.add(const AccelerationSample(30, 0, 0));

      expect(shakes, 1);
      await d.dispose();
    });

    test('a burst inside the cooldown window counts as one shake', () async {
      final d = detector();
      var shakes = 0;
      d.shakes.listen((_) => shakes++);

      samples.add(const AccelerationSample(30, 0, 0));
      clockMs += 500; // well under the 2s cooldown
      samples.add(const AccelerationSample(32, 0, 0));
      clockMs += 500;
      samples.add(const AccelerationSample(28, 0, 0));

      expect(shakes, 1);
      await d.dispose();
    });

    test('two shakes spaced past the cooldown both count', () async {
      final d = detector();
      var shakes = 0;
      d.shakes.listen((_) => shakes++);

      samples.add(const AccelerationSample(30, 0, 0));
      clockMs += 3000; // past the 2s cooldown
      samples.add(const AccelerationSample(30, 0, 0));

      expect(shakes, 2);
      await d.dispose();
    });

    test('magnitude combines all three axes', () {
      const s = AccelerationSample(3, 4, 0);
      expect(s.magnitude, 5.0); // classic 3-4-5 triangle
    });
  });
}
