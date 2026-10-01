/// One episode row for every list that shows episodes (ADR-0016 section 1):
/// Latest and the podcast page today, history and search later. The row
/// says what state the episode is in; the screen around it decides what
/// the row can do.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../../db/database.dart' hide Alignment;
import '../models/format.dart';

/// What a list knows about every episode at once, loaded in a few queries
/// rather than one per row.
class EpisodeListState {
  final Set<int> queued;
  final Map<int, int> progressMs;
  final Set<int> transcribed;
  const EpisodeListState(
      {this.queued = const {},
      this.progressMs = const {},
      this.transcribed = const {}});

  static const empty = EpisodeListState();

  static Future<EpisodeListState> load(AppDatabase db, int profileId) async {
    final listening = await db.feedsDao.listeningOf(profileId);
    final queue = await db.queueDao.queueOf(profileId);
    return EpisodeListState(
        queued: {for (final r in queue) r.workId},
        progressMs: listening.progressMs,
        transcribed: listening.transcribed);
  }
}

final _videoRe =
    RegExp(r'\.(mp4|m4v|mov|webm|mkv)(\?|#|$)', caseSensitive: false);

bool isVideoEnclosure(String? url) => url != null && _videoRe.hasMatch(url);

/// The facts one row shows, kept apart from the widget so the rules
/// (what counts as in progress, what counts as played) are testable.
class EpisodeRowFacts {
  final bool isNew;
  final bool played;
  final bool downloaded;
  final bool queued;
  final bool transcribed;
  final bool video;
  final bool archived;
  final int? durationMs;
  final int? progressMs;

  const EpisodeRowFacts(
      {this.isNew = false,
      this.played = false,
      this.downloaded = false,
      this.queued = false,
      this.transcribed = false,
      this.video = false,
      this.archived = false,
      this.durationMs,
      this.progressMs});

  factory EpisodeRowFacts.of(Episode e, EpisodeListState state,
          {required bool downloaded}) =>
      EpisodeRowFacts(
          isNew: e.readAtMs == null,
          played: e.finishedAtMs != null,
          downloaded: downloaded,
          queued: state.queued.contains(e.workId),
          transcribed: state.transcribed.contains(e.workId),
          video: isVideoEnclosure(e.enclosureUrl),
          archived: e.archivedAtMs != null,
          durationMs: e.durationMs,
          progressMs: state.progressMs[e.workId]);

  bool get _knowsLength => durationMs != null && durationMs! > 0;

  /// Started and not played. Played wins: a finished episode left a few
  /// seconds from its end is done, not "1 min left".
  bool get inProgress {
    final p = progressMs;
    if (played || p == null || p <= 0) return false;
    return !_knowsLength || p < durationMs!;
  }

  double? get fraction =>
      inProgress && _knowsLength ? progressMs! / durationMs! : null;

  int? get leftMs =>
      inProgress && _knowsLength ? durationMs! - progressMs! : null;
}

class EpisodeRow extends StatelessWidget {
  final Work work;
  final Episode episode;
  final EpisodeRowFacts facts;

  /// The show's name; null where every row is the same show.
  final String? showTitle;

  /// Already-downloaded artwork, or null. Never fetched here.
  final File? artwork;

  /// Extra lines under the markers (the download line), owned by the
  /// screen.
  final List<Widget> below;

  final VoidCallback? onTap;

  /// Null for a row with nothing to play (an article).
  final VoidCallback? onPlay;

  /// Opens the transcript without playing. Shown only on a transcribed
  /// row, beside Play: reading and listening are equal ways in.
  final VoidCallback? onRead;

  final PopupMenuItemBuilder<String> menuBuilder;
  final PopupMenuItemSelected<String> onMenu;

  /// Null outside selection; while selecting, whether this row is chosen.
  /// The row then shows a checkbox in place of play and the menu, and
  /// [onTap] is the screen's toggle.
  final bool? selected;

  /// Enters selection (or toggles within it); null where rows can't be
  /// selected.
  final VoidCallback? onLongPress;

  const EpisodeRow(
      {super.key,
      required this.work,
      required this.episode,
      required this.facts,
      this.showTitle,
      this.artwork,
      this.below = const [],
      this.onTap,
      this.onPlay,
      this.onRead,
      required this.menuBuilder,
      required this.onMenu,
      this.selected,
      this.onLongPress});

  int get _id => work.id;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // An archived row is already dimmed whole; fading it again for played
    // would push its text below legible.
    final fade = facts.played && !facts.archived;
    final tile = ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      // Carries the selected state to screen readers as well as the eye.
      selected: selected ?? false,
      leading: _leading(context, fade),
      title: Text(
        work.title,
        overflow: TextOverflow.ellipsis,
        maxLines: 2,
        style: fade
            ? theme.textTheme.bodyLarge
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)
            : facts.isNew
                ? theme.textTheme.bodyLarge
                    ?.copyWith(fontWeight: FontWeight.w600)
                : theme.textTheme.bodyLarge,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _meta(),
                  overflow: TextOverflow.ellipsis,
                  // Two lines, so large text still reaches the length.
                  maxLines: 2,
                ),
              ),
            ],
          ),
          if (facts.inProgress && facts.fraction != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 2),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  key: Key('progress-$_id'),
                  value: facts.fraction,
                  minHeight: 3,
                ),
              ),
            ),
          _markers(theme),
          ...below,
        ],
      ),
      trailing: selected != null
          ? Checkbox(
              key: Key('select-$_id'),
              value: selected,
              onChanged: (_) => onTap?.call(),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onRead != null && facts.transcribed)
                  IconButton(
                    key: Key('read-$_id'),
                    tooltip: 'Read transcript',
                    icon: Icon(Icons.subject,
                        color:
                            fade ? theme.colorScheme.onSurfaceVariant : null),
                    onPressed: onRead,
                  ),
                if (onPlay != null)
                  IconButton(
                    key: Key('play-$_id'),
                    tooltip: 'Play',
                    icon: Icon(Icons.play_circle_outline,
                        size: 32,
                        color:
                            fade ? theme.colorScheme.onSurfaceVariant : null),
                    onPressed: onPlay,
                  ),
                PopupMenuButton<String>(
                  key: Key('menu-$_id'),
                  tooltip: 'More',
                  onSelected: onMenu,
                  itemBuilder: menuBuilder,
                ),
              ],
            ),
    );
    if (facts.archived) {
      return Opacity(key: Key('archived-$_id'), opacity: 0.55, child: tile);
    }
    if (fade) {
      return Semantics(
        key: Key('played-$_id'),
        label: 'Played',
        child: tile,
      );
    }
    return tile;
  }

  String _meta() {
    final parts = [
      if (showTitle != null) showTitle!.isEmpty ? 'Feed' : showTitle!,
      formatDay(episode.publishedAtMs),
      if (facts.leftMs != null)
        formatTimeLeft(facts.leftMs!)
      else if (facts.durationMs != null && facts.durationMs! > 0)
        formatLength(facts.durationMs!),
    ];
    return parts.join(' · ');
  }

  Widget? _leading(BuildContext context, bool fade) {
    final art = artwork;
    if (art == null) return null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Opacity(
        // Unplayed art at full strength is what makes the list scannable.
        opacity: fade ? 0.4 : 1.0,
        child: Image.file(
          art,
          key: Key('artwork-$_id'),
          width: 48,
          height: 48,
          cacheWidth: thumbCacheWidth(context, 48),
          fit: BoxFit.cover,
          // A partial or corrupt file reads as "no thumbnail yet".
          errorBuilder: (_, _, _) => const SizedBox(width: 48, height: 48),
        ),
      ),
    );
  }

  Widget _markers(ThemeData theme) {
    final scheme = theme.colorScheme;
    final markers = <Widget>[
      if (facts.isNew)
        _Marker(
          label: 'New',
          color: scheme.primary,
          lead: Container(
            key: Key('unread-dot-$_id'),
            width: 8,
            height: 8,
            decoration:
                BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
          ),
        ),
      if (facts.downloaded)
        _Marker(
            key: Key('downloaded-$_id'),
            label: 'Downloaded',
            icon: Icons.download_done),
      if (facts.queued)
        _Marker(
            key: Key('queued-$_id'),
            label: 'In Queue',
            icon: Icons.queue_music),
      if (facts.transcribed)
        _Marker(
            key: Key('transcribed-$_id'),
            label: 'Transcript',
            icon: Icons.subject),
      if (facts.video)
        _Marker(
            key: Key('video-$_id'), label: 'Video', icon: Icons.movie_outlined),
    ];
    if (markers.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(spacing: 12, runSpacing: 2, children: markers),
    );
  }
}

/// A small word with an optional icon. Text rather than a Chip, which fixes
/// its height and clips a long label at large text.
class _Marker extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Widget? lead;
  final Color? color;
  const _Marker(
      {super.key, required this.label, this.icon, this.lead, this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = color ?? theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ?lead,
        if (icon != null) Icon(icon, size: 14, color: c),
        const SizedBox(width: 4),
        Flexible(
          child: Text(label,
              style: theme.textTheme.labelSmall?.copyWith(color: c)),
        ),
      ],
    );
  }
}

/// The pixel width to decode a [logical]-wide thumbnail at. Show art is
/// commonly 3000 px square; decoded whole for a 48 dp row, each one holds
/// ~36 MB of image cache instead of ~100 kB.
int thumbCacheWidth(BuildContext context, double logical) =>
    (logical * MediaQuery.devicePixelRatioOf(context)).ceil();
