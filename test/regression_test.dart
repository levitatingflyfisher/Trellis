// Regression tests pinning the fixes from the code-review pass.
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/curriculum/data/curriculum_parser.dart';
import 'package:trellis/features/study/domain/grading.dart';

Map<String, dynamic> _baseCourse() => {
      'schemaVersion': '1.0',
      'id': 'c',
      'title': 'C',
      'nodes': [
        {
          'id': 'a',
          'title': 'A',
          'intake': 'x',
          'items': [
            {'id': 'a1', 'type': 'cloze', 'rung': 1, 'text': '{{c1::y}}', 'answers': {'c1': 'y'}}
          ],
        },
        {
          'id': 'b',
          'title': 'B',
          'intake': 'x',
          'prereqs': ['a'],
          'items': [
            {'id': 'b1', 'type': 'qa', 'rung': 2, 'prompt': 'p', 'answer': 'ans'}
          ],
        },
      ],
    };

void main() {
  group('parser referential integrity (review fix #2/#5)', () {
    test('a well-formed course still parses', () {
      expect(parseCourse(_baseCourse()).nodes.length, 2);
    });

    test('an unknown prereq id is rejected', () {
      final bad = _baseCourse();
      (bad['nodes'] as List)[1]['prereqs'] = ['nope'];
      expect(() => parseCourse(bad), throwsFormatException);
    });

    test('a node listing itself as a prereq is rejected', () {
      final bad = _baseCourse();
      (bad['nodes'] as List)[1]['prereqs'] = ['b'];
      expect(() => parseCourse(bad), throwsFormatException);
    });

    test('a prerequisite cycle (a -> b -> a) is rejected', () {
      final bad = _baseCourse();
      (bad['nodes'] as List)[0]['prereqs'] = ['b'];
      (bad['nodes'] as List)[1]['prereqs'] = ['a'];
      expect(
        () => parseCourse(bad),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('cycle'))),
        reason: 'immediate-prereq gating makes cycle nodes permanently locked',
      );
    });

    test('an empty cloze answers map is rejected', () {
      final bad = _baseCourse();
      (bad['nodes'] as List)[0]['items'][0]['answers'] = <String, dynamic>{};
      expect(() => parseCourse(bad), throwsFormatException);
    });
  });

  group('keywordCoverage ignores empty anchors (review fix #4)', () {
    test('an empty anchor does not inflate coverage', () {
      // Only the real anchor "x" counts; the empty one is skipped.
      expect(keywordCoverage(['', 'x'], 'x'), 1.0);
    });

    test('all-empty anchors give 0.0, not a false positive', () {
      expect(keywordCoverage([''], ''), 0.0);
      expect(keywordCoverage([''], 'anything at all'), 0.0);
    });
  });
}
