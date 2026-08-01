import 'dart:convert';

import 'package:brain_wiring/brain_wiring.dart';
import 'package:study_core/study_core.dart';
import 'package:test/test.dart';

import 'fake_brain.dart';

void main() {
  const provenance = Provenance(
    brainTier: BrainTier.byokAnthropic,
    modelId: 'claude-sonnet-5',
  );
  const gesture = UserGesture();

  DiscourseGrader graderWith(FakeBrain brain) =>
      DiscourseGrader(brain: brain, provenance: provenance);

  String reply({String critique = 'Good recall.', String grade = 'good'}) =>
      jsonEncode({'critique': critique, 'suggestedGrade': grade});

  group('gradeFreeRecall', () {
    test('returns critique + suggested grade + provenance', () async {
      final brain = FakeBrain([
        reply(critique: 'You named the floor, missed the clamp.'),
      ]);
      final grading = await graderWith(brain).gradeFreeRecall(
        rubric: 'Mentions the monotonic floor and the EF clamp.',
        answer: 'The interval never shrinks.',
        userGesture: gesture,
      );

      expect(grading, isA<SuggestedGrading>());
      expect(grading.critique, contains('clamp'));
      expect(grading.suggestedGrade, Grade.good);
      expect(grading.provenance, provenance);
    });

    test('the prompt carries the rubric, the answer, and the suggestion '
        'contract', () async {
      final brain = FakeBrain([reply()]);
      await graderWith(brain).gradeFreeRecall(
        rubric: 'RUBRIC-MARKER',
        answer: 'ANSWER-MARKER',
        userGesture: gesture,
      );
      final prompt = brain.prompts.single;
      expect(prompt, contains('RUBRIC-MARKER'));
      expect(prompt, contains('ANSWER-MARKER'));
      // Suggestion-only by contract: the prompt itself says so, so even a
      // sycophantic model knows the learner keeps the final say.
      expect(prompt.toLowerCase(), contains('suggest'));
    });

    test('every Grade parses, case-insensitively', () async {
      for (final (wire, expected) in [
        ('again', Grade.again),
        ('Hard', Grade.hard),
        ('good', Grade.good),
        ('EASY', Grade.easy),
      ]) {
        final brain = FakeBrain([reply(grade: wire)]);
        final grading = await graderWith(brain).gradeFreeRecall(
          rubric: 'r',
          answer: 'a',
          userGesture: gesture,
        );
        expect(grading.suggestedGrade, expected, reason: wire);
      }
    });

    test('a fenced reply is unwrapped', () async {
      final brain = FakeBrain(['```json\n${reply(grade: 'hard')}\n```']);
      final grading = await graderWith(brain).gradeFreeRecall(
        rubric: 'r',
        answer: 'a',
        userGesture: gesture,
      );
      expect(grading.suggestedGrade, Grade.hard);
    });

    test('a malformed reply fails with the typed, calm exception', () async {
      final brain = FakeBrain(['no json here']);
      await expectLater(
        graderWith(brain)
            .gradeFreeRecall(rubric: 'r', answer: 'a', userGesture: gesture),
        throwsA(isA<GradeSuggestionFailedException>().having(
          (e) => e.message.toLowerCase(),
          'message',
          contains('critique'),
        )),
      );
    });

    test('an unknown grade word fails typed instead of guessing', () async {
      final brain = FakeBrain([reply(grade: 'superb')]);
      await expectLater(
        graderWith(brain)
            .gradeFreeRecall(rubric: 'r', answer: 'a', userGesture: gesture),
        throwsA(isA<GradeSuggestionFailedException>()),
      );
    });

    test('an AskException from the Brain propagates untouched', () async {
      final ask = AskException('Rate limited.');
      final brain = FakeBrain([ask]);
      await expectLater(
        graderWith(brain)
            .gradeFreeRecall(rubric: 'r', answer: 'a', userGesture: gesture),
        throwsA(same(ask)),
      );
    });
  });
}
