import 'package:flutter/widgets.dart';

import 'wall_layout.dart';

/// Wood-and-lattice colors, sourced from the active theme by the widget —
/// the painter never picks a color itself (theme law C1: the wall is the
/// same wall at dusk under `hearthDark`).
class WallPalette {
  const WallPalette({
    required this.cordon,
    required this.trunk,
    required this.branch,
  });
  final Color cordon;
  final Color trunk;
  final Color branch;

  @override
  bool operator ==(Object other) =>
      other is WallPalette &&
      other.cordon == cordon &&
      other.trunk == trunk &&
      other.branch == branch;

  @override
  int get hashCode => Object.hash(cordon, trunk, branch);
}

/// Paints the trained tree itself: the trunk, one horizontal cordon per
/// DAG depth, and a gently curved branch per prerequisite edge. Fruits,
/// buds, chips and titles are widgets stacked above this paint — they need
/// keys, taps and semantics, which pixels don't have.
class EspalierWallPainter extends CustomPainter {
  EspalierWallPainter({required this.layout, required this.palette});

  final WallLayout layout;
  final WallPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    if (layout.cordons.isEmpty) return;

    // Prerequisite branches first — they duck under the cordons.
    final branchPaint = Paint()
      ..color = palette.branch
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.75
      ..strokeCap = StrokeCap.round;
    for (final e in layout.edges) {
      final rise = (e.from.dy - e.to.dy) / 2;
      final path = Path()
        ..moveTo(e.from.dx, e.from.dy)
        ..cubicTo(
          e.from.dx,
          e.from.dy - rise,
          e.to.dx,
          e.to.dy + rise,
          e.to.dx,
          e.to.dy,
        );
      canvas.drawPath(path, branchPaint);
    }

    // The trunk: rooted a little below the bottom cordon, up to the top.
    final bottom = layout.cordons.first.y;
    final top = layout.cordons.last.y;
    final trunkPaint = Paint()
      ..color = palette.trunk
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(layout.trunkX, bottom + 40),
      Offset(layout.trunkX, top),
      trunkPaint,
    );

    final cordonPaint = Paint()
      ..color = palette.cordon
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    for (final c in layout.cordons) {
      canvas.drawLine(Offset(c.left, c.y), Offset(c.right, c.y), cordonPaint);
    }
  }

  @override
  bool shouldRepaint(EspalierWallPainter oldDelegate) =>
      !identical(oldDelegate.layout, layout) || oldDelegate.palette != palette;
}

/// One ripening fruit: a filled circle with a thin rim. The fill arrives
/// from [ripenColor]; the rim keeps the fruit legible on the plaster at
/// every ripeness and in both themes.
class FruitPainter extends CustomPainter {
  FruitPainter({required this.fill, required this.rim});
  final Color fill;
  final Color rim;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    canvas.drawCircle(center, r, Paint()..color = fill);
    canvas.drawCircle(
      center,
      r - 0.75,
      Paint()
        ..color = rim
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(FruitPainter oldDelegate) =>
      oldDelegate.fill != fill || oldDelegate.rim != rim;
}

/// A locked bud: outline only, deliberately smaller than any fruit — the
/// lattice above the learner is visible but plainly not ripe for picking.
class BudPainter extends CustomPainter {
  BudPainter({required this.outline});
  final Color outline;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(
      size.center(Offset.zero),
      size.shortestSide / 2 - 1,
      Paint()
        ..color = outline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(BudPainter oldDelegate) => oldDelegate.outline != outline;
}
