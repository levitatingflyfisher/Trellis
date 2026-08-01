import 'package:jobs_core/jobs_core.dart';
import 'package:test/test.dart';

/// BackoffPolicy is PURE state — a delay schedule, no timers, no clock.
/// The runner owns when to sleep; the policy only answers "how long before
/// retry n?" and "how many attempts total?".
void main() {
  group('BackoffPolicy.delayForRetry', () {
    test('grows exponentially from baseDelayMs by multiplier', () {
      const policy = BackoffPolicy(
          maxAttempts: 10, baseDelayMs: 500, multiplier: 2.0, maxDelayMs: 60000);
      expect(policy.delayForRetry(1), 500);
      expect(policy.delayForRetry(2), 1000);
      expect(policy.delayForRetry(3), 2000);
      expect(policy.delayForRetry(4), 4000);
      expect(policy.delayForRetry(5), 8000);
    });

    test('is BOUNDED: never exceeds maxDelayMs', () {
      const policy = BackoffPolicy(
          maxAttempts: 10, baseDelayMs: 500, multiplier: 2.0, maxDelayMs: 3000);
      expect(policy.delayForRetry(3), 2000);
      expect(policy.delayForRetry(4), 3000); // 4000 capped
      expect(policy.delayForRetry(9), 3000); // still capped, no overflow
    });

    test('multiplier 1.0 gives a constant schedule', () {
      const policy = BackoffPolicy(
          maxAttempts: 5, baseDelayMs: 250, multiplier: 1.0, maxDelayMs: 60000);
      expect(policy.delayForRetry(1), 250);
      expect(policy.delayForRetry(4), 250);
    });

    test('retry numbers below 1 are a caller bug', () {
      const policy = BackoffPolicy();
      expect(() => policy.delayForRetry(0), throwsArgumentError);
      expect(() => policy.delayForRetry(-1), throwsArgumentError);
    });

    test('defaults are sane: a few attempts, sub-minute cap', () {
      const policy = BackoffPolicy();
      expect(policy.maxAttempts, greaterThanOrEqualTo(2));
      expect(policy.maxDelayMs, lessThanOrEqualTo(60000));
      expect(policy.delayForRetry(1), greaterThan(0));
    });
  });
}
