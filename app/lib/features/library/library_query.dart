/// A small pure query model over the library (Campaign 5 Phase 2): every
/// field is optional and AND-combined — an unset field is ignored, a set
/// field must match. No dependency on drift; evaluated in plain Dart over
/// whatever the library screen already loaded, so adding a filter never
/// costs a query round-trip.
///
/// "course" is deliberately absent from [LibraryItemType]: courses
/// (`Courses` table) are never spine works — `worksOf` cannot return one —
/// so a "course" filter option would be a dead control that structurally
/// matches zero rows (ADR-0011). The four types below are exactly the
/// `Work.kind` values this app actually produces.
library;

import '../../db/database.dart' hide Alignment;

enum LibraryItemType { book, article, podcast, note }

/// [LibraryItemType.podcast] maps to the `episode` kind — the label the
/// rest of the app already uses for feed audio items is "podcast", not
/// "episode" (see the feed settings screen's "Playback speed for this
/// podcast").
LibraryItemType? libraryItemTypeOfKind(String kind) => switch (kind) {
      'book' => LibraryItemType.book,
      'article' => LibraryItemType.article,
      'episode' => LibraryItemType.podcast,
      'note' => LibraryItemType.note,
      _ => null,
    };

enum ReadState { any, unread, read }

/// One library entry as the query sees it: a work, its episode row when
/// it has one (only `kind == 'episode'` works do), and the feed title for
/// display — matching [LibraryQuery.feedId] needs only [episode], never
/// the title.
typedef LibraryQueryEntry = ({Work work, Episode? episode, String? feedTitle});

class LibraryQuery {
  /// Case-insensitive substring match on the work's title. Null/empty
  /// matches everything — the library has no separate stored body to
  /// search against title-only is the honest scope for v1.
  final String? textSearch;

  /// Empty matches every kind.
  final Set<LibraryItemType> types;

  /// Matches episode works whose feed is exactly this id; null matches
  /// any feed (and any non-episode work, since it has none). A non-null
  /// [feedId] excludes every non-episode work by construction.
  final int? feedId;

  /// "Read" for an episode work is `episode.readAtMs != null` (the same
  /// signal the river's unread dot uses); for every other kind it's
  /// `work.finishedEpochDay != null` (the closest existing analog — the
  /// library's own progress bar is keyed off the same field).
  final ReadState readState;

  /// true = pinned only; null/false = ignored (this is not a tri-state
  /// "unpinned only" filter — nothing in the spec asked for one).
  final bool? pinned;

  const LibraryQuery({
    this.textSearch,
    this.types = const {},
    this.feedId,
    this.readState = ReadState.any,
    this.pinned,
  });

  /// True when every field is unset — a query that would match
  /// everything. Distinguishes "the user applied an empty filter" (not
  /// really a filter at all) from "the user applied a real one", so the
  /// library's filter icon doesn't offer to "clear" a no-op and Apply/Save
  /// without touching any control doesn't leave a phantom active state.
  bool get isEmpty =>
      (textSearch == null || textSearch!.isEmpty) &&
      types.isEmpty &&
      feedId == null &&
      readState == ReadState.any &&
      pinned == null;

  Map<String, Object?> toJson() => {
        if (textSearch != null && textSearch!.isNotEmpty)
          'textSearch': textSearch,
        if (types.isNotEmpty) 'types': [for (final t in types) t.name],
        if (feedId != null) 'feedId': feedId,
        if (readState != ReadState.any) 'readState': readState.name,
        if (pinned != null) 'pinned': pinned,
      };

  factory LibraryQuery.fromJson(Map<String, Object?> json) => LibraryQuery(
        textSearch: json['textSearch'] as String?,
        types: {
          for (final t
              in (json['types'] as List?)?.cast<String>() ?? const <String>[])
            LibraryItemType.values.byName(t)
        },
        feedId: (json['feedId'] as num?)?.toInt(),
        readState: json['readState'] == null
            ? ReadState.any
            : ReadState.values.byName(json['readState'] as String),
        pinned: json['pinned'] as bool?,
      );
}

bool matchesLibraryQuery(LibraryQueryEntry entry, LibraryQuery query) {
  final work = entry.work;
  final episode = entry.episode;

  final search = query.textSearch?.trim();
  if (search != null &&
      search.isNotEmpty &&
      !work.title.toLowerCase().contains(search.toLowerCase())) {
    return false;
  }

  if (query.types.isNotEmpty) {
    final type = libraryItemTypeOfKind(work.kind);
    if (type == null || !query.types.contains(type)) return false;
  }

  if (query.feedId != null) {
    if (episode == null || episode.feedId != query.feedId) return false;
  }

  if (query.readState != ReadState.any) {
    final isRead =
        episode != null ? episode.readAtMs != null : work.finishedEpochDay != null;
    if (query.readState == ReadState.read && !isRead) return false;
    if (query.readState == ReadState.unread && isRead) return false;
  }

  if (query.pinned == true && !work.pinned) return false;

  return true;
}
