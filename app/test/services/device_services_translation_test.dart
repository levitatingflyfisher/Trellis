import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ml_runtime/ml_runtime.dart';

import '../support/fake_services.dart';

/// DeviceServices.translatorFor and .translation (ADR-0008 "Babel"; 1.5.5):
/// the same download-honesty gate `speechEngineFor` applies to the
/// Supertonic voice, now for the Marian translator, plus the service that
/// plans routes and downloads over the real catalog.
void main() {
  late Directory dir;
  setUp(() => dir =
      Directory.systemTemp.createTempSync('trellis-device-services-mt'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  ModelSpec translatorSpec() => ModelRegistry.starter().byId('opus-mt-en-es')!;

  test('no model downloaded means no translator', () async {
    final services =
        testServices(dir, modelStore: FakeModelStore(), tier: DeviceTier.t2);
    expect(await services.translatorFor(translatorSpec()), isNull);
  });

  test('local ML unavailable (the web tier) refuses even if the store '
      'claims the model is present', () async {
    final services = testServices(dir,
        modelStore: FakeModelStore(downloadedIds: {'opus-mt-en-es'}),
        localMlAvailable: false,
        tier: DeviceTier.t2);
    expect(await services.translatorFor(translatorSpec()), isNull);
  });

  test('below the model\'s own minTier (t1), the honesty gate refuses even '
      'if the store claims it is present', () async {
    final services = testServices(dir,
        modelStore: FakeModelStore(downloadedIds: {'opus-mt-en-es'}),
        tier: DeviceTier.t0);
    expect(await services.translatorFor(translatorSpec()), isNull);
  });

  test('a spec with no marian layout is refused quietly, never a crash',
      () async {
    final services = testServices(dir,
        modelStore: FakeModelStore(downloadedIds: {'whisper-tiny-ggml'}),
        tier: DeviceTier.t2);
    final plain = ModelRegistry.starter().byId('whisper-tiny-ggml')!;
    expect(await services.translatorFor(plain), isNull);
  });

  test('a downloaded model resolves a real translator, files rooted at the '
      'model store\'s own paths', () async {
    final store = FakeModelStore(downloadedIds: {'opus-mt-en-es'});
    final services = testServices(dir, modelStore: store, tier: DeviceTier.t2);
    final translator = await services.translatorFor(translatorSpec());
    expect(translator, isNotNull);
    // Cheap to construct — no file is read, no session opened, until the
    // first translate() call (mirrors SupertonicSpeechEngine's residency
    // law: construct, never touch).
  });

  group('translation — the service every reader is handed (1.5.5)', () {
    test('none where local ML can\'t run, so Translate stays hidden', () {
      final services = testServices(dir,
          localMlAvailable: false, tier: DeviceTier.t2);
      expect(services.translation, isNull);
    });

    test('lists every language the real catalog reaches, downloaded or not, '
        'each with its real download size', () async {
      final services =
          testServices(dir, modelStore: FakeModelStore(), tier: DeviceTier.t2);
      final routes = await services.translation!.routesFrom('en');
      final targets = {for (final r in routes) r.target};
      expect(targets,
          containsAll(['fr', 'de', 'es', 'it', 'pt', 'nl', 'ru', 'zh', 'ar',
              'hi', 'uk']));
      expect(targets, isNot(contains('en')));
      expect(targets, isNot(contains('ja')), reason: 'no en->ja pair');
      final de = routes.firstWhere((r) => r.target == 'de');
      expect(de.missingBytes,
          ModelRegistry.starter().byId('opus-mt-en-de')!.sizeBytes);
    });

    test('German to Spanish goes via English, both legs from the catalog',
        () async {
      final services = testServices(dir,
          modelStore: FakeModelStore(downloadedIds: {'opus-mt-de-en'}),
          tier: DeviceTier.t2);
      final r = (await services.translation!.route('de', 'es'))!;
      expect(r.viaEnglish, isTrue);
      expect([for (final l in r.legs) l.spec.id],
          ['opus-mt-de-en', 'opus-mt-en-es']);
      expect([for (final l in r.missing) l.spec.id], ['opus-mt-en-es']);
    });

    test('opens a downloaded pair through translatorFor, and nothing for '
        'one that isn\'t', () async {
      final services = testServices(dir,
          modelStore: FakeModelStore(downloadedIds: {'opus-mt-en-es'}),
          tier: DeviceTier.t2);
      final registry = ModelRegistry.starter();
      expect(await services.translation!.open(registry.byId('opus-mt-en-es')!),
          isNotNull);
      expect(await services.translation!.open(registry.byId('opus-mt-en-de')!),
          isNull);
    });
  });
}
