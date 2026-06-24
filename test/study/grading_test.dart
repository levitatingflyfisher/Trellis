import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/curriculum/domain/models.dart';
import 'package:trellis/features/study/domain/grading.dart';

void main() {
  group('normalizeAnswer', () {
    test('lowercases', () {
      expect(normalizeAnswer('Predict'), 'predict');
      expect(normalizeAnswer('GAUSSIAN'), 'gaussian');
    });

    test('trims leading/trailing whitespace', () {
      expect(normalizeAnswer('  predict  '), 'predict');
      expect(normalizeAnswer('\tupdate\n'), 'update');
    });

    test('collapses internal whitespace runs to a single space', () {
      expect(normalizeAnswer('kalman   gain'), 'kalman gain');
      expect(normalizeAnswer('a\t\tb\n c'), 'a b c');
    });

    test('combines lowercase + trim + collapse', () {
      expect(normalizeAnswer('  Sigma   POINTS  '), 'sigma points');
    });

    test('empty / whitespace-only normalizes to empty', () {
      expect(normalizeAnswer(''), '');
      expect(normalizeAnswer('   \t\n '), '');
    });
  });

  group('gradeCloze', () {
    ClozeItem clozeWith(Map<String, String> answers) => ClozeItem(
          id: 'c',
          rung: 1,
          text: 'placeholder',
          answers: answers,
        );

    test('all blanks correct -> true', () {
      final item = clozeWith({'c1': 'predict', 'c2': 'update'});
      expect(gradeCloze(item, {'c1': 'predict', 'c2': 'update'}), isTrue);
    });

    test('one blank wrong -> false', () {
      final item = clozeWith({'c1': 'predict', 'c2': 'update'});
      expect(gradeCloze(item, {'c1': 'predict', 'c2': 'correct'}), isFalse);
    });

    test('case-insensitive and whitespace-insensitive -> true', () {
      final item = clozeWith({'c1': 'Kalman gain', 'c2': 'uncertainty'});
      final responses = {
        'c1': '  KALMAN   gain ',
        'c2': '\tUNCERTAINTY\n',
      };
      expect(gradeCloze(item, responses), isTrue);
    });

    test('missing response key -> false (left blank empty)', () {
      final item = clozeWith({'c1': 'state', 'c2': 'measurements'});
      // c2 is absent from the responses map.
      expect(gradeCloze(item, {'c1': 'state'}), isFalse);
    });

    test('empty-string response for a non-empty answer -> false', () {
      final item = clozeWith({'c1': 'gaussian'});
      expect(gradeCloze(item, {'c1': '   '}), isFalse);
    });

    test('a repeated cloze key matches the same expected value once', () {
      // ss-1 in the real course uses c1 twice; answers map carries c1 once.
      final item = clozeWith({'c1': 'state', 'c2': 'measurements'});
      expect(gradeCloze(item, {'c1': 'STATE', 'c2': 'Measurements'}), isTrue);
    });

    test('extra unexpected response keys are ignored', () {
      final item = clozeWith({'c1': 'predict'});
      expect(
        gradeCloze(item, {'c1': 'predict', 'c9': 'whatever'}),
        isTrue,
      );
    });

    test('an item with no blanks is vacuously correct', () {
      final item = clozeWith({});
      expect(gradeCloze(item, {}), isTrue);
      expect(gradeCloze(item, {'c1': 'noise'}), isTrue);
    });

    test('does not mutate the responses map', () {
      final item = clozeWith({'c1': 'predict'});
      final responses = {'c1': 'predict'};
      gradeCloze(item, responses);
      expect(responses, {'c1': 'predict'});
    });
  });

  group('gradeDiscrimination', () {
    DiscriminationItem disc(int correctIndex) => DiscriminationItem(
          id: 'd',
          rung: 2,
          prompt: 'Exactly one is false:',
          choices: const ['a', 'b', 'c', 'd'],
          correctIndex: correctIndex,
        );

    test('chosen index equals correct index -> true', () {
      expect(gradeDiscrimination(disc(0), 0), isTrue);
      expect(gradeDiscrimination(disc(3), 3), isTrue);
    });

    test('chosen index differs from correct index -> false', () {
      expect(gradeDiscrimination(disc(0), 1), isFalse);
      expect(gradeDiscrimination(disc(2), 0), isFalse);
    });

    test('out-of-range choice is simply not the correct index -> false', () {
      expect(gradeDiscrimination(disc(0), -1), isFalse);
      expect(gradeDiscrimination(disc(0), 99), isFalse);
    });
  });

  group('keywordCoverage', () {
    const anchors = ['regime switching', 'bank of filters', 'markov', 'mixing'];

    test('response containing 2 of 4 anchors -> 0.5', () {
      const response =
          'It uses a bank of filters mixed by a markov transition matrix.';
      // present: "bank of filters", "markov"; absent: "regime switching", "mixing".
      expect(keywordCoverage(anchors, response), closeTo(0.5, 1e-9));
    });

    test('response containing none of the anchors -> 0.0', () {
      const response = 'Something completely unrelated to the answer.';
      expect(keywordCoverage(anchors, response), 0.0);
    });

    test('response containing all anchors -> 1.0', () {
      const response =
          'Regime switching via a bank of filters mixed by a markov '
          'chain — the probability-weighted mixing of models.';
      expect(keywordCoverage(anchors, response), closeTo(1.0, 1e-9));
    });

    test('empty acceptable list -> 0.0 (no division by zero)', () {
      expect(keywordCoverage(const [], 'anything at all'), 0.0);
      expect(keywordCoverage(const [], ''), 0.0);
    });

    test('matching is case- and whitespace-insensitive', () {
      const response = '  The   KALMAN   Gain   is the optimal blend.';
      expect(keywordCoverage(const ['kalman gain'], response), closeTo(1.0, 1e-9));
    });

    test('substring matching: anchor inside a larger word counts', () {
      // "linear" is a substring of "linearization".
      expect(
        keywordCoverage(const ['linear'], 'The EKF relies on linearization.'),
        closeTo(1.0, 1e-9),
      );
    });

    test('1 of 4 anchors -> 0.25', () {
      expect(
        keywordCoverage(anchors, 'It involves a markov property only.'),
        closeTo(0.25, 1e-9),
      );
    });

    test('3 of 4 anchors -> 0.75', () {
      const response =
          'Regime switching with a bank of filters and a markov chain.';
      expect(keywordCoverage(anchors, response), closeTo(0.75, 1e-9));
    });

    test('empty response with non-empty anchors -> 0.0', () {
      expect(keywordCoverage(anchors, ''), 0.0);
    });
  });

  group('suggestGrade', () {
    test('coverage <= 0.0 -> again', () {
      expect(suggestGrade(0.0), Grade.again);
      expect(suggestGrade(-0.1), Grade.again); // defensive: below floor
    });

    test('0 < coverage < 0.5 -> hard', () {
      expect(suggestGrade(0.01), Grade.hard);
      expect(suggestGrade(0.25), Grade.hard);
      expect(suggestGrade(0.49), Grade.hard);
    });

    test('boundary: exactly 0.5 -> good (not hard)', () {
      expect(suggestGrade(0.5), Grade.good);
    });

    test('0.5 <= coverage < 0.85 -> good', () {
      expect(suggestGrade(0.5), Grade.good);
      expect(suggestGrade(0.75), Grade.good);
      expect(suggestGrade(0.84), Grade.good);
    });

    test('boundary: exactly 0.85 -> easy (not good)', () {
      expect(suggestGrade(0.85), Grade.easy);
    });

    test('coverage >= 0.85 -> easy', () {
      expect(suggestGrade(0.85), Grade.easy);
      expect(suggestGrade(0.99), Grade.easy);
      expect(suggestGrade(1.0), Grade.easy);
    });
  });

  group('integration — coverage feeding suggestGrade', () {
    const anchors = ['regime switching', 'bank of filters', 'markov', 'mixing'];

    test('a no-keyword answer suggests again', () {
      final coverage = keywordCoverage(anchors, 'no idea');
      expect(coverage, 0.0);
      expect(suggestGrade(coverage), Grade.again);
    });

    test('a half-right answer (2/4) suggests good', () {
      final coverage =
          keywordCoverage(anchors, 'a bank of filters mixed by markov');
      expect(coverage, closeTo(0.5, 1e-9));
      expect(suggestGrade(coverage), Grade.good);
    });

    test('a 1/4 answer suggests hard', () {
      final coverage = keywordCoverage(anchors, 'just the markov part');
      expect(coverage, closeTo(0.25, 1e-9));
      expect(suggestGrade(coverage), Grade.hard);
    });

    test('a fully-covered answer suggests easy', () {
      final coverage = keywordCoverage(
        anchors,
        'regime switching, a bank of filters, a markov chain, and mixing.',
      );
      expect(coverage, closeTo(1.0, 1e-9));
      expect(suggestGrade(coverage), Grade.easy);
    });
  });
}
