import 'package:flutter/material.dart';

/// The bar's largest label size: [NavigationBar] clamps its labels to this
/// whatever the phone's text size.
const barLabelMaxScale = 1.3;

/// Draws every bottom-bar label at one size (owner, board-0169: "all
/// labels full size"). That size is the phone's own text size, up to the
/// bar's cap, unless the widest label would not fit in its share of the
/// width; then all of them are drawn at the largest size at which every
/// label fits whole on one line. No label is ever drawn smaller than the
/// others, and none is broken mid-word or cut. Never icons alone (owner:
/// plain labels).
class OneSizeBarLabels extends StatelessWidget {
  final List<String> labels;
  final Widget child;
  const OneSizeBarLabels({
    super.key,
    required this.labels,
    required this.child,
  });

  /// The one text scale for [labels] sharing [width] equally.
  static double scaleFor(
    BuildContext context,
    List<String> labels,
    double width,
  ) {
    final style = Theme.of(context).textTheme.labelMedium;
    final size = style?.fontSize ?? 12;
    final phone =
        MediaQuery.textScalerOf(
          context,
        ).clamp(maxScaleFactor: barLabelMaxScale).scale(size) /
        size;
    var widest = 0.0;
    for (final label in labels) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: style),
        textDirection: Directionality.of(context),
        maxLines: 1,
      )..layout();
      if (painter.width > widest) widest = painter.width;
      painter.dispose();
    }
    if (widest == 0) return phone;
    // Half a point spare, so rounding never wraps the last letter.
    final room = width / labels.length - 0.5;
    final fits = room / widest;
    return fits < phone ? fits : phone;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(
          scaleFor(context, labels, constraints.maxWidth),
        ),
      ),
      child: child,
    ),
  );
}
