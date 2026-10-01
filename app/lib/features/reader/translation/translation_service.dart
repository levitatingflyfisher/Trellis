/// The one object screens hold for translation (1.5.5): which languages a
/// work can go into and what each would cost to download, the download
/// itself, and opening a pair's model. Replaces the two callbacks
/// (`resolveTranslator`, `availableTranslationTargets`) the reader used
/// to be threaded with, which could only see pairs already downloaded.
library;

import 'package:ml_runtime/ml_runtime.dart';

import '../../models/model_store.dart';
import 'translation_route.dart' as route_plan;
import 'translation_route.dart' show TranslationRoute;
import 'translator.dart';

class TranslationService {
  final ModelRegistry registry;
  final DeviceTier tier;
  final ModelStore store;

  /// Opens a downloaded pair, or null when it can't be (not downloaded, a
  /// mis-registered spec). [DeviceServices.translatorFor] in the app.
  final Future<SentenceTranslator?> Function(ModelSpec spec) openSpec;

  TranslationService({
    required this.registry,
    required this.tier,
    required this.store,
    required this.openSpec,
  });

  Future<Map<String, int>> _missing() async => {
        for (final s in registry.translationPairsAt(tier))
          s.id: await store.missingBytes(s),
      };

  /// Every language [source] can be translated into, installed or not,
  /// each with what is left to download.
  Future<List<TranslationRoute>> routesFrom(String source) async {
    await topUpTranslationModels(registry, store);
    final missing = await _missing();
    return route_plan.routesFrom(registry, tier,
        source: source, missingBytesOf: (s) => missing[s.id] ?? s.sizeBytes);
  }

  /// The route from [source] to [target] as things stand now; null for
  /// the same language or one no pair reaches.
  Future<TranslationRoute?> route(String source, String target) async {
    final missing = await _missing();
    return route_plan.planRoute(registry, tier,
        source: source,
        target: target,
        missingBytesOf: (s) => missing[s.id] ?? s.sizeBytes);
  }

  /// Starts (or resumes) downloading one leg, through the same resumable,
  /// hash-checked engine the Models screen uses.
  ModelDownload download(ModelSpec spec) => store.download(spec);

  Future<SentenceTranslator?> open(ModelSpec spec) => openSpec(spec);
}

/// A pair this small a fetch away from complete is one downloaded before
/// 1.5.5 registered its two config files (about 2 KB). Weights are never
/// this small, so nothing new is downloaded without the reader asking.
const int _topUpLimitBytes = 64 * 1024;

/// Fetches the missing config files of pairs whose weights are already on
/// the device, quietly: the user agreed to those models when they were
/// downloaded, and without the configs they would read as not downloaded.
/// Failures are left for the next open.
Future<void> topUpTranslationModels(
    ModelRegistry registry, ModelStore store) async {
  for (final spec in registry.specs) {
    if (spec.task != ModelTask.translation) continue;
    final missing = await store.missingBytes(spec);
    if (missing == 0 || missing > _topUpLimitBytes) continue;
    try {
      await store.download(spec).done;
    } catch (_) {
      // Offline or a bad pin: the pair stays as it was; try again later.
    }
  }
}
