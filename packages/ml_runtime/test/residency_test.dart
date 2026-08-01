import 'package:test/test.dart';
import 'package:ml_runtime/ml_runtime.dart';

/// Residency (proposal-2 §5, memory-residency bullet): desktop holds several
/// models; phones hold ONE, freed before a sibling loads. And transient load
/// failures get a bounded cooldown retry — never a session-long sticky
/// demotion (the donor's evict-to-one jank).
void main() {
  group('ResidencyPolicy', () {
    test('a phone holds one: loading a sibling evicts the resident', () {
      final phone = ResidencyPolicy.phone();
      expect(phone.maxResident, 1);
      expect(
        phone.evictionsFor(incomingId: 'whisper-tiny', residentOldestFirst: ['qwen']),
        ['qwen'],
      );
    });

    test('loading an already-resident model evicts nothing', () {
      final phone = ResidencyPolicy.phone();
      expect(
        phone.evictionsFor(
            incomingId: 'whisper-tiny', residentOldestFirst: ['whisper-tiny']),
        isEmpty,
      );
    });

    test('a desktop holds several: under capacity, nothing is evicted', () {
      final desktop = ResidencyPolicy.desktop();
      expect(
        desktop.evictionsFor(
            incomingId: 'piper', residentOldestFirst: ['whisper-base', 'qwen']),
        isEmpty,
      );
    });

    test('at capacity the oldest goes first', () {
      final desktop = ResidencyPolicy.desktop(maxResident: 3);
      expect(
        desktop.evictionsFor(
          incomingId: 'kokoro',
          residentOldestFirst: ['whisper-base', 'qwen', 'piper'],
        ),
        ['whisper-base'],
      );
    });

    test('over capacity evicts as many oldest as needed', () {
      final policy = ResidencyPolicy(maxResident: 2);
      expect(
        policy.evictionsFor(
          incomingId: 'e',
          residentOldestFirst: ['a', 'b', 'c', 'd'],
        ),
        ['a', 'b', 'c'],
      );
    });

    test('an already-resident model never evicts siblings on a desktop', () {
      final desktop = ResidencyPolicy.desktop(maxResident: 3);
      expect(
        desktop.evictionsFor(
          incomingId: 'qwen',
          residentOldestFirst: ['whisper-base', 'qwen', 'piper'],
        ),
        isEmpty,
      );
    });

    test('maxResident below one is rejected', () {
      expect(() => ResidencyPolicy(maxResident: 0), throwsArgumentError);
    });
  });

  group('LoadRetryPolicy — cooldown, never sticky', () {
    final policy = LoadRetryPolicy();

    test('no failures means no cooldown', () {
      expect(policy.cooldownAfter(0), Duration.zero);
    });

    test('cooldown grows with consecutive failures', () {
      expect(policy.cooldownAfter(2), greaterThan(policy.cooldownAfter(1)));
      expect(policy.cooldownAfter(3), greaterThan(policy.cooldownAfter(2)));
    });

    test('cooldown is capped — even absurd failure counts stay bounded', () {
      expect(policy.cooldownAfter(1000), policy.maxCooldown);
      // And no overflow weirdness on the way there:
      expect(policy.cooldownAfter(63), policy.maxCooldown);
    });

    test('NEVER a permanent demotion: after the cap elapses, retry is allowed', () {
      for (final failures in [1, 5, 100, 10000]) {
        expect(
          policy.shouldRetry(
              consecutiveFailures: failures,
              sinceLastFailure: policy.maxCooldown),
          isTrue,
          reason: '$failures failures must still be retryable',
        );
      }
    });

    test('inside the cooldown window, no retry yet', () {
      expect(
        policy.shouldRetry(
          consecutiveFailures: 3,
          sinceLastFailure: policy.cooldownAfter(3) - const Duration(seconds: 1),
        ),
        isFalse,
      );
    });

    test('with zero failures a load is always allowed', () {
      expect(
        policy.shouldRetry(
            consecutiveFailures: 0, sinceLastFailure: Duration.zero),
        isTrue,
      );
    });
  });
}
