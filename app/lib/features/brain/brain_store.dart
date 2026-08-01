/// The Brain settings and their custody (proposal-2 §7 wiring): which tier
/// the user has explicitly pinned, where the BYOK key lives, and how a
/// [Brain] is constructed at use time.
///
/// Custody law: the API key is held ONLY by the [BrainSecretStore] —
/// flutter_secure_storage in production — never the database, never prefs,
/// never a field that outlives a call. Deleting it deletes it.
///
/// Degradation law: a device whose secure storage cannot be read behaves
/// as "no brain". Study works fully without one, so the brain must never
/// be the thing that takes a session down.
library;

import 'package:brain_wiring/brain_wiring.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'dio_brain_http.dart';

/// The narrow seam over secret storage, so widget tests inject an
/// in-memory map and never touch the plugin channel.
abstract interface class BrainSecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Production custody: flutter_secure_storage (Keystore-backed on Android,
/// WebCrypto-backed in the PWA).
class SecureBrainSecretStore implements BrainSecretStore {
  SecureBrainSecretStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  /// Reads are deadline-bound because an absent platform implementation
  /// HANGS the channel rather than throwing (proven under flutter test:
  /// the unmocked plugin's future never completes — a MissingPlugin
  /// throw was the wrong assumption). The TimeoutException lands in
  /// [BrainStore]'s degrade-to-no-brain catch, so a session load can
  /// never wait on secure storage forever.
  static const Duration _readDeadline = Duration(seconds: 5);

  @override
  Future<String?> read(String key) =>
      _storage.read(key: key).timeout(_readDeadline);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Edges only, never the middle: enough for "yes, that's my key", useless
/// to a shoulder or a screenshot.
String maskKey(String key) {
  if (key.length <= 12) return '••••••••';
  return '${key.substring(0, 7)}…${key.substring(key.length - 4)}';
}

/// What [BrainStore.brainForUse] hands back: a Brain ready to run, or a
/// calm one-line reason there is none.
sealed class BrainUse {
  const BrainUse();
}

/// No runnable Brain right now. [message] is displayable as-is — the
/// task's "explains instead of running" line.
class BrainNotConfigured extends BrainUse {
  const BrainNotConfigured(this.message);
  final String message;
}

/// A Brain constructed for THIS use. Cloud tiers must pass the one egress
/// consent chokepoint before [brain] is asked anything (ADR-0003 law 6);
/// [egressHost] is the honest name the consent dialog shows.
class BrainReady extends BrainUse {
  const BrainReady({
    required this.brain,
    required this.provenance,
    required this.requiresEgressConsent,
    this.egressHost = '',
  });

  final Brain brain;

  /// Stamped into whatever this Brain generates (tier + model id).
  final Provenance provenance;

  final bool requiresEgressConsent;

  /// Where bytes would go, for the consent sentence. Empty for local/LAN.
  final String egressHost;
}

/// Builds the BYOK Anthropic Brain from a key. Injectable so tests swap in
/// a FakeBrain script — no test ever constructs a real HTTP path.
typedef AnthropicBrainFactory = ({Brain brain, Provenance provenance})
    Function(String apiKey);

class BrainStore {
  BrainStore({
    required BrainSecretStore secrets,
    AnthropicBrainFactory? anthropicFactory,
  })  : _secrets = secrets,
        _anthropicFactory = anthropicFactory ?? _realAnthropic;

  /// The production wiring: real secure storage, real AnthropicBrain over
  /// dio. Construction is cheap; nothing is read until asked.
  factory BrainStore.production() =>
      BrainStore(secrets: SecureBrainSecretStore());

  /// Secret-store entry names. Public so tests can prove custody.
  static const String tierName = 'brain.tier';
  static const String anthropicKeyName = 'brain.anthropic_api_key';

  final BrainSecretStore _secrets;
  final AnthropicBrainFactory _anthropicFactory;

  static ({Brain brain, Provenance provenance}) _realAnthropic(
      String apiKey) {
    final brain =
        AnthropicBrain(http: DioBrainHttpClient(), apiKey: apiKey);
    return (brain: brain, provenance: brain.provenance);
  }

  /// Reads that must never take the app down: an unreadable secret store
  /// (no plugin, locked keystore) is "nothing stored" — the Thinking
  /// screen shows unconfigured and study carries on.
  Future<String?> _readQuiet(String key) async {
    try {
      return await _secrets.read(key);
    } catch (_) {
      return null;
    }
  }

  /// The persisted tier choice. Only [pinTier] — a settings tap — ever
  /// changes it (brain_wiring's no-silent-fallback law).
  Future<TierSelection> selection() async {
    final raw = await _readQuiet(tierName);
    final tier = raw == null ? null : BrainTier.values.asNameMap()[raw];
    if (tier == null) return const TierSelection.initial();
    return const TierSelection.initial().pin(tier);
  }

  /// The user's hand pins a tier (including [BrainTier.none] — an explicit
  /// "no brain" is a choice too).
  Future<void> pinTier(BrainTier tier) => _secrets.write(tierName, tier.name);

  Future<bool> hasAnthropicKey() async =>
      (await _readQuiet(anthropicKeyName)) != null;

  /// The masked display form, or null when no key is stored. The raw key
  /// never leaves this store except into the Brain being constructed.
  Future<String?> maskedAnthropicKey() async {
    final key = await _readQuiet(anthropicKeyName);
    return key == null ? null : maskKey(key);
  }

  Future<void> saveAnthropicKey(String key) =>
      _secrets.write(anthropicKeyName, key.trim());

  Future<void> deleteAnthropicKey() => _secrets.delete(anthropicKeyName);

  /// Constructs the Brain for the pinned tier AT USE TIME — settings hold
  /// no live Brain — or says calmly why there is none. Roadmap tiers
  /// (stove, local) come back ready-but-honest: their Brain's first
  /// completion explains itself with an AskException instead of hiding.
  Future<BrainUse> brainForUse() async {
    final sel = await selection();
    if (!sel.brainEnabled) {
      // No arrows here: U+2192 is outside the bundled fonts' cmaps (the
      // fleet's C7 tofu trap, on record).
      return const BrainNotConfigured(
          'Study works fully without a brain. To distill courses and ask '
          'for critiques, choose one under Thinking, in the Courses tab.');
    }
    switch (sel.tier) {
      case BrainTier.none:
        // Unreachable while brainEnabled excludes none; kept exhaustive.
        return const BrainNotConfigured(
            'Study works fully without a brain.');
      case BrainTier.byokAnthropic:
        final key = await _readQuiet(anthropicKeyName);
        if (key == null || key.isEmpty) {
          return const BrainNotConfigured(
              'Your Anthropic brain needs its API key — add it under '
              'Thinking, in the Courses tab.');
        }
        final built = _anthropicFactory(key);
        return BrainReady(
          brain: built.brain,
          provenance: built.provenance,
          requiresEgressConsent: true,
          egressHost: 'api.anthropic.com',
        );
      case BrainTier.byokOpenAiCompatible:
        // The tier exists in the model; its endpoint UI is not built yet.
        return const BrainNotConfigured(
            'An OpenAI-compatible endpoint is not wired in this build yet '
            '— pick another brain under Thinking, in the Courses tab.');
      case BrainTier.stove:
      case BrainTier.localStub:
        // LAN / on-device: exempt from egress consent by definition
        // (ADR-0003 law 6). The stand-in Brain answers every ask with a
        // calm, displayable explanation of the roadmap.
        return BrainReady(
          brain: UnavailableTierBrain(sel.tier),
          provenance:
              Provenance(brainTier: sel.tier, modelId: 'not-installed'),
          requiresEgressConsent: false,
        );
    }
  }
}
