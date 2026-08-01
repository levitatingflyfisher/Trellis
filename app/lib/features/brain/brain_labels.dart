/// Human names for the Brain tiers and the provenance sentence every
/// generated artifact carries ("distilled by tier + model", proposal-2 §7:
/// the UI names the model so quality expectations stay honest).
library;

import 'package:brain_wiring/brain_wiring.dart';

String tierDisplayName(BrainTier tier) => switch (tier) {
      BrainTier.none => 'no brain',
      BrainTier.byokAnthropic => 'your Anthropic key',
      BrainTier.byokOpenAiCompatible => 'an OpenAI-compatible endpoint',
      BrainTier.stove => 'the household stove',
      BrainTier.localStub => 'a local model',
    };

/// The provenance line for a generated course.
String distilledByLine(Provenance p) =>
    'Distilled by ${p.modelId} · ${tierDisplayName(p.brainTier)}';

/// The provenance line for a critique.
String critiqueByLine(Provenance p) =>
    'Critique by ${p.modelId} · ${tierDisplayName(p.brainTier)}';
