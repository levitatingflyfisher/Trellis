import 'package:brain_wiring/brain_wiring.dart';
import 'package:test/test.dart';

void main() {
  group('BrainTier', () {
    test('has exactly the five designed tiers', () {
      expect(BrainTier.values, [
        BrainTier.none,
        BrainTier.byokAnthropic,
        BrainTier.byokOpenAiCompatible,
        BrainTier.stove,
        BrainTier.localStub,
      ]);
    });

    test('only the BYOK tiers require egress consent (ADR-0003 law 6)', () {
      expect(BrainTier.byokAnthropic.requiresEgressConsent, isTrue);
      expect(BrainTier.byokOpenAiCompatible.requiresEgressConsent, isTrue);
      // Local/LAN endpoints are exempt by definition.
      expect(BrainTier.none.requiresEgressConsent, isFalse);
      expect(BrainTier.stove.requiresEgressConsent, isFalse);
      expect(BrainTier.localStub.requiresEgressConsent, isFalse);
    });

    test('stove is the only roadmap stub', () {
      expect(BrainTier.stove.isRoadmapStub, isTrue);
      for (final tier in BrainTier.values) {
        if (tier != BrainTier.stove) {
          expect(tier.isRoadmapStub, isFalse, reason: tier.name);
        }
      }
    });
  });

  group('TierSelection', () {
    test('starts at none, not pinned by anyone', () {
      const selection = TierSelection.initial();
      expect(selection.tier, BrainTier.none);
      expect(selection.pinnedByUser, isFalse);
    });

    test('pin() returns a new selection carrying the explicit user choice',
        () {
      const initial = TierSelection.initial();
      final pinned = initial.pin(BrainTier.byokAnthropic);
      expect(pinned.tier, BrainTier.byokAnthropic);
      expect(pinned.pinnedByUser, isTrue);
    });

    test('pin() never mutates the prior selection (no silent fallback)', () {
      const initial = TierSelection.initial();
      initial.pin(BrainTier.byokAnthropic);
      expect(initial.tier, BrainTier.none);
      expect(initial.pinnedByUser, isFalse);
    });

    test('re-pinning replaces the tier, still explicitly', () {
      final selection = const TierSelection.initial()
          .pin(BrainTier.byokAnthropic)
          .pin(BrainTier.localStub);
      expect(selection.tier, BrainTier.localStub);
      expect(selection.pinnedByUser, isTrue);
    });

    test('brainEnabled only when a user pinned a tier other than none', () {
      expect(const TierSelection.initial().brainEnabled, isFalse);
      expect(
        const TierSelection.initial().pin(BrainTier.none).brainEnabled,
        isFalse,
      );
      expect(
        const TierSelection.initial().pin(BrainTier.stove).brainEnabled,
        isTrue,
      );
    });

    test('value equality', () {
      expect(const TierSelection.initial(), const TierSelection.initial());
      expect(
        const TierSelection.initial().pin(BrainTier.stove),
        const TierSelection.initial().pin(BrainTier.stove),
      );
      expect(
        const TierSelection.initial().pin(BrainTier.stove),
        isNot(const TierSelection.initial().pin(BrainTier.localStub)),
      );
    });
  });

  group('UnavailableTierBrain', () {
    test('stove stub fails calmly, naming the roadmap', () {
      final brain = UnavailableTierBrain(BrainTier.stove);
      expect(
        () => brain.complete('anything'),
        throwsA(isA<AskException>().having(
          (e) => e.message.toLowerCase(),
          'message',
          contains('stove'),
        )),
      );
    });

    test('localStub stub fails calmly, naming the missing local model', () {
      final brain = UnavailableTierBrain(BrainTier.localStub);
      expect(
        () => brain.complete('anything'),
        throwsA(isA<AskException>().having(
          (e) => e.message.toLowerCase(),
          'message',
          contains('local model'),
        )),
      );
    });

    test('refuses to stand in for a tier that has a real Brain', () {
      expect(
        () => UnavailableTierBrain(BrainTier.byokAnthropic),
        throwsArgumentError,
      );
      expect(
        () => UnavailableTierBrain(BrainTier.none),
        throwsArgumentError,
      );
    });
  });
}
