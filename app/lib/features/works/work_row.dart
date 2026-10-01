/// One row for every list of works (ADR-0016 section 1, widened to
/// every kind in 1.5.4): Latest, the podcast page, Search, History, the
/// Queue and the Library all show a podcast episode, a book, an article
/// or a pasted text the same way. The row says what state the work is
/// in; the screen around it decides what the row can do, and adds its
/// own extras through slots, never a copy of the row.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../db/database.dart' hide Alignment;
import '../models/format.dart';

/// A work as a list holds it: the episode is there when it came from a
/// feed.
typedef WorkEntry = ({Work work, Episode? episode});

/// Whether [work] is read rather than played: anything that is neither
/// an audiobook nor an episode with audio.
bool isTextWork(Work work, Episode? episode) =>
    work.kind != 'audiobook' && episode?.enclosureUrl == null;

/// What a list knows about every work at once, loaded in a few queries
/// for the whole list rather than one per row (a Latest of 20k rows must
/// cost what a Latest of 20 does).
class WorkListState {
  final Set<int> queued;

  /// Where listening reached, by work.
  final Map<int, int> progressMs;
  final Set<int> transcribed;

  /// Which segment reading reached, by work.
  final Map<int, int> readIdx;

  /// The size of each text work in the list; absent until asked for.
  final Map<int, TextSize> textSizes;

  /// Which file an audiobook reached, and how many files it has.
  final Map<int, int> fileIdx;
  final Map<int, int> fileCounts;

  /// Works whose size or file count was already asked for, found or not,
  /// so a later page never asks twice.
  final Set<int> _sized;

  const WorkListState({
    this.queued = const {},
    this.progressMs = const {},
    this.transcribed = const {},
    this.readIdx = const {},
    this.textSizes = const {},
    this.fileIdx = const {},
    this.fileCounts = const {},
  }) : _sized = const {};

  const WorkListState._({
    required this.queued,
    required this.progressMs,
    required this.transcribed,
    required this.readIdx,
    required this.textSizes,
    required this.fileIdx,
    required this.fileCounts,
    required Set<int> sized,
  }) : _sized = sized;

  static const empty = WorkListState();

  /// The list-wide facts for [profileId], plus the sizes of [entries].
  /// [carry] keeps sizes an earlier load already found, for a re-read
  /// of one row or a page; a full load passes none, so a text whose
  /// segments changed is sized afresh.
  static Future<WorkListState> load(
    AppDatabase db,
    int profileId, {
    Iterable<WorkEntry> entries = const [],
    WorkListState? carry,
  }) async {
    final listening = await db.feedsDao.listeningOf(profileId);
    final queue = await db.queueDao.queueOf(profileId);
    final positions = await db.spineDao.positionsOf(profileId);
    final books = [
      for (final e in entries)
        if (e.work.kind == 'audiobook') e.work.id,
    ];
    final base = WorkListState._(
      queued: {for (final r in queue) r.workId},
      progressMs: listening.progressMs,
      transcribed: listening.transcribed,
      readIdx: {for (final p in positions.values) p.workId: p.segmentIdx},
      textSizes: carry?.textSizes ?? const {},
      fileIdx: {for (final id in books) id: ?listening.fileIdx[id]},
      fileCounts: carry?.fileCounts ?? const {},
      sized: carry?._sized ?? const {},
    );
    return base.including(db, entries);
  }

  /// This state's list-wide facts with every size either state knows.
  /// The merge a screen does at setState time, so a page landing and a
  /// row re-read in flight together can't overwrite each other: the
  /// newer list-wide facts come from `this`, sizes are a union.
  WorkListState withSizesFrom(WorkListState other) => WorkListState._(
    queued: queued,
    progressMs: progressMs,
    transcribed: transcribed,
    readIdx: readIdx,
    textSizes: {...other.textSizes, ...textSizes},
    fileIdx: {...other.fileIdx, ...fileIdx},
    fileCounts: {...other.fileCounts, ...fileCounts},
    sized: {...other._sized, ..._sized},
  );

  /// This state with the sizes of [entries] it does not know yet: what a
  /// newly loaded page adds, in a query or two for the whole page.
  Future<WorkListState> including(
    AppDatabase db,
    Iterable<WorkEntry> entries,
  ) async {
    final texts = <int>[];
    final books = <int>[];
    for (final e in entries) {
      final id = e.work.id;
      if (_sized.contains(id)) continue;
      if (e.work.kind == 'audiobook') {
        books.add(id);
      } else if (isTextWork(e.work, e.episode)) {
        texts.add(id);
      }
    }
    if (texts.isEmpty && books.isEmpty) return this;
    final sizes = texts.isEmpty
        ? const <int, TextSize>{}
        : await db.spineDao.textSizesOf(texts);
    final counts = books.isEmpty
        ? const <int, int>{}
        : await db.audiobooksDao.fileCountsOf(books);
    return WorkListState._(
      queued: queued,
      progressMs: progressMs,
      transcribed: transcribed,
      readIdx: readIdx,
      textSizes: {...textSizes, ...sizes},
      fileIdx: fileIdx,
      fileCounts: {...fileCounts, ...counts},
      sized: {..._sized, ...texts, ...books},
    );
  }
}

final _videoRe = RegExp(
  r'\.(mp4|m4v|mov|webm|mkv)(\?|#|$)',
  caseSensitive: false,
);

bool isVideoEnclosure(String? url) => url != null && _videoRe.hasMatch(url);

/// Characters a minute of silent reading covers: about 238 words a minute
/// (Brysbaert 2019) at under six characters a word, spaces included. An
/// estimate for a row, never a promise.
const _charsPerMinute = 1350;

/// The facts one row shows, kept apart from the widget so the rules
/// (what counts as in progress, what counts as played) are testable.
class WorkRowFacts {
  final bool isNew;
  final bool played;
  final bool downloaded;
  final bool queued;
  final bool transcribed;
  final bool video;
  final bool archived;

  /// A feed item someone kept (ADR-0019): it stays in the Library.
  final bool kept;
  final bool pinned;

  /// There is something to play: an episode's audio or an audiobook.
  final bool audio;
  final int? durationMs;
  final int? progressMs;

  /// How far reading (or an audiobook's files) reached, when that is how
  /// the work measures progress; null when not started.
  final double? partFraction;

  /// The estimated time to read the whole text.
  final int? readingMs;

  const WorkRowFacts({
    this.isNew = false,
    this.played = false,
    this.downloaded = false,
    this.queued = false,
    this.transcribed = false,
    this.video = false,
    this.archived = false,
    this.kept = false,
    this.pinned = false,
    this.audio = false,
    this.durationMs,
    this.progressMs,
    this.partFraction,
    this.readingMs,
  });

  factory WorkRowFacts.of(
    Work w,
    Episode? e,
    WorkListState state, {
    bool downloaded = false,
  }) {
    final id = w.id;
    final audiobook = w.kind == 'audiobook';
    final text = isTextWork(w, e);
    double? part;
    int? readingMs;
    if (audiobook) {
      final idx = state.fileIdx[id];
      final count = state.fileCounts[id] ?? 0;
      if (idx != null && count > 0) part = (idx / count).clamp(0.0, 1.0);
    } else if (text) {
      final size = state.textSizes[id];
      final idx = state.readIdx[id];
      if (size != null && size.chars > 0) {
        readingMs = (size.chars / _charsPerMinute * 60000).round();
      }
      if (size != null && idx != null && size.segments > 0) {
        part = (idx / size.segments).clamp(0.0, 1.0);
      }
    }
    return WorkRowFacts(
      isNew: e != null && e.readAtMs == null,
      played: e?.finishedAtMs != null || w.finishedEpochDay != null,
      downloaded: downloaded,
      queued: state.queued.contains(id),
      transcribed: state.transcribed.contains(id),
      video: isVideoEnclosure(e?.enclosureUrl),
      archived: e?.archivedAtMs != null,
      kept: e != null && w.persistence == 'work',
      pinned: w.pinned,
      audio: !text,
      durationMs: text ? null : e?.durationMs,
      progressMs: text || audiobook ? null : state.progressMs[id],
      partFraction: part,
      readingMs: readingMs,
    );
  }

  /// The same facts without the queued marker: on the Queue every row is
  /// queued, and saying so on each would be noise.
  WorkRowFacts withoutQueued() => WorkRowFacts(
    isNew: isNew,
    played: played,
    downloaded: downloaded,
    transcribed: transcribed,
    video: video,
    archived: archived,
    kept: kept,
    pinned: pinned,
    audio: audio,
    durationMs: durationMs,
    progressMs: progressMs,
    partFraction: partFraction,
    readingMs: readingMs,
  );

  /// Read is offered on a text, and on audio that has a transcript.
  bool get readable => !audio || transcribed;

  bool get _knowsLength => durationMs != null && durationMs! > 0;

  /// Started and not played. Played wins: a finished episode left a few
  /// seconds from its end is done, not "1 min left".
  bool get inProgress {
    if (played) return false;
    if (partFraction != null) return true;
    final p = progressMs;
    if (p == null || p <= 0) return false;
    return !_knowsLength || p < durationMs!;
  }

  double? get fraction {
    if (!inProgress) return null;
    if (partFraction != null) return partFraction;
    return _knowsLength ? progressMs! / durationMs! : null;
  }

  int? get leftMs {
    if (!inProgress) return null;
    if (partFraction != null) {
      final r = readingMs;
      return r == null ? null : (r * (1 - partFraction!)).round();
    }
    return _knowsLength ? durationMs! - progressMs! : null;
  }
}

class WorkRow extends StatelessWidget {
  final Work work;

  /// Present when the work came from a feed.
  final Episode? episode;
  final WorkRowFacts facts;

  /// The show's name for a feed item; null where every row is the same
  /// show. A work not from a feed names its own source.
  final String? showTitle;

  /// Already-downloaded artwork, or null for the kind's glyph. Never
  /// fetched here.
  final File? artwork;

  /// Extra lines under the markers (the download line), owned by the
  /// screen.
  final List<Widget> below;

  /// What a tap on the row does. One callback, so the screen routes it
  /// through the one shared open (see work_open.dart).
  final VoidCallback? onTap;

  /// Null for a row with nothing to play.
  final VoidCallback? onPlay;

  /// Opens the text: a book or article in the reader, an episode's
  /// transcript. Shown only where [WorkRowFacts.readable], beside Play:
  /// reading and listening are equal ways in.
  final VoidCallback? onRead;

  /// The ⋮ menu: the work kind's shared items first, then any the screen
  /// adds. Null for a row with no menu.
  final PopupMenuItemBuilder<String>? menuBuilder;
  final PopupMenuItemSelected<String>? onMenu;

  /// The screen's own control at the row's very end: the Queue's drag
  /// handle.
  final Widget? trailing;

  /// Null outside selection; while selecting, whether this row is chosen.
  /// The row then shows a checkbox in place of play and the menu, and
  /// [onTap] is the screen's toggle.
  final bool? selected;

  /// Enters selection (or toggles within it); null where rows can't be
  /// selected.
  final VoidCallback? onLongPress;

  const WorkRow({
    super.key,
    required this.work,
    this.episode,
    required this.facts,
    this.showTitle,
    this.artwork,
    this.below = const [],
    this.onTap,
    this.onPlay,
    this.onRead,
    this.menuBuilder,
    this.onMenu,
    this.trailing,
    this.selected,
    this.onLongPress,
  });

  int get _id => work.id;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // An archived row is already dimmed whole; fading it again for played
    // would push its text below legible.
    final fade = facts.played && !facts.archived;
    final quiet = fade ? theme.colorScheme.onSurfaceVariant : null;
    final menu = menuBuilder;
    final tile = ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      // Carries the selected state to screen readers as well as the eye.
      selected: selected ?? false,
      // The picture sits by the title, not adrift mid-row.
      titleAlignment: ListTileTitleAlignment.top,
      // The last line's 48 dp buttons bring their own air.
      minVerticalPadding: 4,
      leading: _leading(context, fade),
      title: Text(
        work.title,
        overflow: TextOverflow.ellipsis,
        maxLines: 2,
        style: fade
            ? theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              )
            : facts.isNew
            ? theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)
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
          ...below,
          ?_statusLine(theme, quiet, menu),
        ],
      ),
      trailing: selected == null
          ? null
          : Checkbox(
              key: Key('select-$_id'),
              value: selected,
              onChanged: (_) => onTap?.call(),
            ),
    );
    if (facts.archived) {
      return Opacity(key: Key('archived-$_id'), opacity: 0.55, child: tile);
    }
    if (fade) {
      return Semantics(
        key: Key('played-$_id'),
        // A book is finished, not played.
        label: facts.audio ? 'Played' : 'Finished',
        child: tile,
      );
    }
    return tile;
  }

  /// The row's last line: its markers on the left, then Play and Read,
  /// worded, ⋮ and the screen's own control on the right. When the
  /// markers don't fit beside the actions they take a line of their own
  /// above them, never the title's width. Nothing sits beside the text,
  /// so the title keeps the row's whole width on a phone, and the
  /// actions are low and wide, in reach without a re-grip.
  Widget? _statusLine(
    ThemeData theme,
    Color? quiet,
    PopupMenuItemBuilder<String>? menu,
  ) {
    final markers = _markerList(theme);
    final markersWrap = markers.isEmpty
        ? null
        : Wrap(spacing: _markerGap, runSpacing: 2, children: markers);
    final selecting = selected != null;
    final read = !selecting && onRead != null && facts.readable;
    final play = !selecting && onPlay != null;
    final hasMenu = !selecting && menu != null;
    final hasTrailing = !selecting && trailing != null;
    if (!read && !play && !hasMenu && !hasTrailing) {
      return markersWrap == null
          ? null
          : Padding(padding: const EdgeInsets.only(top: 4), child: markersWrap);
    }
    final style = TextButton.styleFrom(
      foregroundColor: quiet,
      minimumSize: const Size(48, 48),
      padding: const EdgeInsets.symmetric(horizontal: 6),
    );
    final readButton = TextButton.icon(
      key: Key('read-$_id'),
      style: style,
      onPressed: onRead,
      // One glyph for Read, text or transcript: the same verb.
      icon: const Icon(Icons.chrome_reader_mode_outlined),
      label: const Text('Read'),
    );
    final actions = Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (play)
          TextButton.icon(
            key: Key('play-$_id'),
            style: style,
            onPressed: onPlay,
            icon: const Icon(Icons.play_circle_outline),
            label: const Text('Play'),
          ),
        if (read)
          facts.audio
              ? Tooltip(
                  message: 'Read transcript',
                  // A long press on a row belongs to the row (drag in
                  // the Queue, selection elsewhere), not to this hint.
                  triggerMode: TooltipTriggerMode.manual,
                  child: readButton,
                )
              : readButton,
        if (hasMenu)
          PopupMenuButton<String>(
            key: Key('menu-$_id'),
            tooltip: 'More',
            iconColor: quiet,
            onSelected: onMenu,
            itemBuilder: menu,
          ),
        if (hasTrailing) trailing!,
      ],
    );
    return _MarkersAndActions(
      markers: markersWrap,
      markersExtraWidth: markers.isEmpty
          ? 0
          : _markerGap * (markers.length - 1),
      actions: actions,
    );
  }

  String _meta() => workMeta(work, episode, facts, showTitle);

  Widget? _leading(BuildContext context, bool fade) {
    // On a narrow screen at large text the words need the room more than
    // the picture does: the title and the length must still be readable.
    final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
    if (scale >= 1.6 && MediaQuery.sizeOf(context).width < 400) return null;
    final art = artwork;
    final scheme = Theme.of(context).colorScheme;
    // The same 48 dp box on every row, art or not, so titles line up
    // down any list.
    final glyph = Container(
      key: Key('glyph-$_id'),
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(kindIcon(work.kind, episode), color: scheme.onSurfaceVariant),
    );
    if (art == null) return glyph;
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
          errorBuilder: (_, _, _) => glyph,
        ),
      ),
    );
  }

  List<Widget> _markerList(ThemeData theme) => workMarkers(theme, facts, _id);
}

/// The row's meta line, `source · date · length`, for anything else that
/// names a work the same way (the work page's header).
String workMeta(
  Work work,
  Episode? episode,
  WorkRowFacts facts,
  String? showTitle,
) {
  final e = episode;
  final parts = [
    ?_sourceOf(work, episode, showTitle),
    e != null
        ? formatDay(e.publishedAtMs)
        : formatEpochDay(work.firstSeenEpochDay),
    if (facts.leftMs != null)
      _whole(formatTimeLeft(facts.leftMs!))
    else if (facts.durationMs != null && facts.durationMs! > 0)
      _whole(formatLength(facts.durationMs!))
    else if (facts.readingMs != null && facts.readingMs! > 0)
      _whole('${formatLength(facts.readingMs!)} read'),
  ];
  return parts.join(' · ');
}

/// A length wraps whole, never "32" on one line and "min left" on the
/// next.
String _whole(String length) => length.replaceAll(' ', '\u00A0');

/// The show for a feed item, the site for anything fetched from the
/// web, and otherwise what kind of thing it is. (No author yet: intake
/// does not keep one.)
String? _sourceOf(Work work, Episode? episode, String? showTitle) {
  if (episode != null) {
    final show = showTitle;
    return show == null ? null : (show.isEmpty ? 'Feed' : show);
  }
  // A book is a book wherever it was fetched from: an EPUB and a
  // Gutenberg download say the same thing.
  if (work.kind == 'book') return kindLabel(work.kind);
  final host = _hostOf(work.sourceUrl);
  return host ?? kindLabel(work.kind);
}

String? _hostOf(String? url) {
  if (url == null) return null;
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme || !uri.scheme.startsWith('http')) {
    return null;
  }
  final host = uri.host;
  if (host.isEmpty) return null;
  return host.startsWith('www.') ? host.substring(4) : host;
}

/// The row's markers, as words, for the work [id].
List<Widget> workMarkers(ThemeData theme, WorkRowFacts facts, int id) {
  final scheme = theme.colorScheme;
  final markers = <Widget>[
    if (facts.isNew)
      _Marker(
        label: 'New',
        color: scheme.primary,
        lead: Container(
          key: Key('unread-dot-$id'),
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: scheme.primary,
            shape: BoxShape.circle,
          ),
        ),
      ),
    if (facts.downloaded)
      _Marker(
        key: Key('downloaded-$id'),
        label: 'Downloaded',
        icon: Icons.download_done,
      ),
    if (facts.queued)
      _Marker(
        key: Key('queued-$id'),
        label: 'In Queue',
        icon: Icons.queue_music,
      ),
    if (facts.transcribed)
      _Marker(
        key: Key('transcribed-$id'),
        label: 'Transcript',
        icon: Icons.subject,
      ),
    if (facts.video)
      _Marker(
        key: Key('video-$id'),
        label: 'Video',
        icon: Icons.movie_outlined,
      ),
    if (facts.kept)
      _Marker(
        key: Key('kept-$id'),
        label: 'Kept',
        icon: Icons.bookmark_added_outlined,
      ),
    if (facts.pinned)
      _Marker(key: Key('pinned-$id'), label: 'Pinned', icon: Icons.push_pin),
  ];
  return markers;
}

const _markerGap = 12.0;

enum _Slot { markers, actions }

/// The markers and the actions on one line when they fit, the markers on
/// a line above when they don't. A plain Row would squeeze the markers
/// into a narrow column; a Wrap can't hold the actions to the right.
class _MarkersAndActions
    extends SlottedMultiChildRenderObjectWidget<_Slot, RenderBox> {
  final Widget? markers;

  /// The markers' spacing, which their Wrap leaves out of its intrinsic
  /// width.
  final double markersExtraWidth;
  final Widget actions;

  const _MarkersAndActions({
    required this.markers,
    required this.markersExtraWidth,
    required this.actions,
  });

  @override
  Iterable<_Slot> get slots => _Slot.values;

  @override
  Widget? childForSlot(_Slot slot) => switch (slot) {
    _Slot.markers => markers,
    _Slot.actions => actions,
  };

  @override
  _RenderMarkersAndActions createRenderObject(BuildContext context) =>
      _RenderMarkersAndActions(markersExtraWidth);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMarkersAndActions renderObject,
  ) => renderObject.markersExtraWidth = markersExtraWidth;
}

class _RenderMarkersAndActions extends RenderBox
    with SlottedContainerRenderObjectMixin<_Slot, RenderBox> {
  _RenderMarkersAndActions(this._markersExtraWidth);

  double _markersExtraWidth;
  set markersExtraWidth(double v) {
    if (v == _markersExtraWidth) return;
    _markersExtraWidth = v;
    markNeedsLayout();
  }

  static const _gap = 8.0;

  /// The narrowest the markers may wrap to beside the actions.
  static const _minBeside = 96.0;

  static double layoutHeight(
    RenderBox m,
    double width,
    Size Function(RenderBox, BoxConstraints) layout,
  ) => layout(m, BoxConstraints(maxWidth: width)).height;

  RenderBox? get _markers => childForSlot(_Slot.markers);
  RenderBox get _actions => childForSlot(_Slot.actions)!;

  bool _oneLine(double width, double actionsWidth) {
    final m = _markers;
    if (m == null) return true;
    return m.getMaxIntrinsicWidth(double.infinity) +
            _markersExtraWidth +
            _gap +
            actionsWidth <=
        width;
  }

  /// Lays out (or dry-lays out, through [layout]) and returns the size,
  /// placing children through [place] when it is given.
  Size _compute(
    BoxConstraints constraints,
    Size Function(RenderBox, BoxConstraints) layout, [
    void Function(RenderBox, Offset)? place,
  ]) {
    final width = constraints.maxWidth;
    final a = layout(_actions, BoxConstraints(maxWidth: width));
    final m = _markers;
    if (m == null) {
      place?.call(_actions, Offset(width - a.width, 0));
      return constraints.constrain(Size(width, a.height));
    }
    // Beside the actions when they fit on one line, or wrap there within
    // the actions' own 48 dp height: either way the row grows no taller.
    final room = width - _gap - a.width;
    final beside =
        _oneLine(width, a.width) ||
        (room >= _minBeside && layoutHeight(m, room, layout) <= a.height);
    if (beside) {
      final ms = layout(m, BoxConstraints(maxWidth: room));
      final h = ms.height > a.height ? ms.height : a.height;
      place?.call(m, Offset(0, (h - ms.height) / 2));
      place?.call(_actions, Offset(width - a.width, (h - a.height) / 2));
      return constraints.constrain(Size(width, h));
    }
    final ms = layout(m, BoxConstraints(maxWidth: width));
    place?.call(m, const Offset(0, 4));
    place?.call(_actions, Offset(width - a.width, ms.height + 4));
    return constraints.constrain(Size(width, 4 + ms.height + a.height));
  }

  @override
  void performLayout() {
    size = _compute(
      constraints,
      (child, c) {
        child.layout(c, parentUsesSize: true);
        return child.size;
      },
      (child, offset) => (child.parentData! as BoxParentData).offset = offset,
    );
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _compute(constraints, (child, c) => child.getDryLayout(c));

  @override
  double computeMinIntrinsicHeight(double width) =>
      getDryLayout(BoxConstraints(maxWidth: width)).height;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeMinIntrinsicHeight(width);

  @override
  double computeMinIntrinsicWidth(double height) {
    final m = _markers?.getMinIntrinsicWidth(height) ?? 0;
    final a = _actions.getMinIntrinsicWidth(height);
    return m > a ? m : a;
  }

  @override
  double computeMaxIntrinsicWidth(double height) =>
      (_markers?.getMaxIntrinsicWidth(height) ?? 0) +
      _markersExtraWidth +
      _gap +
      _actions.getMaxIntrinsicWidth(height);

  @override
  void paint(PaintingContext context, Offset offset) {
    for (final child in children) {
      context.paintChild(
        child,
        offset + (child.parentData! as BoxParentData).offset,
      );
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final child in children) {
      final offset = (child.parentData! as BoxParentData).offset;
      final hit = result.addWithPaintOffset(
        offset: offset,
        position: position,
        hitTest: (result, transformed) =>
            child.hitTest(result, position: transformed),
      );
      if (hit) return true;
    }
    return false;
  }
}

/// The glyph for a work with no art: what kind of thing it is at a glance.
IconData kindIcon(String kind, [Episode? episode]) => switch (kind) {
  'book' => Icons.menu_book_outlined,
  'audiobook' => Icons.headphones_outlined,
  'article' => Icons.article_outlined,
  'episode' when episode?.enclosureUrl != null => Icons.podcasts,
  'episode' => Icons.article_outlined,
  _ => Icons.notes_outlined,
};

String kindLabel(String kind) => switch (kind) {
  'book' => 'Book',
  'audiobook' => 'Audiobook',
  'article' => 'Article',
  'episode' => 'Episode',
  _ => 'Note',
};

/// A small word with an optional icon. Text rather than a Chip, which fixes
/// its height and clips a long label at large text.
class _Marker extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Widget? lead;
  final Color? color;
  const _Marker({
    super.key,
    required this.label,
    this.icon,
    this.lead,
    this.color,
  });

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
          child: Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(color: c),
          ),
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
