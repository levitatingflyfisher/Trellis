/// Provenance stamping: every generated course, layer, and critique says
/// which Brain made it — `{brainTier, modelId}` — so quality expectations
/// stay honest (proposal-2 §7: "The UI names the translating model").
library;

import 'package:brain_wiring/src/tier.dart';

/// Who thought: the tier the user had pinned and the model that ran.
class Provenance {
  const Provenance({required this.brainTier, required this.modelId});

  /// Parses the wire shape produced by [toJson].
  ///
  /// Strict about present-but-wrong values (the house parser posture):
  /// unknown tiers and missing/mistyped fields throw a path-qualified
  /// [FormatException].
  factory Provenance.fromJson(Map<String, dynamic> json) {
    final rawTier = json['brainTier'];
    if (rawTier is! String) {
      throw const FormatException(
          "provenance: missing required 'brainTier' string");
    }
    final tier = BrainTier.values.asNameMap()[rawTier];
    if (tier == null) {
      throw FormatException(
        "provenance: unknown 'brainTier' '$rawTier' (expected one of: "
        '${BrainTier.values.map((t) => t.name).join(', ')})',
      );
    }
    final modelId = json['modelId'];
    if (modelId is! String || modelId.isEmpty) {
      throw const FormatException(
          "provenance: missing required 'modelId' string");
    }
    return Provenance(brainTier: tier, modelId: modelId);
  }

  /// The tier that was pinned when this artifact was generated.
  final BrainTier brainTier;

  /// The model that ran (e.g. `claude-sonnet-5`, a GGUF file id, a stove
  /// upstream name).
  final String modelId;

  /// The wire shape baked into generated `.ohcourse` files and critiques.
  Map<String, Object?> toJson() =>
      {'brainTier': brainTier.name, 'modelId': modelId};

  @override
  bool operator ==(Object other) =>
      other is Provenance &&
      other.brainTier == brainTier &&
      other.modelId == modelId;

  @override
  int get hashCode => Object.hash(brainTier, modelId);

  @override
  String toString() => 'Provenance(${brainTier.name}, $modelId)';
}
