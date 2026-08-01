import 'package:brain_wiring/brain_wiring.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/brain/brain_store.dart';

import 'brain_test_support.dart';

/// The BrainStore: tier selection is explicit and persisted, the BYOK key
/// lives ONLY in the secret store, and a Brain is constructed at use time —
/// or the store says calmly why there is none. A device whose secure
/// storage cannot even be read behaves as "no brain" instead of crashing
/// (study never blocks on the brain).
void main() {
  late InMemorySecretStore secrets;
  setUp(() => secrets = InMemorySecretStore());

  group('tier selection', () {
    test('out of the box: nothing pinned, brain disabled', () async {
      final store = BrainStore(secrets: secrets);
      final sel = await store.selection();
      expect(sel.pinnedByUser, isFalse);
      expect(sel.tier, BrainTier.none);
      expect(sel.brainEnabled, isFalse);
    });

    test('pinning persists through the secret store', () async {
      final store = BrainStore(secrets: secrets);
      await store.pinTier(BrainTier.byokAnthropic);

      final again = BrainStore(secrets: secrets); // a fresh app launch
      final sel = await again.selection();
      expect(sel.pinnedByUser, isTrue);
      expect(sel.tier, BrainTier.byokAnthropic);
      expect(sel.brainEnabled, isTrue);
    });

    test('an unreadable secret store degrades to no brain, calmly', () async {
      final store = BrainStore(secrets: ThrowingSecretStore());
      final sel = await store.selection();
      expect(sel.brainEnabled, isFalse);
      expect(await store.brainForUse(), isA<BrainNotConfigured>());
    });
  });

  group('key custody', () {
    test('the key is written to the secret store and nowhere else', () async {
      final store = BrainStore(secrets: secrets);
      await store.saveAnthropicKey('  sk-ant-api03-verysecret-tail1234  ');
      expect(secrets.values[BrainStore.anthropicKeyName],
          'sk-ant-api03-verysecret-tail1234',
          reason: 'trimmed, and held by the injected secret store');
      expect(await store.hasAnthropicKey(), isTrue);
    });

    test('the masked form shows edges only, never the middle', () async {
      final store = BrainStore(secrets: secrets);
      await store.saveAnthropicKey('sk-ant-api03-verysecret-tail1234');
      final masked = (await store.maskedAnthropicKey())!;
      expect(masked, isNot(contains('verysecret')));
      expect(masked, startsWith('sk-ant-'));
      expect(masked, endsWith('1234'));
    });

    test('a short string masks to dots only', () {
      expect(maskKey('tiny'), isNot(contains('tiny')));
    });

    test('deleting the key deletes it', () async {
      final store = BrainStore(secrets: secrets);
      await store.saveAnthropicKey('sk-ant-api03-verysecret-tail1234');
      await store.deleteAnthropicKey();
      expect(secrets.values, isNot(contains(BrainStore.anthropicKeyName)));
      expect(await store.hasAnthropicKey(), isFalse);
      expect(await store.maskedAnthropicKey(), isNull);
    });
  });

  group('brainForUse', () {
    test('nothing pinned: not configured, and the message says study '
        'works fully without a brain', () async {
      final store = BrainStore(secrets: secrets);
      final use = await store.brainForUse();
      expect(use, isA<BrainNotConfigured>());
      expect((use as BrainNotConfigured).message,
          contains('works fully without a brain'));
    });

    test('Anthropic pinned without a key: not configured, message names '
        'the missing key', () async {
      final store = BrainStore(secrets: secrets);
      await store.pinTier(BrainTier.byokAnthropic);
      final use = await store.brainForUse();
      expect(use, isA<BrainNotConfigured>());
      expect((use as BrainNotConfigured).message, contains('key'));
    });

    test('Anthropic pinned with a key: ready, egress-consent required, '
        'provenance stamped', () async {
      final store =
          fakeBrainStore(secrets: secrets, brain: FakeBrain(['ok']));
      await store.pinTier(BrainTier.byokAnthropic);
      await store.saveAnthropicKey('sk-ant-k');
      final use = await store.brainForUse();
      expect(use, isA<BrainReady>());
      final ready = use as BrainReady;
      expect(ready.requiresEgressConsent, isTrue);
      expect(ready.egressHost, 'api.anthropic.com');
      expect(ready.provenance.brainTier, BrainTier.byokAnthropic);
      expect(ready.provenance.modelId, 'fake-model');
      expect(await ready.brain.complete('hi'), 'ok');
    });

    test('the real factory builds an AnthropicBrain (no fake injected)',
        () async {
      final store = BrainStore(secrets: secrets);
      await store.pinTier(BrainTier.byokAnthropic);
      await store.saveAnthropicKey('sk-ant-k');
      final use = await store.brainForUse();
      expect(use, isA<BrainReady>());
      expect((use as BrainReady).brain, isA<AnthropicBrain>());
      expect(use.provenance.modelId, AnthropicBrain.defaultModel);
    });

    test('stove: ready but honest — completing explains the roadmap, '
        'no egress consent (LAN)', () async {
      final store = BrainStore(secrets: secrets);
      await store.pinTier(BrainTier.stove);
      final use = await store.brainForUse();
      expect(use, isA<BrainReady>());
      final ready = use as BrainReady;
      expect(ready.requiresEgressConsent, isFalse);
      await expectLater(ready.brain.complete('hi'),
          throwsA(isA<AskException>()));
    });

    test('local model: ready but honest — completing explains no model '
        'is installed yet', () async {
      final store = BrainStore(secrets: secrets);
      await store.pinTier(BrainTier.localStub);
      final use = await store.brainForUse();
      expect(use, isA<BrainReady>());
      expect((use as BrainReady).requiresEgressConsent, isFalse);
      await expectLater(use.brain.complete('hi'),
          throwsA(isA<AskException>()));
    });
  });
}
