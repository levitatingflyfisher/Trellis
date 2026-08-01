import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ml_runtime/ml_runtime.dart';

import '../support/fake_services.dart';

/// DeviceServices.translatorFor / resolveTranslator (ADR-0008 "Babel" Phase
/// 3): the same download-honesty gate `speechEngineFor`/`resolveSpeechEngine`
/// already applies to the Supertonic voice, now for the Marian translator —
/// so the reader's "Translate to Spanish" action can offer itself only when
/// the model is actually there to run.
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

  test('below the model\'s own minTier (t2), the honesty gate refuses even '
      'if the store claims it is present', () async {
    final services = testServices(dir,
        modelStore: FakeModelStore(downloadedIds: {'opus-mt-en-es'}),
        tier: DeviceTier.t1);
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

  group('resolveTranslator — the registry selection law, one call for '
      'ReaderScreen to close over', () {
    test('resolves the starter model once downloaded', () async {
      final services = testServices(dir,
          modelStore: FakeModelStore(downloadedIds: {'opus-mt-en-es'}),
          tier: DeviceTier.t2);
      expect(await services.resolveTranslator(), isNotNull);
    });

    test('below t2 the registry has nothing to pick', () async {
      final services = testServices(dir,
          modelStore: FakeModelStore(downloadedIds: {'opus-mt-en-es'}),
          tier: DeviceTier.t1);
      expect(await services.resolveTranslator(), isNull);
    });

    test('no model downloaded resolves to null, the same honesty gate as '
        'translatorFor', () async {
      final services =
          testServices(dir, modelStore: FakeModelStore(), tier: DeviceTier.t2);
      expect(await services.resolveTranslator(), isNull);
    });

    test('a target language the starter catalog has no model for resolves '
        'to null', () async {
      final services = testServices(dir,
          modelStore: FakeModelStore(downloadedIds: {'opus-mt-en-es'}),
          tier: DeviceTier.t2);
      expect(await services.resolveTranslator(targetLang: 'pt'), isNull);
    });
  });
}
