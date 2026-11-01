import 'dart:io';

import 'package:flutter/material.dart';
import 'package:openhearth_design/openhearth_design.dart';

import '../models/format.dart' show formatClock;
import '../../db/database.dart' show Work;
import 'player_controller.dart';
import 'mini_player_host.dart' show sheetContextFor;
import 'sleep_timer_sheet.dart';
import 'speed_control.dart';
import '../works/work_row.dart' show thumbCacheWidth;

/// The persistent playback bar, one slim row (1.5.9, user: "the bar is
/// too thick"): the show's art and the title, which open the episode, then
/// Back 15, play/pause, the swipe speed control (0.5–4×) and X. A 3 px
/// line along the top edge shows how far in; dragging sideways along the
/// title row scrubs it. Everything rarer (the show, Page, captures,
/// chapters, the Queue, Forward 30, the sleep timer) is in the ⋮ menu.
/// Compact enough for 320dp at 2× text scale; the fleet's sweep pins that.
class MiniPlayerBar extends StatefulWidget {
  final PlayerController controller;

  /// Opens the playing work's page (the episode); the shell wires it,
  /// inside the tab in view.
  final VoidCallback? onOpenWork;

  /// Opens the playing episode's show; the menu offers it only while the
  /// current work has a feed.
  final VoidCallback? onOpenShow;

  /// Opens the playing work's text on Page; the shell wires it. Offered
  /// only when the current work HAS alignments: the promise is never
  /// dangled before it can be kept.
  final VoidCallback? onOpenSyncedText;

  /// The study crown, Phase 2: saves a capture at the current playback
  /// position. Unlike the Page door, this works with or without
  /// alignments (a capture is still worth taking before a transcript
  /// exists; see [PlayerController.capture]'s backfill note), so it is
  /// gated only on the callback being wired at all.
  final VoidCallback? onCapture;

  /// Opens the captures list for the current work; the shell wires it.
  final VoidCallback? onOpenCaptures;

  /// Shows the Queue; the shell switches to its tab.
  final VoidCallback? onOpenQueue;

  /// Opens the chapters drawer (Campaign 7, ADR-0013); the shell wires it.
  /// Offered only when the current work IS an audiobook, the same
  /// promise-never-dangled law [onOpenSyncedText] follows.
  final VoidCallback? onOpenChapters;

  /// Opens the Headphone buttons sheet (1.6.0); the shell wires it. Null
  /// where there is no media session for a headset to drive.
  final VoidCallback? onOpenHeadsetKeys;

  const MiniPlayerBar(
      {super.key,
      required this.controller,
      this.onOpenWork,
      this.onOpenShow,
      this.onOpenSyncedText,
      this.onCapture,
      this.onOpenCaptures,
      this.onOpenQueue,
      this.onOpenChapters,
      this.onOpenHeadsetKeys});

  @override
  State<MiniPlayerBar> createState() => _MiniPlayerBarState();
}

class _MiniPlayerBarState extends State<MiniPlayerBar> {
  PlayerController get controller => widget.controller;

  /// Measures the progress line: the finger's x maps onto its width.
  final _lineKey = GlobalKey();

  /// Where the finger is along the line, 0–1, while scrubbing; null
  /// otherwise. Nothing seeks until the finger lifts.
  double? _scrub;
  int? _scrubWorkId;

  /// A drag the platform cancelled (a call coming in, a system gesture)
  /// still reaches the recognizer's end; this tells the two apart, so a
  /// cancelled scrub puts everything back instead of seeking.
  bool _pointerCancelled = false;

  /// The length a scrub maps onto: null while it isn't known, and on a
  /// bar restored at launch (nothing is loaded to seek yet).
  int? get _scrubTotalMs {
    if (controller.rehydratedPositionMs != null) return null;
    final total = controller.duration?.inMilliseconds;
    return total == null || total <= 0 ? null : total;
  }

  double _fractionAt(Offset global) {
    final box = _lineKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || box.size.width <= 0) return 0;
    return (box.globalToLocal(global).dx / box.size.width).clamp(0.0, 1.0);
  }

  void _scrubStart(DragStartDetails d) => setState(() {
        _scrubWorkId = controller.current?.id;
        _scrub = _fractionAt(d.globalPosition);
      });

  void _scrubUpdate(DragUpdateDetails d) =>
      setState(() => _scrub = _fractionAt(d.globalPosition));

  void _scrubEnd(DragEndDetails _) {
    final fraction = _scrub;
    final total = _scrubTotalMs;
    final sameWork = _scrubWorkId == controller.current?.id;
    setState(() => _scrub = null);
    if (fraction == null || total == null || !sameWork || _pointerCancelled) {
      return;
    }
    controller.seekTo(Duration(milliseconds: (fraction * total).round()));
  }

  void _scrubCancel() => setState(() => _scrub = null);

  /// How far in, 0–1. Paused after a restart there is no live player yet,
  /// so it comes from the saved position and the duration learned on the
  /// last play; an unknown duration reads as the start (the caption
  /// carries the real number).
  double _progress() {
    final restoredMs = controller.rehydratedPositionMs;
    if (restoredMs != null) {
      final total = controller.rehydratedDurationMs;
      if (total == null || total <= 0) return 0;
      return (restoredMs / total).clamp(0.0, 1.0);
    }
    final total = controller.duration?.inMilliseconds;
    if (total == null || total <= 0) return 0;
    return (controller.position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final work = controller.current;
        if (work == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final restoredMs = controller.rehydratedPositionMs;
        final total = _scrubTotalMs;
        // A scrub only shows while it can still land.
        final scrub = total == null ? null : _scrub;
        final scrubLabel = scrub == null
            ? null
            : '${formatClock((scrub * total!).round())} / '
                '${formatClock(total)}';
        return Material(
          key: const Key('mini-player'),
          color: theme.colorScheme.surfaceContainerHigh,
          // The whole bar opens the episode, not only the art and title
          // (1.6.0, user: "tapping the episode play bar doesn't open the
          // episode"). On a phone the title is cut to a few letters, and
          // the strip the bar pads above the gesture bar did nothing. The
          // buttons are inside and win their own taps; for a screen
          // reader the door is still the title's button alone.
          child: GestureDetector(
            key: const Key('player-open-work-bar'),
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTap: widget.onOpenWork,
            child: SafeArea(
              top: false,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 7, 0, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: _openWorkArea(context, work,
                              restoredMs: restoredMs,
                              scrubLabel: scrubLabel,
                              canScrub: total != null),
                        ),
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
                        SpeedControl(
                          key: const Key('player-speed'),
                          speed: controller.speed,
                          onChanged: controller.setSpeed,
                        ),
                        IconButton(
                          key: const Key('player-close'),
                          tooltip: 'Close',
                          icon: const Icon(Icons.close),
                          onPressed: controller.stop,
                        ),
                        Builder(
                          builder: (buttonContext) => IconButton(
                            key: const Key('player-menu'),
                            tooltip: 'More',
                            icon: Icon(controller.sleepTimerMode == null
                                ? Icons.more_vert
                                // The menu holds the sleep timer; its state
                                // still shows on the bar.
                                : Icons.bedtime),
                            onPressed: () => _openMenu(buttonContext),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Over the row's top padding, so thickening while
                  // scrubbing never moves the row.
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: _progressLine(theme, scrub: scrub, total: total),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// The art and title: a tap opens the episode, a sideways drag scrubs.
  Widget _openWorkArea(BuildContext context, Work work,
      {required int? restoredMs,
      required String? scrubLabel,
      required bool canScrub}) {
    final theme = Theme.of(context);
    return Listener(
      onPointerDown: (_) => _pointerCancelled = false,
      onPointerCancel: (_) => _pointerCancelled = true,
      child: GestureDetector(
        // The line carries the slider for a screen reader; scroll actions
        // here would only muddle the button.
        excludeFromSemantics: true,
        onHorizontalDragStart: canScrub ? _scrubStart : null,
        onHorizontalDragUpdate: canScrub ? _scrubUpdate : null,
        onHorizontalDragEnd: canScrub ? _scrubEnd : null,
        onHorizontalDragCancel: canScrub ? _scrubCancel : null,
        child: Semantics(
          container: true,
          button: true,
          child: InkWell(
            key: const Key('player-open-work'),
            borderRadius: BorderRadius.circular(8),
            onTap: widget.onOpenWork,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: LayoutBuilder(
                // The art is decoration: it gives way before the title
                // gets narrower than a fingertip.
                builder: (context, box) => Row(
                  children: [
                    if (box.maxWidth >= 96) ...[
                      _Art(file: controller.currentArtwork, kind: work.kind),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(scrubLabel ?? work.title,
                              key: scrubLabel == null
                                  ? null
                                  : const Key('player-scrub-readout'),
                              style: theme.textTheme.titleSmall,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1),
                          // Campaign 9 Phase 2: a restored work has no
                          // live duration, so the real number is said in
                          // words; it goes the instant a load starts.
                          if (restoredMs != null)
                            Text(
                              'Paused at ${formatClock(restoredMs)}',
                              key: const Key('rehydrated-position'),
                              style: theme.textTheme.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 3 px of progress; while scrubbing, 6 px with a thumb at the finger.
  /// For a screen reader it is the slider: +30 s and −15 s, like the
  /// skips.
  Widget _progressLine(ThemeData theme,
      {required double? scrub, required int? total}) {
    final enabled = total != null;
    final positionMs = controller.position.inMilliseconds;
    final value = total == null
        ? null
        : '${formatClock(positionMs)} of ${formatClock(total)}';
    return Semantics(
      container: true,
      slider: true,
      enabled: enabled,
      label: 'Position',
      value: value,
      increasedValue: enabled
          ? formatClock((positionMs + 30000).clamp(0, total))
          : null,
      decreasedValue: enabled
          ? formatClock((positionMs - 15000).clamp(0, total))
          : null,
      onIncrease: enabled
          ? () => controller.seekBy(const Duration(seconds: 30))
          : null,
      onDecrease: enabled
          ? () => controller.seekBy(const Duration(seconds: -15))
          : null,
      excludeSemantics: true,
      child: SizedBox(
        key: _lineKey,
        height: 3,
        child: LayoutBuilder(
          builder: (context, box) => Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(
                  key: const Key('player-slider'),
                  value: scrub ?? _progress(),
                  minHeight: scrub == null ? 3 : 6,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
              ),
              if (scrub != null)
                Positioned(
                  key: const Key('player-scrub-thumb'),
                  top: -3,
                  left: scrub * box.maxWidth - 6,
                  width: 12,
                  height: 12,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  List<PopupMenuEntry<_BarAction>> _menuItems() {
    final onOpenShow = widget.onOpenShow;
    final onOpenSyncedText = widget.onOpenSyncedText;
    final onCapture = widget.onCapture;
    final onOpenCaptures = widget.onOpenCaptures;
    final onOpenChapters = widget.onOpenChapters;
    final onOpenQueue = widget.onOpenQueue;
    PopupMenuItem<_BarAction> item(
            _BarAction a, String key, IconData icon, String label) =>
        PopupMenuItem<_BarAction>(
          key: Key(key),
          value: a,
          child: Row(
            children: [
              Icon(icon),
              const SizedBox(width: 12),
              Flexible(child: Text(label)),
            ],
          ),
        );
    return [
      if (onOpenShow != null && controller.currentFeed != null)
        item(_BarAction.show, 'player-go-to-show', Icons.podcasts,
            'Go to show'),
      if (controller.hasAlignments && onOpenSyncedText != null)
        // The playing work's text on Page, lit as it plays (1.5.5:
        // "hard to get to").
        item(_BarAction.page, 'open-karaoke', Icons.article_outlined, 'Page'),
      if (onCapture != null)
        item(_BarAction.capture, 'player-capture',
            Icons.bookmark_add_outlined, 'Capture this moment'),
      if (onOpenCaptures != null)
        // Campaign 9 Phase 1: reads as a LIST, not a second "add"
        // bookmark (user: "two bookmark symbols… unclear which is doing
        // what").
        item(_BarAction.captures, 'open-captures',
            Icons.collections_bookmark_outlined, 'Captures'),
      if (controller.isAudiobook && onOpenChapters != null)
        item(_BarAction.chapters, 'open-chapters', Icons.list_alt_outlined,
            'Chapters'),
      if (onOpenQueue != null)
        item(_BarAction.queue, 'open-queue', Icons.queue_music_outlined,
            'Queue'),
      item(_BarAction.fwd30, 'player-fwd30', Icons.forward_30,
          'Forward 30 seconds'),
      item(
          _BarAction.sleep,
          'open-sleep-timer',
          controller.sleepTimerMode == null
              ? Icons.bedtime_outlined
              : Icons.bedtime,
          controller.sleepTimerMode == null ? 'Sleep timer' : 'Sleep timer (on)'),
      if (widget.onOpenHeadsetKeys != null)
        item(_BarAction.headsetKeys, 'open-headset-keys',
            Icons.headphones_outlined, 'Headphone buttons'),
    ];
  }

  /// The ⋮ menu, by hand rather than a PopupMenuButton: over a pushed page
  /// the bar sits above the app's Navigator, so the menu opens on that
  /// Navigator, placed under the button.
  Future<void> _openMenu(BuildContext buttonContext) async {
    final onOpenShow = widget.onOpenShow;
    final onOpenSyncedText = widget.onOpenSyncedText;
    final onCapture = widget.onCapture;
    final onOpenCaptures = widget.onOpenCaptures;
    final onOpenChapters = widget.onOpenChapters;
    final onOpenQueue = widget.onOpenQueue;
    final menuContext = sheetContextFor(buttonContext);
    final overlay = Navigator.of(menuContext).overlay!.context
        .findRenderObject()! as RenderBox;
    final button = buttonContext.findRenderObject()! as RenderBox;
    final topLeft = overlay.globalToLocal(button.localToGlobal(Offset.zero));
    final position = RelativeRect.fromRect(
        topLeft & button.size, Offset.zero & overlay.size);
    final picked = await showMenu<_BarAction>(
        context: menuContext, position: position, items: _menuItems());
    switch (picked) {
      case null:
        return;
      case _BarAction.show:
        onOpenShow?.call();
      case _BarAction.page:
        onOpenSyncedText?.call();
      case _BarAction.capture:
        onCapture?.call();
      case _BarAction.captures:
        onOpenCaptures?.call();
      case _BarAction.chapters:
        onOpenChapters?.call();
      case _BarAction.queue:
        onOpenQueue?.call();
      case _BarAction.headsetKeys:
        widget.onOpenHeadsetKeys?.call();
      case _BarAction.fwd30:
        await controller.seekBy(const Duration(seconds: 30));
      case _BarAction.sleep:
        if (!menuContext.mounted) return;
        await showModalBottomSheet<void>(
          context: menuContext,
          builder: (_) => SleepTimerSheet(controller: controller),
        );
    }
  }
}

enum _BarAction {
  show,
  page,
  capture,
  captures,
  chapters,
  queue,
  fwd30,
  sleep,
  headsetKeys,
}

/// The show's art, or, when none is on disk, a glyph for what is playing:
/// an episode, an audiobook, or a text read aloud.
class _Art extends StatelessWidget {
  final File? file;
  final String kind;

  const _Art({required this.file, required this.kind});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final glyph = Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(
          switch (kind) {
            'episode' => Icons.podcasts,
            'audiobook' => Icons.headphones_outlined,
            _ => Icons.record_voice_over_outlined,
          },
          color: scheme.onSurfaceVariant),
    );
    final art = file;
    return KeyedSubtree(
      key: const Key('player-art'),
      child: art == null
          ? glyph
          : ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.file(
                art,
                width: 40,
                height: 40,
                cacheWidth: thumbCacheWidth(context, 40),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => glyph,
              ),
            ),
    );
  }
}
