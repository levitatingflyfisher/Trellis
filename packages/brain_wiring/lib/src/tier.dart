/// The Brain tier model (proposal-2 §7): which rung of the household-AI
/// ladder the user has *explicitly* pinned. Pure data + laws; the Brains
/// themselves live elsewhere (AnthropicBrain here, flutter_gemma /
/// llama.cpp / StoveClient adapters app-side).
///
/// The one law this file enforces by shape: tier selection only ever
/// changes through an explicit [TierSelection.pin] — there is no API that
/// falls back *upward* (toward the cloud) on its own. Silent fallback
/// would turn a local failure into an egress, which ADR-0003 law 6
/// forbids without the consent chokepoint.
library;

import 'package:domovoi/domovoi.dart' show AskException, Brain;

/// The rungs of proposal-2 §7's tier table.
enum BrainTier {
  /// No Brain at all: every Brain feature hidden; keyword-coverage
  /// grading (study_core) still works. Trellis today.
  none,

  /// BYOK Anthropic direct (messages API). Cloud — behind the consent
  /// chokepoint.
  byokAnthropic,

  /// BYOK OpenAI-compatible endpoint (Ollama / LM Studio / OpenRouter).
  /// Cloud by classification; the app's chokepoint exempts loopback/LAN
  /// endpoints per ADR-0003 law 6 (that URL judgment lives with
  /// comms_core's URL hygiene, not here).
  byokOpenAiCompatible,

  /// The household stove (domovoi StoveClient, port 4663). LAN, so exempt
  /// from egress consent — but a roadmap stub in this package until the
  /// app wires the real client.
  stove,

  /// A local on-device model. Stub tier until the LiteRT / llama.cpp
  /// adapters land app-side.
  localStub,
}

/// Laws that hang off a tier.
extension BrainTierLaws on BrainTier {
  /// True for tiers whose Brain leaves the household — these must pass
  /// the one egress consent chokepoint (ADR-0003 law 6). Local and LAN
  /// tiers are exempt by definition.
  bool get requiresEgressConsent =>
      this == BrainTier.byokAnthropic || this == BrainTier.byokOpenAiCompatible;

  /// True for tiers that are designed but not yet buildable here.
  bool get isRoadmapStub => this == BrainTier.stove;
}

/// The user's explicit tier choice. Immutable; the only way the tier
/// changes is [pin], which is called from a settings gesture — never from
/// a fallback path.
class TierSelection {
  /// The out-of-the-box state: no Brain, nothing pinned.
  const TierSelection.initial()
      : tier = BrainTier.none,
        pinnedByUser = false;

  const TierSelection._(this.tier, this.pinnedByUser);

  /// The currently selected tier.
  final BrainTier tier;

  /// Whether a person chose [tier] (as opposed to the initial default).
  final bool pinnedByUser;

  /// The user's hand pins a tier. Returns a new selection; the receiver
  /// is untouched.
  TierSelection pin(BrainTier tier) => TierSelection._(tier, true);

  /// Brain features show only when a person pinned a tier that has one.
  /// A roadmap-stub tier still counts as enabled — its Brain explains
  /// itself calmly instead of hiding.
  bool get brainEnabled => pinnedByUser && tier != BrainTier.none;

  @override
  bool operator ==(Object other) =>
      other is TierSelection &&
      other.tier == tier &&
      other.pinnedByUser == pinnedByUser;

  @override
  int get hashCode => Object.hash(tier, pinnedByUser);

  @override
  String toString() =>
      'TierSelection(${tier.name}${pinnedByUser ? ', pinned' : ''})';
}

/// A [Brain] for tiers the user may pin before their real implementation
/// exists (stove is roadmap; localStub awaits the on-device adapters).
/// Completing always fails with a calm, displayable [AskException] — the
/// feature is honest about what this device cannot do yet, per the
/// fleet's "what runs on this device" posture.
class UnavailableTierBrain implements Brain {
  UnavailableTierBrain(this.tier) {
    if (tier != BrainTier.stove && tier != BrainTier.localStub) {
      throw ArgumentError.value(
        tier,
        'tier',
        'has a real Brain — UnavailableTierBrain only stands in for '
            'stove and localStub',
      );
    }
  }

  /// Which unavailable tier this stands in for.
  final BrainTier tier;

  @override
  Future<String> complete(String prompt) async {
    throw AskException(switch (tier) {
      // Plain words, not internal jargon — a real device tester read
      // "household stove" as insane (Campaign 8 "Babel widens" Addendum 2).
      // The BrainTier.stove identifier itself is unchanged; this is copy
      // only.
      BrainTier.stove =>
        'Your home desktop is not connected yet — that tier is on the '
            'roadmap. Pick another Brain in Settings for now.',
      _ =>
        'No local model is installed on this device yet. Pick another '
            'Brain in Settings for now.',
    });
  }
}
