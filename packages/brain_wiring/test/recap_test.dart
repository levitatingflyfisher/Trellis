import 'dart:convert';

import 'package:brain_wiring/brain_wiring.dart';
import 'package:test/test.dart';

import 'fake_brain.dart';

/// Campaign 4 Phase 4's "Catch me up?" recap — spoiler-safe by contract:
/// the caller is responsible for handing in only pre-position text (see
/// the app's own `preCursorText`, tested in isolation there); this layer's
/// own job is the Brain round-trip and the typed failure path, same shape
/// as [DiscourseGrader]/[Distiller].
void main() {
  const provenance = Provenance(
    brainTier: BrainTier.byokAnthropic,
    modelId: 'claude-sonnet-5',
  );
  const gesture = UserGesture();

  RecapGenerator generatorWith(FakeBrain brain) =>
      RecapGenerator(brain: brain, provenance: provenance);

  String reply({String recap = 'So far, the story has begun.'}) =>
      jsonEncode({'recap': recap});

  group('recap', () {
    test('returns the summary + provenance', () async {
      final brain =
          FakeBrain([reply(recap: 'Ada arrived at the lighthouse.')]);
      final result = await generatorWith(brain).recap(
        title: 'The Lighthouse',
        textSoFar: 'Ada arrived at the lighthouse at dawn.',
        userGesture: gesture,
      );

      expect(result, isA<Recap>());
      expect(result.summary, contains('lighthouse'));
      expect(result.provenance, provenance);
    });

    test('the prompt carries the title and the pre-position text, and '
        'names the no-spoiler rule', () async {
      final brain = FakeBrain([reply()]);
      await generatorWith(brain).recap(
        title: 'TITLE-MARKER',
        textSoFar: 'TEXT-SO-FAR-MARKER',
        userGesture: gesture,
      );
      final prompt = brain.prompts.single;
      expect(prompt, contains('TITLE-MARKER'));
      expect(prompt, contains('TEXT-SO-FAR-MARKER'));
      // The privacy law is enforced by the CALLER (only pre-position text
      // is ever handed in) — but the prompt itself should also tell the
      // model not to invent what it was never shown, belt and suspenders.
      expect(prompt.toLowerCase(), contains('not'));
    });

    test('a fenced reply is unwrapped', () async {
      final brain = FakeBrain(['```json\n${reply(recap: 'Fenced.')}\n```']);
      final result = await generatorWith(brain).recap(
          title: 'T', textSoFar: 'so far', userGesture: gesture);
      expect(result.summary, 'Fenced.');
    });

    test('a malformed reply fails with the typed, calm exception', () async {
      final brain = FakeBrain(['no json here']);
      await expectLater(
        generatorWith(brain)
            .recap(title: 'T', textSoFar: 'so far', userGesture: gesture),
        throwsA(isA<RecapFailedException>().having(
          (e) => e.message.toLowerCase(),
          'message',
          contains('recap'),
        )),
      );
    });

    test('a reply missing the recap key fails typed instead of showing '
        'nothing', () async {
      final brain = FakeBrain([jsonEncode({'wrong': 'key'})]);
      await expectLater(
        generatorWith(brain)
            .recap(title: 'T', textSoFar: 'so far', userGesture: gesture),
        throwsA(isA<RecapFailedException>()),
      );
    });

    test('an empty recap string fails typed rather than showing a blank '
        'sheet', () async {
      final brain = FakeBrain([reply(recap: '   ')]);
      await expectLater(
        generatorWith(brain)
            .recap(title: 'T', textSoFar: 'so far', userGesture: gesture),
        throwsA(isA<RecapFailedException>()),
      );
    });

    test('an AskException from the Brain propagates untouched', () async {
      final ask = AskException('Rate limited.');
      final brain = FakeBrain([ask]);
      await expectLater(
        generatorWith(brain)
            .recap(title: 'T', textSoFar: 'so far', userGesture: gesture),
        throwsA(same(ask)),
      );
    });
  });
}
