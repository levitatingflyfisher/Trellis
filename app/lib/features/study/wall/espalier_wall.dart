import 'package:flutter/material.dart';
import 'package:openhearth_design/openhearth_design.dart';
import 'package:study_core/study_core.dart' as study;

import 'ripen.dart';
import 'wall_layout.dart';
import 'wall_painter.dart';

/// Everything the wall needs to know about one concept, derived fresh from
/// the card rows by the screen (never stored — same law as the old ladder).
class WallNodeState {
  const WallNodeState({
    required this.mastery,
    required this.due,
    required this.studyable,
  });

  final double mastery;
  final int due;

  /// Unlocked, or already started — a prerequisite lapse never buries
  /// reviews the learner already owns (unlock-is-first-exposure-only).
  final bool studyable;

  bool get mastered => mastery >= 1.0;
}

/// The Espalier Wall (proposal-2 §12): the course DAG as a trained fruit
/// tree on a warm plaster wall. Cordon branches are prerequisite depths,
/// each studyable concept a fruit ripening green → blush → terracotta with
/// mastery, locked concepts small buds further up the lattice, due chips
/// riding the fruits. Wider trees pan horizontally — the wall never
/// overflows a 320dp screen.
class EspalierWall extends StatelessWidget {
  const EspalierWall({
    super.key,
    required this.course,
    required this.states,
    required this.onStudy,
    this.geometry = const WallGeometry(),
  });

  final study.Course course;
  final Map<String, WallNodeState> states;
  final VoidCallback onStudy;
  final WallGeometry geometry;

  @override
  Widget build(BuildContext context) {
    final layout = layoutWall(course, geometry);
    final cs = Theme.of(context).colorScheme;

    final wall = Container(
      key: const Key('wall-surface'),
      width: layout.size.width,
      height: layout.size.height,
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: EspalierWallPainter(
                layout: layout,
                palette: WallPalette(
                  cordon: cs.outline,
                  trunk: cs.outline,
                  branch: cs.outlineVariant,
                ),
              ),
            ),
          ),
          for (final node in course.nodes)
            Positioned(
              left: layout.centers[node.id]!.dx - geometry.nodeSpacing / 2,
              top: layout.centers[node.id]!.dy - _fruitBoxSize / 2,
              width: geometry.nodeSpacing,
              child: _WallNode(
                key: Key('node-${node.id}'),
                node: node,
                state: states[node.id]!,
                onStudy: onStudy,
              ),
            ),
        ],
      ),
    );

    // Pans when the tree outgrows the screen; centers when it doesn't.
    return Center(
      child: SingleChildScrollView(
        key: const Key('wall-pan'),
        scrollDirection: Axis.horizontal,
        child: wall,
      ),
    );
  }
}

/// The square that holds a fruit or bud (and its due chip) — the tap
/// target, sized to the 48dp minimum.
const double _fruitBoxSize = 48;

/// One concept on the wall: fruit or bud on the cordon, title below.
class _WallNode extends StatelessWidget {
  const _WallNode({
    super.key,
    required this.node,
    required this.state,
    required this.onStudy,
  });

  final study.KnowledgeNode node;
  final WallNodeState state;
  final VoidCallback onStudy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: state.studyable ? onStudy : null,
      child: Semantics(
        button: state.studyable,
        label: node.title,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: _fruitBoxSize,
              height: _fruitBoxSize,
              child: Stack(
                children: [
                  Center(
                    child: state.studyable
                        ? WallFruit(
                            key: Key('fruit-${node.id}'),
                            mastery: state.mastery,
                            icon: state.mastered
                                ? Icons.check
                                : Icons.menu_book_outlined,
                          )
                        : WallBud(key: Key('bud-${node.id}')),
                  ),
                  if (state.studyable && state.due > 0)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: _DueChip(count: state.due),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 2),
            Text(
              node.title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: state.studyable ? cs.onSurface : cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A ripening fruit on the cordon. [mastery] drives the fill through
/// [ripenColor]; the small icon says what the fruit is for (open to study,
/// or mastered with its check).
class WallFruit extends StatelessWidget {
  const WallFruit({
    super.key,
    required this.mastery,
    required this.icon,
  });

  final double mastery;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      height: 28,
      child: CustomPaint(
        painter: FruitPainter(
          fill: ripenColor(mastery),
          rim: Theme.of(context).colorScheme.outline,
        ),
        child: Center(
          // A warm-white glyph reads on every ripeness, day and dusk.
          child: Icon(icon, size: 14, color: OhColors.linen50),
        ),
      ),
    );
  }
}

/// A locked concept further up the lattice: a small outlined bud with its
/// padlock — visible, calm, and plainly not ready.
class WallBud extends StatelessWidget {
  const WallBud({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 20,
      height: 20,
      child: CustomPaint(
        painter: BudPainter(outline: cs.outline),
        child: Center(
          child: Icon(Icons.lock_outline, size: 11, color: cs.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// The count of presentable-due cards riding a fruit.
class _DueChip extends StatelessWidget {
  const _DueChip({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$count',
        style: theme.textTheme.labelSmall
            ?.copyWith(color: cs.onPrimaryContainer),
      ),
    );
  }
}
