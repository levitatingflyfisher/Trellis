import 'package:brain_wiring/brain_wiring.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  group('readCourseDiscourse (lenient — imported courses)', () {
    test('reads 1-2 typed items per node', () {
      final discourse = readCourseDiscourse(validCourseJson());
      expect(discourse.keys, containsAll(['n1', 'n2']));
      expect(discourse['n1'], hasLength(2));
      expect(discourse['n1']![0].kind, DiscourseKind.socratic);
      expect(discourse['n1']![0].prompt, contains('break'));
      expect(discourse['n1']![1].kind, DiscourseKind.explainBack);
      expect(discourse['n2'], hasLength(1));
    });

    test('a course with no discourse at all reads as empty, not an error',
        () {
      final json = validCourseJson();
      for (final node in json['nodes'] as List) {
        (node as Map<String, dynamic>).remove('discourse');
      }
      expect(readCourseDiscourse(json), isEmpty);
    });

    test('present-but-malformed discourse throws path-qualified', () {
      final json = validCourseJson();
      ((json['nodes'] as List).first as Map<String, dynamic>)['discourse'] = [
        {'kind': 'socratic'}, // no prompt
      ];
      expect(
        () => readCourseDiscourse(json),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          allOf(contains("'n1'"), contains('prompt')),
        )),
      );
    });
  });

  group('validateDistilledDiscourse (strict — the distiller invariant)', () {
    test('accepts the valid fixture (both 2-item and 1-item nodes)', () {
      expect(() => validateDistilledDiscourse(validCourseJson()),
          returnsNormally);
    });

    Map<String, dynamic> withN1Discourse(Object? discourse) {
      final json = validCourseJson();
      final n1 = (json['nodes'] as List).first as Map<String, dynamic>;
      if (discourse == null) {
        n1.remove('discourse');
      } else {
        n1['discourse'] = discourse;
      }
      return json;
    }

    void expectRejects(Object? discourse, Pattern messagePart) {
      expect(
        () => validateDistilledDiscourse(withN1Discourse(discourse)),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          allOf(contains("'n1'"), contains(messagePart)),
        )),
      );
    }

    test('a node without discourse is rejected, naming the node', () {
      expectRejects(null, 'discourse');
    });

    test('an empty discourse list is rejected', () {
      expectRejects(<Object>[], '1-2');
    });

    test('three discourse items are rejected — 1-2 is the law', () {
      expectRejects([
        {'kind': 'socratic', 'prompt': 'a?'},
        {'kind': 'explain_back', 'prompt': 'b'},
        {'kind': 'socratic', 'prompt': 'c?'},
      ], '1-2');
    });

    test('an unknown kind is rejected, listing the legal kinds', () {
      expectRejects([
        {'kind': 'quiz', 'prompt': 'a?'},
      ], 'explain_back');
    });

    test('an empty prompt is rejected', () {
      expectRejects([
        {'kind': 'socratic', 'prompt': '   '},
      ], 'prompt');
    });

    test('a repeated kind is rejected — the pair is Socratic + explain-back',
        () {
      expectRejects([
        {'kind': 'socratic', 'prompt': 'a?'},
        {'kind': 'socratic', 'prompt': 'b?'},
      ], 'repeats');
    });

    test('a non-map discourse entry is rejected', () {
      expectRejects(['just a string'], 'object');
    });
  });
}
