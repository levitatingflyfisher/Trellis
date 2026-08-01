import 'package:flutter_test/flutter_test.dart';
import 'package:study_core/study_core.dart' as study;
import 'package:trellis/features/study/wall/wall_layout.dart';

/// The Espalier Wall's layout math, pure (proposal-2 §12): cordon branches
/// per DAG depth, fruits placed on the cordons, prerequisite edges between
/// fruit centers. The painter consumes these numbers verbatim, so pinning
/// them here pins the wall's geometry without a pixel test.
void main() {
  study.KnowledgeNode node(String id, {List<String> prereqs = const []}) =>
      study.KnowledgeNode(
          id: id, title: id, intake: '', items: const [], prereqs: prereqs);

  study.Course courseOf(List<study.KnowledgeNode> nodes) =>
      study.Course(id: 'c', title: 'C', nodes: nodes);

  const g = WallGeometry();

  group('wallDepths', () {
    test('a linear chain climbs one cordon per prerequisite', () {
      final c = courseOf([
        node('a'),
        node('b', prereqs: ['a']),
        node('c', prereqs: ['b']),
      ]);
      expect(wallDepths(c), {'a': 0, 'b': 1, 'c': 2});
    });

    test('a diamond joins at one cordon above its deepest prerequisite', () {
      final c = courseOf([
        node('a'),
        node('b', prereqs: ['a']),
        node('c', prereqs: ['a']),
        node('d', prereqs: ['b', 'c']),
      ]);
      expect(wallDepths(c), {'a': 0, 'b': 1, 'c': 1, 'd': 2});
    });

    test('an unknown prerequisite id is ignored, never crashes the wall', () {
      // The parser rejects these, but the wall must not be the thing that
      // dies if a course object arrives another way.
      final c = courseOf([
        node('a', prereqs: ['ghost'])
      ]);
      expect(wallDepths(c), {'a': 0});
    });

    test('uneven prerequisites take the deepest path', () {
      final c = courseOf([
        node('a'),
        node('b', prereqs: ['a']),
        node('e', prereqs: ['a', 'b']),
      ]);
      expect(wallDepths(c)['e'], 2);
    });
  });

  group('layoutWall positions', () {
    test('depth zero sits on the bottom cordon; deeper is higher up', () {
      final l = layoutWall(
          courseOf([
            node('a'),
            node('b', prereqs: ['a']),
          ]),
          g);
      final a = l.centers['a']!;
      final b = l.centers['b']!;
      expect(b.dy, lessThan(a.dy), reason: 'the tree grows upward');
      expect(b.dy, a.dy - g.cordonSpacing);
    });

    test('same-depth fruits share a cordon and sit nodeSpacing apart', () {
      final l = layoutWall(
          courseOf([
            node('a'),
            node('b'),
            node('c'),
          ]),
          g);
      final ys = {for (final o in l.centers.values) o.dy};
      expect(ys, hasLength(1));
      expect(l.centers['b']!.dx - l.centers['a']!.dx, g.nodeSpacing);
      expect(l.centers['c']!.dx - l.centers['b']!.dx, g.nodeSpacing);
    });

    test('each cordon row is centered on the trunk', () {
      final l = layoutWall(
          courseOf([
            node('a'),
            node('b'),
            node('c', prereqs: ['a']),
          ]),
          g);
      // Depth 0 has two fruits: their midpoint is the trunk.
      final mid = (l.centers['a']!.dx + l.centers['b']!.dx) / 2;
      expect(mid, l.trunkX);
      // Depth 1 has one fruit: it sits on the trunk itself.
      expect(l.centers['c']!.dx, l.trunkX);
      expect(l.trunkX, l.size.width / 2);
    });

    test('the wall sizes itself to the widest cordon plus padding', () {
      final l = layoutWall(
          courseOf([
            node('a'),
            node('b'),
            node('c'),
            node('d', prereqs: ['a']),
          ]),
          g);
      expect(l.size.width, 3 * g.nodeSpacing + 2 * g.horizontalPadding);
      expect(l.size.height,
          g.topPadding + g.cordonSpacing + g.bottomPadding,
          reason: 'two cordons: one spacing between them, padding around');
    });

    test('a single fruit hangs centered on a one-cordon wall', () {
      final l = layoutWall(courseOf([node('a')]), g);
      expect(l.centers['a'],
          Offset(l.size.width / 2, l.size.height - g.bottomPadding));
      expect(l.cordons, hasLength(1));
    });

    test('an empty course is an empty wall, not a crash', () {
      final l = layoutWall(courseOf(const []), g);
      expect(l.centers, isEmpty);
      expect(l.edges, isEmpty);
      expect(l.cordons, isEmpty);
    });
  });

  group('layoutWall cordons', () {
    test('one cordon per depth, bottom cordon first', () {
      final l = layoutWall(
          courseOf([
            node('a'),
            node('b', prereqs: ['a']),
            node('c', prereqs: ['b']),
          ]),
          g);
      expect(l.cordons, hasLength(3));
      expect(l.cordons[0].y, greaterThan(l.cordons[1].y));
      expect(l.cordons[1].y, greaterThan(l.cordons[2].y));
      expect(l.cordons[0].y, l.centers['a']!.dy);
      expect(l.cordons[2].y, l.centers['c']!.dy);
    });

    test('a cordon spans its row of fruits with half a spacing overhang', () {
      final l = layoutWall(
          courseOf([
            node('a'),
            node('b'),
          ]),
          g);
      final left = l.centers['a']!.dx - g.nodeSpacing / 2;
      final right = l.centers['b']!.dx + g.nodeSpacing / 2;
      expect(l.cordons[0].left, left);
      expect(l.cordons[0].right, right);
    });
  });

  group('layoutWall edges', () {
    test('one branch per prerequisite, prereq center to dependent center', () {
      final l = layoutWall(
          courseOf([
            node('a'),
            node('b'),
            node('d', prereqs: ['a', 'b']),
          ]),
          g);
      expect(l.edges, hasLength(2));
      final fromA =
          l.edges.singleWhere((e) => e.fromId == 'a' && e.toId == 'd');
      expect(fromA.from, l.centers['a']);
      expect(fromA.to, l.centers['d']);
    });

    test('an unknown prerequisite grows no branch', () {
      final l = layoutWall(
          courseOf([
            node('a', prereqs: ['ghost'])
          ]),
          g);
      expect(l.edges, isEmpty);
    });
  });
}
