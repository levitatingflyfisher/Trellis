import 'package:flutter/material.dart';
import 'package:openhearth_design/openhearth_design.dart';

import '../models/format.dart' show formatClock;
import 'player_controller.dart';
import 'sleep_timer_sheet.dart';

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

  /// The study crown, Phase 2: saves a capture at the current playback
  /// position. Unlike the karaoke door, this works with or without
  /// alignments (a capture is still worth taking before a transcript
  /// exists — see [PlayerController.capture]'s backfill note), so it is
  /// gated only on the callback being wired at all.
  final VoidCallback? onCapture;

  /// Opens the captures list for the current work; the shell wires it.
  final VoidCallback? onOpenCaptures;

  /// Opens the Up Next queue view; the shell wires it. Shown whenever the
  /// bar itself is (something is always playing when the bar shows), so no
  /// gate beyond that.
  final VoidCallback? onOpenQueue;

  /// Opens the chapters drawer (Campaign 7, ADR-0013); the shell wires it.
  /// Shown only when the current work IS an audiobook — the same
  /// promise-never-dangled law [onOpenSyncedText] follows for
  /// [PlayerController.hasAlignments].
  final VoidCallback? onOpenChapters;

  const MiniPlayerBar(
      {super.key,
      required this.controller,
      this.onOpenSyncedText,
      this.onCapture,
      this.onOpenCaptures,
      this.onOpenQueue,
      this.onOpenChapters});

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
                      if (onCapture != null)
                        IconButton(
                          key: const Key('player-capture'),
                          tooltip: 'Capture this moment',
                          icon: const Icon(Icons.bookmark_add_outlined),
                          onPressed: onCapture,
                        ),
                      if (onOpenCaptures != null)
                        IconButton(
                          key: const Key('open-captures'),
                          tooltip: 'Captures',
                          // Campaign 9 Phase 1: distinct from the capture
                          // door's bookmark_add_outlined above — this one
                          // reads as a LIST, not a second "add" bookmark
                          // (user: "two bookmark symbols… unclear which is
                          // doing what").
                          icon: const Icon(Icons.collections_bookmark_outlined),
                          onPressed: onOpenCaptures,
                        ),
                      if (onOpenQueue != null)
                        IconButton(
                          key: const Key('open-queue'),
                          tooltip: 'Up Next',
                          icon: const Icon(Icons.queue_music_outlined),
                          onPressed: onOpenQueue,
                        ),
                      if (controller.isAudiobook && onOpenChapters != null)
                        IconButton(
                          key: const Key('open-chapters'),
                          tooltip: 'Chapters',
                          icon: const Icon(Icons.list_alt_outlined),
                          onPressed: onOpenChapters,
                        ),
                      IconButton(
                        key: const Key('open-sleep-timer'),
                        tooltip: 'Sleep timer',
                        icon: Icon(controller.sleepTimerMode == null
                            ? Icons.bedtime_outlined
                            : Icons.bedtime),
                        onPressed: () => showModalBottomSheet<void>(
                          context: context,
                          builder: (_) => SleepTimerSheet(controller: controller),
                        ),
                      ),
                      IconButton(
                        key: const Key('player-close'),
                        tooltip: 'Stop',
                        icon: const Icon(Icons.close),
                        onPressed: controller.stop,
                      ),
                    ],
                  ),
                  // Campaign 9 Phase 2 ("resume after restart"): a
                  // rehydrated-but-not-yet-loaded work has no live
                  // duration to show on the slider below — a full-width
                  // bar with position/(position+1) as its max would read
                  // as "basically finished" regardless of how far in this
                  // actually is. A plain sentence carries the real number
                  // honestly instead; it disappears the instant a real
                  // load starts (rehydratedPositionMs goes null).
                  if (controller.rehydratedPositionMs != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Paused at ${formatClock(controller.rehydratedPositionMs!)}',
                        key: const Key('rehydrated-position'),
                        style: theme.textTheme.bodySmall,
                      ),
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
                      OhIconButton.filled(
                        key: const Key('player-toggle'),
                        tooltip: controller.playing ? 'Pause' : 'Play',
                        // Glyph contrast (Campaign 9 Phase 0's "blank
                        // circles") is pinned by OhIconButton, not here.
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
                      Tooltip(
                        message: 'Playback speed',
                        child: TextButton(
                          key: const Key('player-speed'),
                          onPressed: controller.cycleSpeed,
                          child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(_speedLabel(controller.speed))),
                        ),
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
