import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/player/sleep_timer.dart';

/// The sleep timer's volume fade: full volume until the final 20 seconds,
/// then a linear ramp to silence exactly at the stop instant. Pure function
/// — no player, no timer, just remaining time in.
void main() {
  group('sleepTimerFadeVolume', () {
    test('full volume outside the fade window', () {
      expect(sleepTimerFadeVolume(const Duration(seconds: 25)), 1.0);
      expect(sleepTimerFadeVolume(const Duration(minutes: 5)), 1.0);
    });

    test('exactly at the fade window boundary is still full volume', () {
      expect(sleepTimerFadeVolume(const Duration(seconds: 20)), 1.0);
    });

    test('ramps linearly inside the window', () {
      expect(sleepTimerFadeVolume(const Duration(seconds: 10)), 0.5);
      expect(sleepTimerFadeVolume(const Duration(seconds: 4)), closeTo(0.2, 1e-9));
    });

    test('silent at and past the stop instant', () {
      expect(sleepTimerFadeVolume(Duration.zero), 0.0);
      expect(sleepTimerFadeVolume(const Duration(seconds: -5)), 0.0);
    });

    test('a custom fade window is honoured', () {
      expect(
          sleepTimerFadeVolume(const Duration(seconds: 5),
              fadeWindow: const Duration(seconds: 10)),
          0.5);
    });
  });
}
