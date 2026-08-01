import 'package:flutter/material.dart';

import 'player_controller.dart';

/// The persistent playback bar: play/pause, ±15/+30, speed cycling
/// (1.0–2.0×), a seek slider — and, when the playing work has synced text
/// (alignments), the door to the karaoke view. Compact enough for 320dp at
/// 2× text scale — the fleet's sweep pins that.
class MiniPlayerBar extends StatelessWidget {
  final PlayerController controller;

  /// Opens the synced-text (karaoke) view; the shell wires it. The button
  /// only shows when the current work HAS alignments — the promise is never
  /// dangled before it can be kept.
  final VoidCallback? onOpenSyncedText;
  const MiniPlayerBar(
      {super.key, required this.controller, this.onOpenSyncedText});

  String _speedLabel(double s) =>
      '${s.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '')}×';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final work = controller.current;
        if (work == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final durationMs = controller.duration?.inMilliseconds;
        final positionMs = controller.position.inMilliseconds
            .clamp(0, durationMs ?? controller.position.inMilliseconds);
        return Material(
          key: const Key('mini-player'),
          color: theme.colorScheme.surfaceContainerHigh,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(work.title,
                            style: theme.textTheme.titleSmall,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1),
                      ),
                      if (controller.hasAlignments &&
                          onOpenSyncedText != null)
                        IconButton(
                          key: const Key('open-karaoke'),
                          tooltip: 'Synced text',
                          icon: const Icon(Icons.subtitles_outlined),
                          onPressed: onOpenSyncedText,
                        ),
                      IconButton(
                        key: const Key('player-close'),
                        tooltip: 'Stop',
                        icon: const Icon(Icons.close),
                        onPressed: controller.stop,
                      ),
                    ],
                  ),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                        trackHeight: 2,
                        thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6)),
                    child: Slider(
                      key: const Key('player-slider'),
                      min: 0,
                      max: (durationMs ?? positionMs + 1).toDouble(),
                      value: positionMs.toDouble(),
                      onChanged: durationMs == null
                          ? null
                          : (v) => controller
                              .seekTo(Duration(milliseconds: v.round())),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        key: const Key('player-back15'),
                        tooltip: 'Back 15 seconds',
                        icon: const Icon(Icons.replay),
                        onPressed: () =>
                            controller.seekBy(const Duration(seconds: -15)),
                      ),
                      IconButton.filled(
                        key: const Key('player-toggle'),
                        tooltip: controller.playing ? 'Pause' : 'Play',
                        icon: Icon(controller.playing
                            ? Icons.pause
                            : Icons.play_arrow),
                        onPressed: controller.toggle,
                      ),
                      IconButton(
                        key: const Key('player-fwd30'),
                        tooltip: 'Forward 30 seconds',
                        icon: const Icon(Icons.forward_30),
                        onPressed: () =>
                            controller.seekBy(const Duration(seconds: 30)),
                      ),
                      TextButton(
                        key: const Key('player-speed'),
                        onPressed: controller.cycleSpeed,
                        child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(_speedLabel(controller.speed))),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
