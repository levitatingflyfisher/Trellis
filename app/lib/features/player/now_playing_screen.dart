/// The big player (owner, 14 Nov 2026: "the little horizontal card that
/// shows what is playing needs to become a big screen when I click it, so
/// I can drag the play bar; it's too tiny a target right now").
///
/// A tap on the bar opens it; the down arrow, a swipe down or Back closes
/// it. The scrub bar runs nearly the screen's width with a thumb-sized
/// grip, and, as on the bar, nothing seeks until the finger lifts. The
/// rarer doors (the episode, Page, chapters, captures, the Queue, the
/// show) close it first, so what they open is not hidden under it.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:openhearth_design/openhearth_design.dart';

import '../../db/database.dart' show Work;
import '../models/format.dart' show formatClock;
import '../reader/translation/language_names.dart';
import '../shared/capped_body.dart';
import 'language_switch.dart';
import 'player_controller.dart';
import 'sleep_timer_sheet.dart';
import 'speed_control.dart';

/// Opens the big player over everything, from [context]'s Navigator. The
/// callbacks are the bar's; each runs after the big player has closed.
Future<void> openNowPlaying(
  BuildContext context, {
  required PlayerController controller,
  VoidCallback? onOpenWork,
  VoidCallback? onOpenShow,
  VoidCallback? onOpenSyncedText,
  VoidCallback? onCapture,
  VoidCallback? onOpenCaptures,
  VoidCallback? onOpenQueue,
  VoidCallback? onOpenChapters,
  File Function(int workId, String url)? audioFileFor,
}) =>
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: NowPlayingScreen.routeName),
      fullscreenDialog: true,
      builder: (_) => NowPlayingScreen(
        controller: controller,
        onOpenWork: onOpenWork,
        onOpenShow: onOpenShow,
        onOpenSyncedText: onOpenSyncedText,
        onCapture: onCapture,
        onOpenCaptures: onOpenCaptures,
        onOpenQueue: onOpenQueue,
        onOpenChapters: onOpenChapters,
        audioFileFor: audioFileFor,
      ),
    ));

class NowPlayingScreen extends StatefulWidget {
  /// The route's name, by which the host knows to hide its bar.
  static const routeName = 'now-playing';

  final PlayerController controller;
  final VoidCallback? onOpenWork;
  final VoidCallback? onOpenShow;
  final VoidCallback? onOpenSyncedText;
  final VoidCallback? onCapture;
  final VoidCallback? onOpenCaptures;
  final VoidCallback? onOpenQueue;
  final VoidCallback? onOpenChapters;

  /// Where a made language's audio is on the phone; without it (the web)
  /// only the playing language shows.
  final File Function(int workId, String url)? audioFileFor;

  const NowPlayingScreen({
    super.key,
    required this.controller,
    this.onOpenWork,
    this.onOpenShow,
    this.onOpenSyncedText,
    this.onCapture,
    this.onOpenCaptures,
    this.onOpenQueue,
    this.onOpenChapters,
    this.audioFileFor,
  });

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen> {
  PlayerController get controller => widget.controller;

  /// Where the finger holds the scrub bar, in ms; null when not held.
  double? _scrubMs;
  int? _scrubWorkId;

  /// The length the scrub bar maps onto; null when nothing is loaded to
  /// seek (a work restored at launch, not yet played).
  int? get _totalMs {
    if (controller.rehydratedPositionMs != null) return null;
    final total = controller.duration?.inMilliseconds;
    return total == null || total <= 0 ? null : total;
  }

  int get _positionMs =>
      controller.rehydratedPositionMs ?? controller.position.inMilliseconds;

  int? get _shownTotalMs => controller.rehydratedPositionMs != null
      ? controller.rehydratedDurationMs
      : _totalMs;

  /// Closes the big player, then opens [door].
  void _thenOpen(VoidCallback? door) {
    Navigator.of(context).pop();
    if (door != null) scheduleMicrotask(door);
  }

  /// The playing episode's languages that can play now: the episode and
  /// each version whose audio is on the phone (1.6.18).
  List<EpisodeLanguage> _languages = const [];
  int? _languagesOf;

  Future<void> _loadLanguages() async {
    final work = controller.current;
    if (work == null || work.id == _languagesOf) return;
    _languagesOf = work.id;
    final fileFor = widget.audioFileFor;
    final all = await episodeLanguages(controller.db, work);
    final here = [
      for (final l in all)
        if (l.work.kind != 'version' ||
            l.work.id == work.id ||
            (fileFor != null &&
                l.work.sourceUrl != null &&
                fileFor(l.work.id, l.work.sourceUrl!).existsSync()))
          l,
    ];
    if (mounted && controller.current?.id == work.id) {
      setState(() => _languages = here);
    }
  }

  /// Plays [to] from the paragraph playing now.
  Future<void> _switchTo(Work to) async {
    final from = controller.current;
    if (from == null || from.id == to.id) return;
    final at = controller.position.inMilliseconds;
    final placed = await placeIn(controller.db, from: from, at: at, to: to);
    await controller.playWork(to,
        startAt: Duration(milliseconds: placed ?? 0));
  }

  @override
  void initState() {
    super.initState();
    controller.addListener(_changed);
    unawaited(_loadLanguages());
  }

  @override
  void dispose() {
    controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    // Nothing playing any more (X elsewhere, the queue ran out): go back.
    if (controller.current == null && mounted) {
      Navigator.of(context).maybePop();
      return;
    }
    unawaited(_loadLanguages());
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final work = controller.current;
    final theme = Theme.of(context);
    if (work == null) return const SizedBox.shrink(key: Key('now-playing'));
    final total = _totalMs;
    final shownTotal = _shownTotalMs;
    final held = total == null ? null : _scrubMs;
    final at = held?.round() ?? _positionMs;
    return Scaffold(
      key: const Key('now-playing'),
      appBar: AppBar(
        leading: IconButton(
          key: const Key('now-playing-down'),
          tooltip: 'Back',
          icon: const Icon(Icons.keyboard_arrow_down),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Now playing'),
      ),
      body: CappedBody(
        child: SafeArea(
        child: GestureDetector(
          // A swipe down closes it, as it opened from the bar below.
          onVerticalDragEnd: (d) {
            if ((d.primaryVelocity ?? 0) > 300) Navigator.of(context).pop();
          },
          // The art takes what room is left and gives way first, so the
          // scrub bar and Play are on screen on any phone. Only when the
          // rest alone does not fit (a small phone at large text) does the
          // page scroll, without the art.
          child: LayoutBuilder(builder: (context, box) {
            final scale = MediaQuery.textScalerOf(context).scale(1);
            final restNeeds = 200 + 260 * scale;
            final rest = <Widget>[
              const SizedBox(height: 16),
              Text(work.title,
                  key: const Key('now-playing-title'),
                  style: theme.textTheme.titleLarge,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
              if (widget.onOpenWork != null)
                TextButton(
                  key: const Key('now-playing-open-work'),
                  onPressed: () => _thenOpen(widget.onOpenWork),
                  child: const Text('Open the episode'),
                ),
              const SizedBox(height: 8),
              _scrubBar(theme, total: total, at: at, shownTotal: shownTotal),
              _times(theme, at: at, total: shownTotal),
              const SizedBox(height: 8),
              if (_languages.length > 1) _languageRow(work),
              _controls(),
              const SizedBox(height: 16),
              _doors(),
            ];
            const pad = EdgeInsets.fromLTRB(16, 8, 16, 16);
            if (box.maxHeight < restNeeds + 64) {
              return SingleChildScrollView(
                padding: pad,
                child: Column(children: rest),
              );
            }
            return Padding(
              padding: pad,
              child: Column(children: [
                Expanded(
                  child: LayoutBuilder(builder: (context, art) {
                    final side = art.maxWidth < art.maxHeight
                        ? art.maxWidth
                        : art.maxHeight;
                    if (side < 64) return const SizedBox.shrink();
                    return Center(
                      child: _BigArt(
                        file: controller.currentArtwork,
                        kind: work.kind,
                        size: side > 320 ? 320 : side,
                      ),
                    );
                  }),
                ),
                ...rest,
              ]),
            );
          }),
        ),
        ),
      ),
    );
  }

  Widget _scrubBar(ThemeData theme,
      {required int? total, required int at, required int? shownTotal}) {
    final max = (shownTotal ?? 1).toDouble();
    return SizedBox(
      key: const Key('now-playing-scrub'),
      height: 56,
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 8,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 12),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 28),
        ),
        child: Slider(
          value: at.clamp(0, max).toDouble(),
          max: max,
          semanticFormatterCallback: (v) =>
              '${formatClock(v.round())} of ${formatClock(max.round())}',
          onChangeStart: total == null
              ? null
              : (v) => setState(() {
                    _scrubWorkId = controller.current?.id;
                    _scrubMs = v;
                  }),
          onChanged: total == null ? null : (v) => setState(() => _scrubMs = v),
          onChangeEnd: total == null
              ? null
              : (v) {
                  final same = _scrubWorkId == controller.current?.id;
                  setState(() => _scrubMs = null);
                  if (same) {
                    controller.seekTo(Duration(milliseconds: v.round()));
                  }
                },
        ),
      ),
    );
  }

  Widget _times(ThemeData theme, {required int at, required int? total}) {
    final style = theme.textTheme.bodyMedium
        ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(formatClock(at), key: const Key('now-playing-elapsed'), style: style),
          if (total != null)
            Text('-${formatClock((total - at).clamp(0, total))}',
                key: const Key('now-playing-left'), style: style),
        ],
      ),
    );
  }

  Widget _controls() => Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            key: const Key('now-playing-back15'),
            tooltip: 'Back 15 seconds',
            iconSize: 36,
            icon: const Icon(Icons.replay),
            onPressed: () => controller.seekBy(const Duration(seconds: -15)),
          ),
          SizedBox(
            width: 80,
            height: 80,
            child: OhIconButton.filled(
              key: const Key('now-playing-toggle'),
              tooltip: controller.playing ? 'Pause' : 'Play',
              iconSize: 44,
              icon: Icon(controller.playing ? Icons.pause : Icons.play_arrow),
              onPressed: controller.toggle,
            ),
          ),
          IconButton(
            key: const Key('now-playing-fwd30'),
            tooltip: 'Forward 30 seconds',
            iconSize: 36,
            icon: const Icon(Icons.forward_30),
            onPressed: () => controller.seekBy(const Duration(seconds: 30)),
          ),
        ],
      );

  /// One chip a language; the playing one is selected.
  Widget _languageRow(Work playing) => Padding(
        key: const Key('now-playing-languages'),
        padding: const EdgeInsets.only(bottom: 4),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          children: [
            for (final l in _languages)
              ChoiceChip(
                key: Key('now-playing-lang-${l.lang}'),
                label: Text(l.work.kind == 'version'
                    ? languageDisplayName(l.lang)
                    : 'Original'),
                selected: l.work.id == playing.id,
                onSelected: (_) => _switchTo(l.work),
              ),
          ],
        ),
      );

  /// Speed, the sleep timer and the doors elsewhere, each one labelled.
  Widget _doors() {
    Widget door(String key, IconData icon, String label, VoidCallback onTap) =>
        TextButton.icon(
          key: Key(key),
          onPressed: onTap,
          icon: Icon(icon),
          label: Text(label),
        );
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: [
        SpeedControl(
          key: const Key('now-playing-speed'),
          speed: controller.speed,
          onChanged: controller.setSpeed,
        ),
        door(
          'now-playing-sleep',
          controller.sleepTimerMode == null
              ? Icons.bedtime_outlined
              : Icons.bedtime,
          controller.sleepTimerMode == null ? 'Sleep timer' : 'Sleep timer (on)',
          () => showModalBottomSheet<void>(
            context: context,
            builder: (_) => SleepTimerSheet(controller: controller),
          ),
        ),
        if (controller.hasAlignments && widget.onOpenSyncedText != null)
          door('now-playing-page', Icons.article_outlined, 'Page',
              () => _thenOpen(widget.onOpenSyncedText)),
        if (controller.isAudiobook && widget.onOpenChapters != null)
          door('now-playing-chapters', Icons.list_alt_outlined, 'Chapters',
              () => _thenOpen(widget.onOpenChapters)),
        if (widget.onCapture != null)
          door('now-playing-capture', Icons.bookmark_add_outlined,
              'Capture this moment', () => widget.onCapture!()),
        if (widget.onOpenCaptures != null)
          door('now-playing-captures', Icons.collections_bookmark_outlined,
              'Captures', () => _thenOpen(widget.onOpenCaptures)),
        if (widget.onOpenQueue != null)
          door('now-playing-queue', Icons.queue_music_outlined, 'Queue',
              () => _thenOpen(widget.onOpenQueue)),
        if (widget.onOpenShow != null && controller.currentFeed != null)
          door('now-playing-show', Icons.podcasts, 'Go to show',
              () => _thenOpen(widget.onOpenShow)),
      ],
    );
  }
}

/// The show's art, large, or a glyph for what is playing.
class _BigArt extends StatelessWidget {
  final File? file;
  final String kind;
  final double size;

  const _BigArt({required this.file, required this.kind, required this.size});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final glyph = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Icon(
          switch (kind) {
            'episode' => Icons.podcasts,
            'audiobook' => Icons.headphones_outlined,
            _ => Icons.record_voice_over_outlined,
          },
          size: size / 3,
          color: scheme.onSurfaceVariant),
    );
    final art = file;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return KeyedSubtree(
      key: const Key('now-playing-art'),
      child: art == null
          ? glyph
          : ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.file(
                art,
                width: size,
                height: size,
                cacheWidth: (size * dpr).round(),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => glyph,
              ),
            ),
    );
  }
}
