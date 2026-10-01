/// The one playback-speed control (1.5.5, user: "a simple number spinning
/// thing you swipe your finger up and down on"). Tap-cycling meant going
/// up through every step to come back down; a swipe goes either way, and
/// a tap opens the same wheel with one-tap presets.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'mini_player_host.dart' show sheetContextFor;

const double minSpeed = 0.5;
const double maxSpeed = 4.0;
const List<double> speedPresets = [1.0, 1.5, 2.0, 3.0, 4.0];

/// How far a finger travels for one 0.1 step.
const double dpPerSpeedStep = 24;

/// Speeds live in tenths: adding 0.1 in floating point drifts
/// (1.2000000000000002), and a label or an equality check would show it.
double clampSpeed(double s) =>
    (s.clamp(minSpeed, maxSpeed) * 10).round() / 10;

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

/// The wheel and the presets. `enableDrag: false` so a swipe on the wheel
/// turns it rather than dismissing the sheet.
Future<void> showSpeedSheet(BuildContext context,
    {required double speed, required ValueChanged<double> onChanged}) {
  return showModalBottomSheet<void>(
    context: sheetContextFor(context),
    enableDrag: false,
    showDragHandle: true,
    builder: (sheet) => StatefulBuilder(
      builder: (sheet, setSheet) {
        void set(double s) {
          setSheet(() => speed = s);
          onChanged(s);
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Playback speed',
                    style: Theme.of(sheet).textTheme.titleMedium),
                SizedBox(
                  height: 160,
                  child: _Wheel(speed: speed, onChanged: set),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final p in speedPresets)
                      ChoiceChip(
                        key: Key('speed-preset-$p'),
                        label: Text(speedLabel(p)),
                        selected: speed == p,
                        onSelected: (_) {
                          set(p);
                          Navigator.of(sheet).pop();
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _Wheel extends StatefulWidget {
  final double speed;
  final ValueChanged<double> onChanged;
  const _Wheel({required this.speed, required this.onChanged});

  @override
  State<_Wheel> createState() => _WheelState();
}

class _WheelState extends State<_Wheel> {
  static const _count = 36; // 0.5 to 4.0 in tenths
  late final _controller = FixedExtentScrollController(
      initialItem: ((widget.speed - minSpeed) * 10).round());

  @override
  void didUpdateWidget(_Wheel old) {
    super.didUpdateWidget(old);
    final item = ((widget.speed - minSpeed) * 10).round();
    if (item != _controller.selectedItem) {
      _controller.animateToItem(item,
          duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListWheelScrollView.useDelegate(
      key: const Key('speed-wheel'),
      controller: _controller,
      itemExtent: 44,
      physics: const FixedExtentScrollPhysics(),
      onSelectedItemChanged: (i) {
        final s = clampSpeed(minSpeed + i / 10);
        if (s == widget.speed) return;
        HapticFeedback.selectionClick();
        widget.onChanged(s);
      },
      childDelegate: ListWheelChildBuilderDelegate(
        childCount: _count,
        builder: (context, i) => Center(
          child: Text(speedLabel(clampSpeed(minSpeed + i / 10)),
              style: theme.textTheme.titleLarge),
        ),
      ),
    );
  }
}
