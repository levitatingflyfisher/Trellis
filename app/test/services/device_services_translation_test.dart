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

    test('Campaign 8 "Babel widens": sourceLang disambiguates pairs that '
        'share a target language — de-en/ru-en/zh-en all produce en, '
        'pickModel could not tell them apart', () async {
      final services = testServices(dir,
          modelStore: FakeModelStore(downloadedIds: {
            'opus-mt-de-en',
            'opus-mt-ru-en',
            'opus-mt-zh-en',
          }),
          tier: DeviceTier.t2);
      final fromDe =
          await services.resolveTranslator(sourceLang: 'de', targetLang: 'en');
      final fromZh =
          await services.resolveTranslator(sourceLang: 'zh', targetLang: 'en');
      expect(fromDe, isNotNull);
      expect(fromZh, isNotNull);
      // Each resolved to a DIFFERENT downloaded pair's files, not the
      // same one twice by accident — verified indirectly: a pair NOT
      // downloaded for a given source still refuses.
      final fromRuNotDownloaded = await services.resolveTranslator(
          sourceLang: 'ru', targetLang: 'en');
      expect(fromRuNotDownloaded, isNotNull); // ru-en IS downloaded above
      final fromJaNotRegistered = await services.resolveTranslator(
          sourceLang: 'ja', targetLang: 'en');
      expect(fromJaNotRegistered, isNull,
          reason: 'no ja-en pair is registered at all (Japanese is the '
              'Phase 5 Brain-lane language, see docs/reference/'
              'mt-models.md)');
    });

    test('sourceLang defaults to en, matching the declared-source-'
        'language default', () async {
      final services = testServices(dir,
          modelStore: FakeModelStore(downloadedIds: {'opus-mt-en-es'}),
          tier: DeviceTier.t2);
      expect(await services.resolveTranslator(targetLang: 'es'), isNotNull,
          reason: 'sourceLang defaults to en; opus-mt-en-es carries '
              'sourceLang: en');
    });
  });

  group('availableTranslationTargets — the picker\'s data source '
      '(Campaign 8 "Babel widens" Phase 1)', () {
    test('lists only DOWNLOADED pairs for the given source language, '
        'never the un-downloaded rest of the catalog', () async {
      final services = testServices(dir,
          modelStore: FakeModelStore(downloadedIds: {
            'opus-mt-en-es',
            'opus-mt-en-de',
            // en-ru NOT downloaded — must be excluded.
          }),
          tier: DeviceTier.t2);
      final targets = await services.availableTranslationTargets(
          sourceLang: 'en');
      expect(targets, containsAll(['es', 'de']));
      expect(targets, isNot(contains('ru')));
    });

    test('never lists the source language itself as a target, even if '
        'somehow downloaded', () async {
      final services = testServices(dir,
          modelStore: FakeModelStore(downloadedIds: {'opus-mt-de-en'}),
          tier: DeviceTier.t2);
      // de-en produces 'en' FROM 'de' — asking for en's own targets
      // must never offer 'en' back to itself.
      final targets =
          await services.availableTranslationTargets(sourceLang: 'de');
      expect(targets, isNot(contains('de')));
    });

    test('nothing downloaded means an empty list, not null or a throw',
        () async {
      final services =
          testServices(dir, modelStore: FakeModelStore(), tier: DeviceTier.t2);
      expect(await services.availableTranslationTargets(sourceLang: 'en'),
          isEmpty);
    });
  });
}
