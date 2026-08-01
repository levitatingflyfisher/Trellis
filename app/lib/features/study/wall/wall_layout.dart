import 'dart:math' as math;
import 'dart:ui';

import 'package:study_core/study_core.dart' as study;

/// The Espalier Wall's layout math (proposal-2 §12), pure and painter-free:
/// the course DAG becomes a trained fruit tree — one horizontal cordon per
/// prerequisite depth, fruits placed along the cordons, branch edges from
/// each prerequisite fruit up to its dependent. The painter and the widget
/// both consume these numbers verbatim; only this file decides them.

/// Fixed geometry in logical pixels. The defaults leave room below each
/// fruit for a two-line title at 2.0 text scale (the 320dp sweep law).
class WallGeometry {
  const WallGeometry({
    this.nodeSpacing = 96,
    this.cordonSpacing = 112,
    this.horizontalPadding = 28,
    this.topPadding = 36,
    this.bottomPadding = 96,
  });

  /// Center-to-center distance between fruits sharing a cordon.
  final double nodeSpacing;

  /// Vertical distance between cordons (one DAG depth apart).
  final double cordonSpacing;

  /// Wall margin left and right of the widest cordon.
  final double horizontalPadding;

  /// Wall margin above the topmost cordon (due chips need headroom).
  final double topPadding;

  /// Wall margin below the bottom cordon (titles need legroom).
  final double bottomPadding;
}

/// One horizontal cordon branch: every fruit at the same DAG depth.
class WallCordon {
  const WallCordon({required this.y, required this.left, required this.right});
  final double y;
  final double left;
  final double right;
}

/// One prerequisite branch, prereq fruit center to dependent fruit center.
class WallEdge {
  const WallEdge({
    required this.fromId,
    required this.toId,
    required this.from,
    required this.to,
  });
  final String fromId;
  final String toId;
  final Offset from;
  final Offset to;
}

/// Everything the wall needs to draw itself, computed once per build.
class WallLayout {
  const WallLayout({
    required this.size,
    required this.trunkX,
    required this.depths,
    required this.centers,
    required this.cordons,
    required this.edges,
  });

  final Size size;
  final double trunkX;

  /// Node id -> DAG depth (0 = no prerequisites = the bottom cordon).
  final Map<String, int> depths;

  /// Node id -> fruit center on its cordon.
  final Map<String, Offset> centers;

  /// Indexed by depth: `cordons[0]` is the bottom cordon.
  final List<WallCordon> cordons;

  final List<WallEdge> edges;
}

/// Depth per node: 0 with no prerequisites, else one above the deepest
/// prerequisite. Unknown ids are skipped (the parser already rejects them —
/// the wall just refuses to be the second thing that breaks) and cycles,
/// which the parser also rejects, are cut rather than recursed forever.
Map<String, int> wallDepths(study.Course course) {
  final byId = {for (final n in course.nodes) n.id: n};
  final depths = <String, int>{};
  final visiting = <String>{};

  int depthOf(String id) {
    final cached = depths[id];
    if (cached != null) return cached;
    if (!visiting.add(id)) return 0; // cycle guard: cut the back edge
    var d = 0;
    for (final p in byId[id]!.prereqs) {
      if (!byId.containsKey(p) || p == id) continue;
      d = math.max(d, depthOf(p) + 1);
    }
    visiting.remove(id);
    return depths[id] = d;
  }

  for (final n in course.nodes) {
    depthOf(n.id);
  }
  return depths;
}

/// Lays the course out on the wall. Rows keep course order left to right
/// and are centered on the trunk; depth 0 is the bottom cordon and the tree
/// grows upward from there.
WallLayout layoutWall(study.Course course,
    [WallGeometry g = const WallGeometry()]) {
  final depths = wallDepths(course);
  final maxDepth =
      depths.isEmpty ? -1 : depths.values.reduce(math.max);
  final depthCount = maxDepth + 1;

  // Group nodes per depth, preserving course order within a row.
  final rows = List.generate(depthCount, (_) => <String>[]);
  for (final n in course.nodes) {
    rows[depths[n.id]!].add(n.id);
  }

  final widestRow =
      rows.isEmpty ? 0 : rows.map((r) => r.length).reduce(math.max);
  final size = Size(
    widestRow * g.nodeSpacing + 2 * g.horizontalPadding,
    (depthCount > 0 ? (depthCount - 1) * g.cordonSpacing : 0) +
        g.topPadding +
        g.bottomPadding,
  );
  final trunkX = size.width / 2;

  double cordonY(int depth) => g.topPadding + (maxDepth - depth) * g.cordonSpacing;

  final centers = <String, Offset>{};
  final cordons = <WallCordon>[];
  for (var d = 0; d < depthCount; d++) {
    final row = rows[d];
    final y = cordonY(d);
    final rowWidth = row.length * g.nodeSpacing;
    for (var i = 0; i < row.length; i++) {
      centers[row[i]] =
          Offset(trunkX - rowWidth / 2 + (i + 0.5) * g.nodeSpacing, y);
    }
    // An empty row can only happen on a cycle-cut course; span the trunk.
    final left = row.isEmpty
        ? trunkX
        : centers[row.first]!.dx - g.nodeSpacing / 2;
    final right = row.isEmpty
        ? trunkX
        : centers[row.last]!.dx + g.nodeSpacing / 2;
    cordons.add(WallCordon(y: y, left: left, right: right));
  }

  final edges = <WallEdge>[
    for (final n in course.nodes)
      for (final p in n.prereqs)
        if (centers.containsKey(p) && p != n.id)
          WallEdge(
              fromId: p, toId: n.id, from: centers[p]!, to: centers[n.id]!),
  ];

  return WallLayout(
    size: size,
    trunkX: trunkX,
    depths: depths,
    centers: centers,
    cordons: cordons,
    edges: edges,
  );
}
