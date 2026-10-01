/// How a work gets from its language into another one (Trellis 1.5.5):
/// directly, through one registered pair, or through English when no
/// direct pair exists. Firefox Translations does the same: one pivot,
/// English only. The registry stays hub and spoke (ADR-0014): 2N pairs
/// cover every X->Y between N languages, at the cost of a second pass and
/// the quality of the weaker leg.
///
/// Pure: what's installed comes in as [missingBytesOf], so the planner is
/// tested without a model store.
library;

import 'package:ml_runtime/ml_runtime.dart';

const String pivotLanguage = 'en';

/// `en-US`, `pt_BR` and `zh-Hans` all plan as their base language; null
/// for nothing, blank, or `und` (whisper's "couldn't tell").
String? baseLanguage(String? code) {
  if (code == null) return null;
  final base = code.trim().toLowerCase().split(RegExp('[-_]')).first;
  if (base.isEmpty || base == 'und') return null;
  return base;
}

/// What a work is written in: its own `works.lang`, else its feed's
/// language, else the language whisper reported for its transcript.
/// Null means nobody knows and the reader must ask; English is never
/// assumed, because a German article taken for English is offered
/// English pairs and translates nothing.
String? resolveSourceLanguage({
  required String? workLang,
  required String? feedLang,
  required String? transcriptLang,
}) =>
    baseLanguage(workLang) ??
    baseLanguage(feedLang) ??
    baseLanguage(transcriptLang);

/// One model a route runs, and how many bytes of it are still to fetch.
class TranslationLeg {
  final ModelSpec spec;
  final int missingBytes;
  const TranslationLeg(this.spec, this.missingBytes);

  bool get installed => missingBytes == 0;
  String get source => spec.sourceLang!;
  String get target => spec.langs!.single;
}

class TranslationRoute {
  final String source;
  final String target;

  /// One leg for a direct pair; two (source->en, en->target) via English.
  final List<TranslationLeg> legs;

  const TranslationRoute(
      {required this.source, required this.target, required this.legs});

  bool get viaEnglish => legs.length > 1;
  List<TranslationLeg> get missing =>
      [for (final l in legs) if (!l.installed) l];
  int get missingBytes => missing.fold(0, (sum, l) => sum + l.missingBytes);
  bool get ready => missing.isEmpty;
}

/// The route from [source] to [target], or null when there is none: the
/// same language (never English to English), a language no pair reaches,
/// or a tier below the models.
TranslationRoute? planRoute(
  ModelRegistry registry,
  DeviceTier tier, {
  required String source,
  required String target,
  required int Function(ModelSpec spec) missingBytesOf,
}) {
  final from = baseLanguage(source);
  final to = baseLanguage(target);
  if (from == null || to == null || from == to) return null;
  TranslationLeg? leg(String s, String t) {
    final spec =
        registry.pickTranslationPair(tier, sourceLang: s, targetLang: t);
    return spec == null ? null : TranslationLeg(spec, missingBytesOf(spec));
  }

  final direct = leg(from, to);
  if (direct != null) {
    return TranslationRoute(source: from, target: to, legs: [direct]);
  }
  if (from == pivotLanguage || to == pivotLanguage) return null;
  final first = leg(from, pivotLanguage);
  final second = leg(pivotLanguage, to);
  if (first == null || second == null) return null;
  return TranslationRoute(source: from, target: to, legs: [first, second]);
}

/// Every target reachable from [source], one route each: the Translate
/// sheet's list, installed or not.
List<TranslationRoute> routesFrom(
  ModelRegistry registry,
  DeviceTier tier, {
  required String source,
  required int Function(ModelSpec spec) missingBytesOf,
}) {
  final targets = <String>{
    for (final s in registry.translationPairsAt(tier)) ...?s.langs,
    for (final s in registry.translationPairsAt(tier)) ?s.sourceLang,
  };
  return [
    for (final t in targets)
      ?planRoute(registry, tier,
          source: source, target: t, missingBytesOf: missingBytesOf),
  ];
}
