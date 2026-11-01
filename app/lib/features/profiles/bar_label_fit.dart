import 'package:flutter/material.dart';

/// The bar's largest label size: [NavigationBar] clamps its labels to this
/// whatever the phone's text size.
const barLabelMaxScale = 1.3;

/// Keeps one bottom-bar item's label whole on one line. Six items share a
/// phone's width, and "Subscriptions" needs more than its sixth (about
/// 104 dp at the bar's 1.3x cap, 80 at 1.0, where a 360 dp phone gives
/// each item 60). A label that fits is drawn as the bar draws it; one that
/// does not is drawn smaller, just enough to fit, rather than broken
/// mid-word or cut. Never icons alone (owner: plain labels).
class WholeBarLabel extends StatelessWidget {
  final String label;
  final Widget child;
  const WholeBarLabel({super.key, required this.label, required this.child});

  /// How much smaller than the bar's own size [label] must be drawn in
  /// [width]: 1 when it fits.
  static double fitFactor(BuildContext context, String label, double width) {
    final style = Theme.of(context).textTheme.labelMedium;
    final scaler = MediaQuery.textScalerOf(context)
        .clamp(maxScaleFactor: barLabelMaxScale);
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: Directionality.of(context),
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final needed = painter.width;
    painter.dispose();
    // Half a point spare, so rounding never wraps the last letter.
    final room = width - 0.5;
    return needed <= room ? 1 : room / needed;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final factor = fitFactor(context, label, constraints.maxWidth);
          if (factor >= 1) return child;
          final media = MediaQuery.of(context);
          final size =
              Theme.of(context).textTheme.labelMedium?.fontSize ?? 12;
          final drawn = media.textScaler
                  .clamp(maxScaleFactor: barLabelMaxScale)
                  .scale(size) /
              size;
          return MediaQuery(
            data: media.copyWith(
                textScaler: TextScaler.linear(drawn * factor)),
            child: child,
          );
        },
      );
}
