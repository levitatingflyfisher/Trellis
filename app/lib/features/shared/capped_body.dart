import 'package:flutter/material.dart';
import 'package:openhearth_design/openhearth_design.dart';

/// Every screen's Scaffold body: the fleet's [OhPage] width cap (a phone
/// layout is not stretched across a tablet or a desktop browser), with no
/// extra gutter (the screens keep their own padding) and the content held
/// to the full capped width, so a Column body keeps the left edge it has on
/// a phone instead of shrink-wrapping and drifting to the centre.
class CappedBody extends StatelessWidget {
  const CappedBody({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => OhPage(
        padding: EdgeInsets.zero,
        child: SizedBox(width: double.infinity, child: child),
      );
}
