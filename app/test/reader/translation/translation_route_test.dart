import 'package:flutter_test/flutter_test.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:trellis/features/reader/translation/translation_route.dart';

ModelSpec _pair(String src, String tgt, int bytes) => ModelSpec(
      id: 'opus-mt-$src-$tgt',
      task: ModelTask.translation,
      files: [
        ModelFile(
            url: 'https://example.test/$src-$tgt.onnx',
            sha256: 'a' * 64,
            bytes: bytes),
      ],
      licenses: const ['CC-BY-4.0'],
      minTier: DeviceTier.t2,
      langs: {tgt},
      sourceLang: src,
    );

final _registry = ModelRegistry([
  _pair('en', 'es', 100),
  _pair('es', 'en', 110),
  _pair('en', 'de', 200),
  _pair('de', 'en', 210),
  _pair('ja', 'en', 300), // one-way: no en-ja
]);

void main() {
  group('planRoute — direct, via English, or not at all', () {
    test('a direct pair is one leg; nothing missing once installed', () {
      final r = planRoute(_registry, DeviceTier.t2,
          source: 'en', target: 'de', missingBytesOf: (_) => 0)!;
      expect(r.viaEnglish, isFalse);
      expect(r.legs.map((l) => l.spec.id), ['opus-mt-en-de']);
      expect(r.ready, isTrue);
      expect(r.missingBytes, 0);
    });

    test('X->Y with no direct model pivots through English, in order', () {
      final r = planRoute(_registry, DeviceTier.t2,
          source: 'de', target: 'es', missingBytesOf: (s) => s.sizeBytes)!;
      expect(r.viaEnglish, isTrue);
      expect(r.legs.map((l) => l.spec.id), ['opus-mt-de-en', 'opus-mt-en-es']);
    });

    test('missing legs are listed with their own sizes and totalled', () {
      final r = planRoute(_registry, DeviceTier.t2,
          source: 'de',
          target: 'es',
          missingBytesOf: (s) => s.id == 'opus-mt-de-en' ? 0 : 100)!;
      expect(r.missing.map((l) => l.spec.id), ['opus-mt-en-es']);
      expect(r.missing.single.missingBytes, 100);
      expect(r.missingBytes, 100);
      expect(r.ready, isFalse);

      final both = planRoute(_registry, DeviceTier.t2,
          source: 'ja', target: 'de', missingBytesOf: (s) => s.sizeBytes)!;
      expect(both.missing.map((l) => l.missingBytes), [300, 200]);
      expect(both.missingBytes, 500);
    });

    test('the same language is refused: never English to English', () {
      expect(
          planRoute(_registry, DeviceTier.t2,
              source: 'en', target: 'en', missingBytesOf: (_) => 0),
          isNull);
      expect(
          planRoute(_registry, DeviceTier.t2,
              source: 'de', target: 'de', missingBytesOf: (_) => 0),
          isNull);
    });

    test('a target with no en->X model is unreachable, even via English', () {
      expect(
          planRoute(_registry, DeviceTier.t2,
              source: 'de', target: 'ja', missingBytesOf: (_) => 0),
          isNull);
      expect(
          planRoute(_registry, DeviceTier.t2,
              source: 'en', target: 'ja', missingBytesOf: (_) => 0),
          isNull);
    });

    test('a tier below the models finds nothing', () {
      expect(
          planRoute(_registry, DeviceTier.t1,
              source: 'en', target: 'de', missingBytesOf: (_) => 0),
          isNull);
    });

    test('regional and script tags plan as their base language', () {
      final r = planRoute(_registry, DeviceTier.t2,
          source: 'de-AT', target: 'es_MX', missingBytesOf: (_) => 0)!;
      expect(r.source, 'de');
      expect(r.target, 'es');
    });
  });

  group('routesFrom — the Translate sheet\'s list', () {
    test('every reachable target, the source itself never among them', () {
      final routes = routesFrom(_registry, DeviceTier.t2,
          source: 'de', missingBytesOf: (_) => 0);
      expect(routes.map((r) => r.target).toSet(), {'en', 'es'});
    });

    test('from English: every en->X target, direct', () {
      final routes = routesFrom(_registry, DeviceTier.t2,
          source: 'en', missingBytesOf: (_) => 0);
      expect(routes.map((r) => r.target).toSet(), {'es', 'de'});
      expect(routes.every((r) => !r.viaEnglish), isTrue);
    });
  });

  group('resolveSourceLanguage — what the work is written in', () {
    test('the work\'s own language wins', () {
      expect(
          resolveSourceLanguage(
              workLang: 'de', feedLang: 'en-us', transcriptLang: 'fr'),
          'de');
    });

    test('then the feed\'s language, normalized to its base', () {
      expect(
          resolveSourceLanguage(
              workLang: null, feedLang: 'de-DE', transcriptLang: 'fr'),
          'de');
    });

    test('then the language whisper reported for the transcript', () {
      expect(
          resolveSourceLanguage(
              workLang: null, feedLang: null, transcriptLang: 'fr'),
          'fr');
    });

    test('blank and "und" are no answer; nothing known means ask (null), '
        'never a guess of English', () {
      expect(
          resolveSourceLanguage(
              workLang: ' ', feedLang: 'und', transcriptLang: null),
          isNull);
      expect(
          resolveSourceLanguage(
              workLang: null, feedLang: '', transcriptLang: 'und'),
          isNull);
    });
  });

  test('baseLanguage folds case, region and script', () {
    expect(baseLanguage('en-US'), 'en');
    expect(baseLanguage('pt_BR'), 'pt');
    expect(baseLanguage('zh-Hans'), 'zh');
    expect(baseLanguage('DE'), 'de');
    expect(baseLanguage(null), isNull);
    expect(baseLanguage('  '), isNull);
  });
}
