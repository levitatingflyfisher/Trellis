/// Which whisper model transcribes (1.6.0, owner: "providing bigger model
/// options … if a person has a better phone that can do better
/// transcribing … I want it").
///
/// The small model stays the default on every phone. A larger one is the
/// listener's own choice on the Models page, never a guess about their
/// phone, so an ordinary phone is never handed a model that crawls.
library;

import 'package:ml_runtime/ml_runtime.dart';

import '../models/format.dart';

/// The device setting: the id of the chosen transcription model. Absent
/// until one is chosen, and then the tier's default applies.
const asrModelKey = 'asr_model';

/// Every transcription model in [registry], smallest first.
List<ModelSpec> asrChoices(ModelRegistry registry) => [
      for (final s in registry.specs)
        if (s.task == ModelTask.asr) s,
    ]..sort((a, b) => a.sizeBytes.compareTo(b.sizeBytes));

/// The model a transcription uses: [choice] when it names a transcription
/// model, whatever tier that model was registered for; else the tier's
/// own default.
ModelSpec? asrModelFor(
    ModelRegistry registry, DeviceTier tier, String? choice) {
  for (final s in registry.specs) {
    if (s.task == ModelTask.asr && s.id == choice) return s;
  }
  return registry.pickModel(ModelTask.asr, tier, langHint: null);
}

/// The words for a choice. Models are named by what they give, with the
/// model's own name in the note for those who know it.
String asrChoiceTitle(ModelSpec spec) => switch (spec.id) {
      'whisper-tiny-ggml' => 'Fast',
      'whisper-base-ggml' => 'More accurate',
      'whisper-small-ggml' => 'Most accurate',
      _ => spec.id,
    };

String asrChoiceNote(ModelSpec spec) => switch (spec.id) {
      'whisper-tiny-ggml' =>
        'Whisper tiny, ${formatBytes(spec.sizeBytes)}. Quickest, and fine '
            'for clear speech. It gets names and unusual words wrong more '
            'often.',
      'whisper-base-ggml' =>
        'Whisper base, ${formatBytes(spec.sizeBytes)}. Fewer wrong words. '
            'About twice as slow, so best on a newer phone.',
      'whisper-small-ggml' =>
        'Whisper small, ${formatBytes(spec.sizeBytes)}. The fewest wrong '
            'words. Several times slower than Fast: for a strong phone, '
            'or an episode you can leave running.',
      _ => formatBytes(spec.sizeBytes),
    };
