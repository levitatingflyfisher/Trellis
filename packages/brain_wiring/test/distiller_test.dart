import 'dart:convert';

import 'package:brain_wiring/brain_wiring.dart';
import 'package:study_core/study_core.dart';
import 'package:test/test.dart';

import 'fake_brain.dart';
import 'fixtures.dart';

void main() {
  const provenance = Provenance(
    brainTier: BrainTier.byokAnthropic,
    modelId: 'claude-sonnet-5',
  );
  const gesture = UserGesture();

  Distiller distillerWith(FakeBrain brain) =>
      Distiller(brain: brain, provenance: provenance);

  group('happy path', () {
    test('a clean first reply becomes a parsed, saveable course', () async {
      final brain = FakeBrain([validCourseText()]);
      final result = await distillerWith(brain).distill(
        source: 'A transcript about two ideas.',
        userGesture: gesture,
      );

      expect(result.repairRounds, 0);
      expect(result.course.id, 'kalman-mini');
      expect(result.course.nodes, hasLength(2));
      expect(result.provenance, provenance);
      expect(result.discourse['n1'], hasLength(2));
    });

    test(
        'THE invariant: the exact text handed back for saving passes '
        "study_core's strict parser", () async {
      final brain = FakeBrain([validCourseText()]);
      final result = await distillerWith(brain).distill(
        source: 'src',
        userGesture: gesture,
      );
      // parseCourseString throwing here would mean we could save a course
      // the importer will refuse — the exact half-import the design bans.
      final reparsed = parseCourseString(result.ohcourseJson);
      expect(reparsed.id, result.course.id);
    });

    test('provenance is baked into the saved JSON', () async {
      final brain = FakeBrain([validCourseText()]);
      final result = await distillerWith(brain).distill(
        source: 'src',
        userGesture: gesture,
      );
      final decoded =
          jsonDecode(result.ohcourseJson) as Map<String, dynamic>;
      expect(decoded['provenance'], {
        'brainTier': 'byokAnthropic',
        'modelId': 'claude-sonnet-5',
      });
    });

    test('a fenced ```json reply is unwrapped before parsing', () async {
      final brain = FakeBrain([
        'Here is your course:\n```json\n${validCourseText()}\n```\nEnjoy!',
      ]);
      final result = await distillerWith(brain).distill(
        source: 'src',
        userGesture: gesture,
      );
      expect(result.course.id, 'kalman-mini');
    });
  });

  group('the distiller prompt', () {
    test(
        'encodes the Matuschak properties, the discourse contract, and '
        'the source', () async {
      final brain = FakeBrain([validCourseText()]);
      await distillerWith(brain).distill(
        source: 'UNIQUE-SOURCE-MARKER transcript text',
        userGesture: gesture,
      );

      final prompt = brain.prompts.single.toLowerCase();
      for (final property in [
        'focused',
        'precise',
        'consistent',
        'tractable',
        'effortful',
      ]) {
        expect(prompt, contains(property), reason: property);
      }
      expect(prompt, contains('socratic'));
      expect(prompt, contains('explain_back'));
      expect(prompt, contains('unique-source-marker'));
      expect(prompt, contains('schemaversion'));
    });
  });

  group('repair loop', () {
    test('fail once then succeed: one repair round, error fed back',
        () async {
      // First reply has a prereq typo the strict parser rejects.
      final broken = validCourseJson();
      ((broken['nodes'] as List)[1] as Map<String, dynamic>)['prereqs'] = [
        'nope',
      ];
      final brain = FakeBrain([jsonEncode(broken), validCourseText()]);

      final result = await distillerWith(brain).distill(
        source: 'src',
        userGesture: gesture,
      );

      expect(result.repairRounds, 1);
      expect(brain.callCount, 2);
      // The repair prompt carries the parser's path-qualified error and
      // the previous attempt, so the model can actually fix it.
      final repairPrompt = brain.prompts[1];
      expect(repairPrompt, contains("unknown prereq 'nope'"));
      expect(repairPrompt, contains('"nope"'));
    });

    test('a reply that parses but skips discourse is repaired too',
        () async {
      final noDiscourse = validCourseJson();
      for (final node in noDiscourse['nodes'] as List) {
        (node as Map<String, dynamic>).remove('discourse');
      }
      final brain = FakeBrain([jsonEncode(noDiscourse), validCourseText()]);

      final result = await distillerWith(brain).distill(
        source: 'src',
        userGesture: gesture,
      );
      expect(result.repairRounds, 1);
      expect(brain.prompts[1].toLowerCase(), contains('discourse'));
    });

    test('a reply with no JSON object at all enters the repair loop',
        () async {
      final brain =
          FakeBrain(['Sorry, I cannot help with that.', validCourseText()]);
      final result = await distillerWith(brain).distill(
        source: 'src',
        userGesture: gesture,
      );
      expect(result.repairRounds, 1);
    });

    test('fail all three repairs: a visible typed failure after 4 calls',
        () async {
      final brain = FakeBrain(['bad', 'bad', 'bad', 'bad']);
      await expectLater(
        distillerWith(brain).distill(source: 'src', userGesture: gesture),
        throwsA(isA<DistillFailedException>()
            .having((e) => e.attempts, 'attempts', 4)
            .having((e) => e.lastError, 'lastError', isA<FormatException>())
            .having((e) => e.message.toLowerCase(), 'message',
                contains('course'))),
      );
      expect(brain.callCount, 4); // 1 initial + 3 repair rounds, then stop.
    });

    test('an AskException from the Brain is not swallowed or retried',
        () async {
      final ask = AskException('The stove is cold.');
      final brain = FakeBrain([ask]);
      await expectLater(
        distillerWith(brain).distill(source: 'src', userGesture: gesture),
        throwsA(same(ask)),
      );
      expect(brain.callCount, 1);
    });
  });
}
