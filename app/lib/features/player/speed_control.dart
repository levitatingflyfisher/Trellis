/// The one playback-speed control (1.5.5, user: "a simple number spinning
/// thing you swipe your finger up and down on"). Tap-cycling meant going
/// up through every step to come back down; a swipe goes either way, and
/// a tap opens a plain list of presets (1.5.6: a second wheel confused).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'mini_player_host.dart' show sheetContextFor;

const double minSpeed = 0.5;
const double maxSpeed = 4.0;
const List<double> speedPresets = [
  0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, //
];

/// How far a finger travels for one 0.1 step.
const double dpPerSpeedStep = 24;

/// Speeds live on a 0.05 grid: adding 0.1 in floating point drifts
/// (1.2000000000000002), and a label or an equality check would show it.
/// Twentieths, not tenths, so the 1.25 and 1.75 presets hold.
double clampSpeed(double s) =>
    (s.clamp(minSpeed, maxSpeed) * 20).round() / 20;

/// The speed a vertical drag of [dy] (screen pixels, down positive) lands
/// on from [start]: up is faster, one step per [dpPerSpeedStep].
double speedAfterDrag(double start, double dy) =>
    clampSpeed(start + (-dy ~/ dpPerSpeedStep) / 10);

/// `1×`, `1.5×`; an older per-show override like 1.25 keeps its digits.
String speedLabel(double s) {
  final fixed = s.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
  return '$fixed×';
}

class SpeedControl extends StatefulWidget {
  final double speed;
  final ValueChanged<double> onChanged;

  const SpeedControl({super.key, required this.speed, required this.onChanged});

  @override
  State<SpeedControl> createState() => _SpeedControlState();
}

class _SpeedControlState extends State<SpeedControl> {
  double _dragStart = 1.0;
  double _downY = 0;

  // Measured from where the finger went down, so the gesture's slop still
  // counts toward the first step.
  void _onDrag(DragUpdateDetails d) {
    final next = speedAfterDrag(_dragStart, d.globalPosition.dy - _downY);
    if (next != widget.speed) {
      HapticFeedback.selectionClick();
      widget.onChanged(next);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Playback speed',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragDown: (d) {
          _dragStart = widget.speed;
          _downY = d.globalPosition.dy;
        },
        onVerticalDragUpdate: _onDrag,
        child: TextButton(
          onPressed: () => showSpeedSheet(context,
              speed: widget.speed, onChanged: widget.onChanged),
          style: TextButton.styleFrom(minimumSize: const Size(56, 48)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.unfold_more, size: 16),
              FittedBox(
                  fit: BoxFit.scaleDown, child: Text(speedLabel(widget.speed))),
            ],
          ),
        ),
      ),
    );
  }
}

/// The presets, the current one checked; one tap sets it and closes.
/// The drag on the button is the fine control, so there is no wheel here.
///
/// One at a time, app-wide: the mini player sits below the Navigator
/// (`MaterialApp.builder`), so the sheet's barrier never covers its speed
/// button, and every tap there used to stack another sheet.
Future<void> showSpeedSheet(BuildContext context,
    {required double speed, required ValueChanged<double> onChanged}) {
  if (_speedSheetOpen) return Future.value();
  _speedSheetOpen = true;
  return showModalBottomSheet<void>(
    context: sheetContextFor(context),
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: ListView(
        key: const Key('speed-sheet'),
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('Playback speed',
                style: Theme.of(sheet).textTheme.titleMedium),
          ),
          for (final p in speedPresets)
            ListTile(
              key: Key('speed-preset-$p'),
              minTileHeight: 48,
              title: Text(speedLabel(p)),
              trailing: (p - speed).abs() < 0.001
                  ? const Icon(Icons.check)
                  : null,
              onTap: () {
                onChanged(p);
                Navigator.of(sheet).pop();
              },
            ),
        ],
      ),
    ),
  ).whenComplete(() => _speedSheetOpen = false);
}

bool _speedSheetOpen = false;
