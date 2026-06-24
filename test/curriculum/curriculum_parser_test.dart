import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/curriculum/data/curriculum_parser.dart';
import 'package:trellis/features/curriculum/domain/models.dart';

/// A self-contained, minimal-but-complete course mirroring the real
/// `kalman-filters.ohcourse.json`: two nodes, a prereq edge, and all four
/// item subtypes (cloze, qa, discrimination, procedure). Built as a Dart map
/// so the tests stay hermetic (no asset loading).
Map<String, dynamic> validCourseMap() => {
      'schemaVersion': '1.0',
      'id': 'kalman-filters',
      'title': 'The Kalman Filter Family',
      'subtitle': 'From linear-Gaussian estimation to multiple-model tracking',
      'subject': 'Estimation & Control',
      'level': 'undergrad-to-frontier',
      'description': 'Zero-to-hero on recursive state estimation.',
      'provenance': {
        // Not part of the domain model; the parser must ignore it cleanly.
        'kind': 'researched',
        'sources': [
          {'title': 'Kalman (1960)', 'note': 'the original linear KF'},
        ],
      },
      'srsDefaults': {
        'algorithm': 'sm2',
        'initialEase': 2.5,
        'firstIntervalDays': 1,
      },
      'nodes': [
        {
          'id': 'state-space-and-bayes',
          'title': 'State-space models and the predict-update heartbeat',
          'summary': 'A hidden state, noisy measurements, a recursive belief.',
          'prereqs': <String>[],
          'diagramMermaid': 'flowchart LR; Pr --> Up; Up --> Pr',
          'intake': 'Before any Kalman filter, two ideas...',
          'items': [
            {
              'id': 'ss-1',
              'type': 'cloze',
              'rung': 1,
              'text':
                  'You never observe the hidden {{c1::state}}; you only see '
                      'noisy {{c2::measurements}}.',
              'answers': {'c1': 'state', 'c2': 'measurements'},
            },
            {
              'id': 'ss-3',
              'type': 'qa',
              'rung': 3,
              'prompt': 'Why carry a distribution instead of a point estimate?',
              'answer': 'Because the covariance encodes how much to trust it.',
              'acceptable': ['uncertainty', 'covariance'],
              'rubric': 'Must connect distribution to tracking uncertainty.',
            },
          ],
        },
        {
          'id': 'kf-core',
          'title': 'The linear Kalman filter',
          // summary omitted -> defaults to ''
          'prereqs': ['state-space-and-bayes'],
          // diagramMermaid omitted -> defaults to null
          'intake': 'The Kalman filter is the recursive Bayesian filter...',
          'items': [
            {
              'id': 'kf-5',
              'type': 'discrimination',
              'rung': 2,
              'prompt': 'Exactly one is FALSE:',
              'choices': [
                'The KF must store the full posterior as a histogram',
                'Predict increases uncertainty; update decreases it',
                'The KF is optimal only under linear-Gaussian assumptions',
                'The innovation is measurement minus its prediction',
              ],
              'correctIndex': 0,
              'explanation': 'A Gaussian belief is a mean + covariance.',
              'hints': ['Think about what a Gaussian needs to be stored.'],
            },
            {
              'id': 'kf-6',
              'type': 'procedure',
              'rung': 2,
              'prompt': 'Walk through one predict-update cycle.',
              'steps': [
                'Push the mean through F and grow P by Q (predict).',
                'Form the innovation z - Hx.',
                'Compute the Kalman gain K.',
                'Blend the estimate toward z by K times the innovation.',
              ],
              'rubric': 'Must name predict, innovation, gain, blend.',
              'sources': ['Welch & Bishop tutorial'],
            },
          ],
        },
      ],
    };

void main() {
  group('parseCourse — valid full course', () {
    late Course course;

    setUp(() {
      course = parseCourse(validCourseMap());
    });

    test('parses course-level identity and metadata', () {
      expect(course.id, 'kalman-filters');
      expect(course.title, 'The Kalman Filter Family');
      expect(course.subtitle,
          'From linear-Gaussian estimation to multiple-model tracking');
      expect(course.subject, 'Estimation & Control');
      expect(course.level, 'undergrad-to-frontier');
      expect(course.description, 'Zero-to-hero on recursive state estimation.');
    });

    test('parses srsDefaults', () {
      expect(course.srsDefaults.algorithm, 'sm2');
      expect(course.srsDefaults.initialEase, 2.5);
      expect(course.srsDefaults.firstIntervalDays, 1);
    });

    test('builds the full node graph with correct count and ids', () {
      expect(course.nodes, hasLength(2));
      expect(course.nodes.map((n) => n.id),
          ['state-space-and-bayes', 'kf-core']);
      expect(course.nodeById('kf-core'), isNotNull);
      expect(course.nodeById('does-not-exist'), isNull);
    });

    test('wires prereqs as DAG edges', () {
      final root = course.nodeById('state-space-and-bayes')!;
      final kfCore = course.nodeById('kf-core')!;
      expect(root.prereqs, isEmpty);
      expect(kfCore.prereqs, ['state-space-and-bayes']);
    });

    test('applies model defaults for omitted optional node fields', () {
      final kfCore = course.nodeById('kf-core')!;
      expect(kfCore.summary, ''); // omitted
      expect(kfCore.diagramMermaid, isNull); // omitted
      final root = course.nodeById('state-space-and-bayes')!;
      expect(root.diagramMermaid, 'flowchart LR; Pr --> Up; Up --> Pr');
      expect(root.intake, startsWith('Before any Kalman filter'));
    });

    test('cloze item parses to ClozeItem with answers map', () {
      final item = course.nodeById('state-space-and-bayes')!.items[0];
      expect(item, isA<ClozeItem>());
      expect(item.type, ItemType.cloze);
      final cloze = item as ClozeItem;
      expect(cloze.id, 'ss-1');
      expect(cloze.rung, 1);
      expect(cloze.text, contains('{{c1::state}}'));
      expect(cloze.answers, isA<Map<String, String>>());
      expect(cloze.answers, {'c1': 'state', 'c2': 'measurements'});
      expect(cloze.hints, isEmpty);
      expect(cloze.sources, isEmpty);
    });

    test('qa item parses to QaItem with acceptable + rubric', () {
      final item = course.nodeById('state-space-and-bayes')!.items[1];
      expect(item, isA<QaItem>());
      expect(item.type, ItemType.qa);
      final qa = item as QaItem;
      expect(qa.id, 'ss-3');
      expect(qa.rung, 3);
      expect(qa.prompt, startsWith('Why carry'));
      expect(qa.answer, contains('covariance'));
      expect(qa.acceptable, ['uncertainty', 'covariance']);
      expect(qa.rubric, 'Must connect distribution to tracking uncertainty.');
    });

    test('discrimination item parses with correctIndex + choices', () {
      final item = course.nodeById('kf-core')!.items[0];
      expect(item, isA<DiscriminationItem>());
      expect(item.type, ItemType.discrimination);
      final disc = item as DiscriminationItem;
      expect(disc.id, 'kf-5');
      expect(disc.rung, 2);
      expect(disc.choices, hasLength(4));
      expect(disc.correctIndex, 0);
      expect(disc.explanation, 'A Gaussian belief is a mean + covariance.');
      expect(disc.hints, ['Think about what a Gaussian needs to be stored.']);
    });

    test('procedure item parses with steps + rubric', () {
      final item = course.nodeById('kf-core')!.items[1];
      expect(item, isA<ProcedureItem>());
      expect(item.type, ItemType.procedure);
      final proc = item as ProcedureItem;
      expect(proc.id, 'kf-6');
      expect(proc.rung, 2);
      expect(proc.steps, hasLength(4));
      expect(proc.steps.first, startsWith('Push the mean'));
      expect(proc.rubric, 'Must name predict, innovation, gain, blend.');
      expect(proc.sources, ['Welch & Bishop tutorial']);
    });

    test('ignores unknown top-level fields like provenance', () {
      // No throw, and the course still parses (asserted by setUp succeeding).
      expect(course.nodes, isNotEmpty);
    });
  });

  group('parseCourse — optional-field tolerance + defaults', () {
    test('omitted course optionals fall back to defaults', () {
      final course = parseCourse({
        'schemaVersion': '1.0',
        'id': 'minimal',
        'title': 'Minimal',
        'nodes': [
          {
            'id': 'n1',
            'title': 'Node 1',
            'intake': 'intake text',
            'items': [
              {
                'id': 'i1',
                'type': 'qa',
                'rung': 2,
                'prompt': 'p',
                'answer': 'a',
              },
            ],
          },
        ],
      });
      expect(course.subtitle, '');
      expect(course.subject, '');
      expect(course.level, '');
      expect(course.description, '');
      // srsDefaults absent -> the const SrsDefaults() defaults.
      expect(course.srsDefaults.algorithm, 'sm2');
      expect(course.srsDefaults.initialEase, 2.5);
      expect(course.srsDefaults.firstIntervalDays, 1);

      final node = course.nodes.single;
      expect(node.summary, '');
      expect(node.prereqs, isEmpty);
      expect(node.diagramMermaid, isNull);

      final qa = node.items.single as QaItem;
      expect(qa.acceptable, isEmpty);
      expect(qa.rubric, isNull);
      expect(qa.hints, isEmpty);
      expect(qa.sources, isEmpty);
    });

    test('partial srsDefaults merges with model defaults', () {
      final course = parseCourse({
        'schemaVersion': '1.0',
        'id': 'minimal',
        'title': 'Minimal',
        'srsDefaults': {'initialEase': 2.0},
        'nodes': [
          {
            'id': 'n1',
            'title': 'Node 1',
            'intake': 'x',
            'items': [
              {'id': 'i1', 'type': 'qa', 'rung': 1, 'prompt': 'p', 'answer': 'a'},
            ],
          },
        ],
      });
      expect(course.srsDefaults.initialEase, 2.0); // overridden
      expect(course.srsDefaults.algorithm, 'sm2'); // default
      expect(course.srsDefaults.firstIntervalDays, 1); // default
    });

    test('initialEase accepts an integer-valued JSON number', () {
      final course = parseCourse({
        'schemaVersion': '1.0',
        'id': 'm',
        'title': 'M',
        'srsDefaults': {'initialEase': 3},
        'nodes': [
          {
            'id': 'n',
            'title': 'N',
            'intake': 'x',
            'items': [
              {'id': 'i', 'type': 'qa', 'rung': 1, 'prompt': 'p', 'answer': 'a'},
            ],
          },
        ],
      });
      expect(course.srsDefaults.initialEase, 3.0);
    });
  });

  group('parseCourseString', () {
    test('decodes JSON text then parses', () {
      final text = json.encode(validCourseMap());
      final course = parseCourseString(text);
      expect(course.id, 'kalman-filters');
      expect(course.nodes, hasLength(2));
    });

    test('throws FormatException on invalid JSON text', () {
      expect(
        () => parseCourseString('{not valid json'),
        throwsFormatException,
      );
    });

    test('throws FormatException when top-level JSON is not an object', () {
      expect(
        () => parseCourseString('[1, 2, 3]'),
        throwsA(isA<FormatException>().having(
          (e) => e.message, 'message', contains('must be an object'))),
      );
    });
  });

  group('parseCourse — schemaVersion validation', () {
    test('throws on wrong schemaVersion', () {
      final map = validCourseMap()..['schemaVersion'] = '2.0';
      expect(
        () => parseCourse(map),
        throwsA(isA<FormatException>().having(
          (e) => e.message, 'message', contains('unsupported schemaVersion'))),
      );
    });

    test('throws on missing schemaVersion', () {
      final map = validCourseMap()..remove('schemaVersion');
      expect(
        () => parseCourse(map),
        throwsA(isA<FormatException>().having(
          (e) => e.message, 'message', contains('schemaVersion'))),
      );
    });
  });

  group('parseCourse — missing required fields throw FormatException', () {
    test('missing course id', () {
      final map = validCourseMap()..remove('id');
      expect(
        () => parseCourse(map),
        throwsA(isA<FormatException>().having(
          (e) => e.message, 'message', contains("missing required 'id'"))),
      );
    });

    test('missing course title', () {
      final map = validCourseMap()..remove('title');
      expect(() => parseCourse(map), throwsFormatException);
    });

    test('missing nodes', () {
      final map = validCourseMap()..remove('nodes');
      expect(() => parseCourse(map), throwsFormatException);
    });

    test('empty nodes list', () {
      final map = validCourseMap()..['nodes'] = <dynamic>[];
      expect(
        () => parseCourse(map),
        throwsA(isA<FormatException>().having(
          (e) => e.message, 'message', contains('must not be empty'))),
      );
    });

    test('node missing intake', () {
      final map = validCourseMap();
      (map['nodes'] as List)[0].remove('intake');
      expect(
        () => parseCourse(map),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          allOf(contains('state-space-and-bayes'), contains('intake')))),
      );
    });

    test('node missing items', () {
      final map = validCourseMap();
      (map['nodes'] as List)[1].remove('items');
      expect(() => parseCourse(map), throwsFormatException);
    });

    test('cloze missing answers names node + item + requirement', () {
      final map = validCourseMap();
      ((map['nodes'] as List)[0]['items'] as List)[0].remove('answers');
      expect(
        () => parseCourse(map),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains("node 'state-space-and-bayes'"),
            contains("item 'ss-1'"),
            contains("cloze requires 'text' and 'answers'"),
          ))),
      );
    });

    test('cloze missing text', () {
      final map = validCourseMap();
      ((map['nodes'] as List)[0]['items'] as List)[0].remove('text');
      expect(() => parseCourse(map), throwsFormatException);
    });

    test('qa missing answer', () {
      final map = validCourseMap();
      ((map['nodes'] as List)[0]['items'] as List)[1].remove('answer');
      expect(
        () => parseCourse(map),
        throwsA(isA<FormatException>().having((e) => e.message, 'message',
            contains("qa requires 'prompt' and 'answer'"))),
      );
    });

    test('discrimination missing correctIndex', () {
      final map = validCourseMap();
      ((map['nodes'] as List)[1]['items'] as List)[0].remove('correctIndex');
      expect(
        () => parseCourse(map),
        throwsA(isA<FormatException>().having((e) => e.message, 'message',
            contains('discrimination requires'))),
      );
    });

    test('procedure missing steps', () {
      final map = validCourseMap();
      ((map['nodes'] as List)[1]['items'] as List)[1].remove('steps');
      expect(
        () => parseCourse(map),
        throwsA(isA<FormatException>().having((e) => e.message, 'message',
            contains("procedure requires 'prompt' and 'steps'"))),
      );
    });

    test('item missing rung', () {
      final map = validCourseMap();
      ((map['nodes'] as List)[0]['items'] as List)[0].remove('rung');
      expect(
        () => parseCourse(map),
        throwsA(isA<FormatException>().having(
          (e) => e.message, 'message', contains("missing required 'rung'"))),
      );
    });

    test('item missing id', () {
      final map = validCourseMap();
      ((map['nodes'] as List)[0]['items'] as List)[0].remove('id');
      expect(() => parseCourse(map), throwsFormatException);
    });
  });

  group('parseCourse — type validation', () {
    test('throws on unknown item type', () {
      final map = validCourseMap();
      ((map['nodes'] as List)[0]['items'] as List)[0]['type'] = 'flashcard';
      expect(
        () => parseCourse(map),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains("unknown item type 'flashcard'"),
            contains("item 'ss-1'"),
          ))),
      );
    });

    test('throws when item type is missing', () {
      final map = validCourseMap();
      ((map['nodes'] as List)[0]['items'] as List)[0].remove('type');
      expect(
        () => parseCourse(map),
        throwsA(isA<FormatException>().having(
          (e) => e.message, 'message', contains("missing required 'type'"))),
      );
    });

    test('throws when rung is not an integer', () {
      final map = validCourseMap();
      ((map['nodes'] as List)[0]['items'] as List)[0]['rung'] = 'high';
      expect(
        () => parseCourse(map),
        throwsA(isA<FormatException>().having(
          (e) => e.message, 'message', contains("'rung' must be an integer"))),
      );
    });

    test('throws when correctIndex is out of range', () {
      final map = validCourseMap();
      ((map['nodes'] as List)[1]['items'] as List)[0]['correctIndex'] = 99;
      expect(
        () => parseCourse(map),
        throwsA(isA<FormatException>().having(
          (e) => e.message, 'message', contains('out of range'))),
      );
    });

    test('throws when answers is not a string->string map', () {
      final map = validCourseMap();
      ((map['nodes'] as List)[0]['items'] as List)[0]['answers'] = {
        'c1': 123,
      };
      expect(
        () => parseCourse(map),
        throwsA(isA<FormatException>().having((e) => e.message, 'message',
            contains('string keys to string values'))),
      );
    });

    test('throws when prereqs is not a list of strings', () {
      final map = validCourseMap();
      (map['nodes'] as List)[1]['prereqs'] = [42];
      expect(
        () => parseCourse(map),
        throwsA(isA<FormatException>().having((e) => e.message, 'message',
            contains('list of strings'))),
      );
    });

    test('throws when nodes contains a non-object', () {
      final map = validCourseMap()
        ..['nodes'] = [
          'not-a-node',
        ];
      expect(
        () => parseCourse(map),
        throwsA(isA<FormatException>().having(
          (e) => e.message, 'message', contains('must be an object'))),
      );
    });
  });
}
