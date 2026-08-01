import 'package:brain_wiring/brain_wiring.dart' show AskException;
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/reader/translation/brain_translator.dart';

import '../../support/fake_brain.dart';

/// BrainTranslator (Campaign 8 "Babel widens" Phase 5): a Brain-backed
/// second rung behind TranslationJobController.translateBatch, proven
/// here against a scripted fake Brain — no tier ladder, no consent, no
/// UI. Marian stays the offline floor regardless of what this class can
/// do; this is a second Translator, not a replacement.
void main() {
  group('translateBatch — the happy path', () {
    test('sends one prompt per call, parses the JSON array back in order',
        () async {
      final brain = FakeBrain([
        '{"translations": ["Hola.", "Adios."]}',
      ]);
      final translator = BrainTranslator(
          brain: brain,
          sourceLang: 'en',
          targetLang: 'es',
          engine: 'domovoi:byokAnthropic');

      final result =
          await translator.translateBatch(['Hello.', 'Goodbye.']);

      expect(result, ['Hola.', 'Adios.']);
      expect(brain.callCount, 1);
    });

    test('an empty sentence list never calls the Brain at all', () async {
      final brain = FakeBrain([]);
      final translator = BrainTranslator(
          brain: brain, sourceLang: 'en', targetLang: 'es', engine: 'x');

      expect(await translator.translateBatch(const []), isEmpty);
      expect(brain.callCount, 0);
    });

    test('tolerates a reply wrapped in prose and code fences — the same '
        'extractJsonObject house pattern grader.dart/recap.dart use',
        () async {
      final brain = FakeBrain([
        'Sure, here you go:\n```json\n'
            '{"translations": ["Hola."]}\n```\nHope that helps!',
      ]);
      final translator = BrainTranslator(
          brain: brain, sourceLang: 'en', targetLang: 'es', engine: 'x');

      expect(await translator.translateBatch(['Hello.']), ['Hola.']);
    });

    test('the prompt names the source and target languages and numbers '
        'every sentence', () async {
      final brain = FakeBrain(['{"translations": ["Hola.", "Adios."]}']);
      final translator = BrainTranslator(
          brain: brain, sourceLang: 'en', targetLang: 'es', engine: 'x');

      await translator.translateBatch(['Hello.', 'Goodbye.']);

      final prompt = brain.prompts.single;
      expect(prompt, contains('en'));
      expect(prompt, contains('es'));
      expect(prompt, contains('1. Hello.'));
      expect(prompt, contains('2. Goodbye.'));
    });

    test('an optional glossary is folded into the prompt when non-empty, '
        'absent when not', () async {
      final brain = FakeBrain(['{"translations": ["Hola."]}']);
      final translator = BrainTranslator(
          brain: brain,
          sourceLang: 'en',
          targetLang: 'es',
          engine: 'x',
          glossary: const {'Trellis': 'Trellis'});

      await translator.translateBatch(['Hello.']);

      expect(brain.prompts.single, contains('Trellis'));
    });
  });

  group('per-sentence fail-closed', () {
    test('a non-string entry in the array becomes null for THAT sentence '
        'only — the rest of the batch still resolves', () async {
      final brain = FakeBrain([
        '{"translations": ["Hola.", null, "Buenos dias."]}',
      ]);
      final translator = BrainTranslator(
          brain: brain, sourceLang: 'en', targetLang: 'es', engine: 'x');

      final result = await translator
          .translateBatch(['Hello.', 'Skip me.', 'Good morning.']);

      expect(result, ['Hola.', null, 'Buenos dias.']);
    });

    test('a blank string entry also becomes null — an empty translation '
        'is not a real one', () async {
      final brain = FakeBrain(['{"translations": ["Hola.", "   "]}']);
      final translator = BrainTranslator(
          brain: brain, sourceLang: 'en', targetLang: 'es', engine: 'x');

      final result =
          await translator.translateBatch(['Hello.', 'Blank one.']);

      expect(result, ['Hola.', null]);
    });

    test('a short array (the model returned fewer entries than asked) is '
        'returned as-is — the caller (TranslationJobController) already '
        'treats a missing index as null, no padding needed here',
        () async {
      final brain = FakeBrain(['{"translations": ["Hola."]}']);
      final translator = BrainTranslator(
          brain: brain, sourceLang: 'en', targetLang: 'es', engine: 'x');

      final result =
          await translator.translateBatch(['Hello.', 'Goodbye.']);

      expect(result, ['Hola.']);
    });
  });

  group('whole-chunk fail-closed — throws, never a bare crash or a '
      'silently-empty result', () {
    test('prose with no JSON object at all throws '
        'BrainTranslationFailedException', () async {
      final brain = FakeBrain(["I'm sorry, I can't help with that."]);
      final translator = BrainTranslator(
          brain: brain, sourceLang: 'en', targetLang: 'es', engine: 'x');

      await expectLater(
          translator.translateBatch(['Hello.']),
          throwsA(isA<BrainTranslationFailedException>()));
    });

    test('a JSON object missing the translations array throws', () async {
      final brain = FakeBrain(['{"note": "forgot the field"}']);
      final translator = BrainTranslator(
          brain: brain, sourceLang: 'en', targetLang: 'es', engine: 'x');

      await expectLater(
          translator.translateBatch(['Hello.']),
          throwsA(isA<BrainTranslationFailedException>()));
    });

    test('translations present but not a list throws', () async {
      final brain = FakeBrain(['{"translations": "Hola."}']);
      final translator = BrainTranslator(
          brain: brain, sourceLang: 'en', targetLang: 'es', engine: 'x');

      await expectLater(
          translator.translateBatch(['Hello.']),
          throwsA(isA<BrainTranslationFailedException>()));
    });

    test("the Brain's own AskException propagates untouched — the "
        'controller\'s batch catch-all handles it the same as any other '
        'thrown exception, but this class does not swallow or rewrap it',
        () async {
      final brain = FakeBrain([AskException('egress consent not given')]);
      final translator = BrainTranslator(
          brain: brain, sourceLang: 'en', targetLang: 'es', engine: 'x');

      await expectLater(
          translator.translateBatch(['Hello.']), throwsA(isA<AskException>()));
    });
  });
}
