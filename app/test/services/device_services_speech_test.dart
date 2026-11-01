import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ml_runtime/ml_runtime.dart';

import '../support/fake_services.dart';

/// DeviceServices.speechEngineFor: the localMlAvailable honesty gate, one
/// layer deeper — even on a tier that can run local ML, speak mode may
/// only offer a SPECIFIC voice once it is actually downloaded.
void main() {
  late Directory dir;
  setUp(() =>
      dir = Directory.systemTemp.createTempSync('trellis-device-services'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  ModelSpec voiceSpec() => ModelRegistry.starter().byId('pocket-en')!;

  test('no voice downloaded means no engine — the caller falls back to the '
      'system voice', () async {
    final services = testServices(dir,
        modelStore: FakeModelStore(), tier: DeviceTier.t2);
    expect(await services.speechEngineFor(voiceSpec()), isNull);
  });

  test('local ML unavailable (the web tier) refuses even if the store '
      'claims the voice is present', () async {
    final services = testServices(dir,
        modelStore: FakeModelStore(downloadedIds: {'pocket-en'}),
        localMlAvailable: false,
        tier: DeviceTier.t2);
    expect(await services.speechEngineFor(voiceSpec()), isNull);
  });

  test('a downloaded voice resolves a real, pausable synthesis engine',
      () async {
    final services = testServices(dir,
        modelStore: FakeModelStore(downloadedIds: {'pocket-en'}),
        tier: DeviceTier.t2);
    final engine = await services.speechEngineFor(voiceSpec());
    expect(engine, isNotNull);
    expect(engine!.canPause, isTrue);
  });

  test('below the voice\'s own minTier (t1), the honesty gate refuses even '
      'if the store claims it is present — the same tier check '
      'resolveSpeechEngine\'s pickModel already applies, one layer '
      'deeper', () async {
    final services = testServices(dir,
        modelStore: FakeModelStore(downloadedIds: {'pocket-en'}),
        tier: DeviceTier.t0);
    expect(await services.speechEngineFor(voiceSpec()), isNull);
  });

  test('a spec with no voice layout is refused quietly, never a crash',
      () async {
    final services = testServices(dir,
        modelStore: FakeModelStore(downloadedIds: {'whisper-tiny-ggml'}),
        tier: DeviceTier.t2);
    final plain = ModelRegistry.starter().byId('whisper-tiny-ggml')!;
    expect(await services.speechEngineFor(plain), isNull);
  });

  group('resolveSpeechEngine — the registry selection law, one call for '
      'ReaderScreen to close over', () {
    test('picks the starter voice for English and resolves it once '
        'downloaded', () async {
      final services = testServices(dir,
          modelStore: FakeModelStore(downloadedIds: {'pocket-en'}),
          tier: DeviceTier.t2);
      final engine = await services.resolveSpeechEngine(lang: 'en');
      expect(engine, isNotNull);
      expect(engine!.canPause, isTrue);
    });

    test('at t1, the tier the app runs at, a downloaded voice resolves '
        '(1.5.8)', () async {
      final services = testServices(dir,
          modelStore: FakeModelStore(downloadedIds: {'pocket-en'}),
          tier: DeviceTier.t1);
      expect(await services.resolveSpeechEngine(lang: 'en'), isNotNull);
    });

    test('below t1 the registry has nothing to pick — the system voice',
        () async {
      final services = testServices(dir,
          modelStore: FakeModelStore(downloadedIds: {'pocket-en'}),
          tier: DeviceTier.t0);
      expect(await services.resolveSpeechEngine(lang: 'en'), isNull);
    });

    test('no voice downloaded resolves to null, the same honesty gate as '
        'speechEngineFor', () async {
      final services =
          testServices(dir, modelStore: FakeModelStore(), tier: DeviceTier.t2);
      expect(await services.resolveSpeechEngine(lang: 'en'), isNull);
    });

    test('a language the starter catalog has no voice for resolves to '
        'null, never the wrong-language voice', () async {
      final services = testServices(dir,
          modelStore: FakeModelStore(downloadedIds: {'pocket-en'}),
          tier: DeviceTier.t2);
      expect(await services.resolveSpeechEngine(lang: 'ru'), isNull);
    });

    test('every downloaded voice comes back together, speaking each '
        'language it names (board-0211)', () async {
      final services = testServices(dir,
          modelStore: FakeModelStore(
              downloadedIds: {'pocket-en', 'pocket-es', 'pocket-pt'}),
          tier: DeviceTier.t2);
      final engine = await services.resolveSpeechEngine(lang: 'pt-BR');
      expect(engine, isNotNull);
      expect(engine!.speaks, {'en', 'es', 'pt'});
      expect(await services.downloadedVoiceLangs(), {'en', 'es', 'pt'});
    });

    test('the Chinese voice, once downloaded, joins the others: each '
        'language goes to its own voice', () async {
      final services = testServices(dir,
          modelStore: FakeModelStore(
              downloadedIds: {'pocket-en', 'pocket-es', 'kokoro-zh-zf001'}),
          tier: DeviceTier.t1);
      expect(await services.downloadedVoiceLangs(), {'en', 'es', 'zh'});
      final zh = await services.speechEngineFor(
          ModelRegistry.starter().byId('kokoro-zh-zf001')!);
      expect(zh, isNotNull);
      expect(zh!.speaks, {'zh'});
      expect((await services.resolveSpeechEngine(lang: 'zh-CN'))!.speaks,
          contains('zh'));
    });

    test('nothing downloaded: no languages', () async {
      final services =
          testServices(dir, modelStore: FakeModelStore(), tier: DeviceTier.t2);
      expect(await services.downloadedVoiceLangs(), isEmpty);
    });

    test('a null language hint still resolves the one voice on the '
        'catalog', () async {
      final services = testServices(dir,
          modelStore: FakeModelStore(downloadedIds: {'pocket-en'}),
          tier: DeviceTier.t2);
      expect(await services.resolveSpeechEngine(), isNotNull);
    });
  });

  group('speechTempDir / createSpeechTempFiles', () {
    test('speechTempDir is rooted under supportDir, not systemTemp',
        () async {
      final services = testServices(dir);
      expect(services.speechTempDir.path, '${dir.path}/speech-temp');
    });

    test('createSpeechTempFiles builds a FRESH writer each call', () async {
      final services = testServices(dir);
      final a = services.createSpeechTempFiles();
      final b = services.createSpeechTempFiles();
      expect(identical(a, b), isFalse);
    });
  });
}
