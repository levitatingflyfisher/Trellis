/// A small pure query model over the library (Campaign 5 Phase 2): every
/// field is optional and AND-combined — an unset field is ignored, a set
/// field must match. No dependency on drift; evaluated in plain Dart over
/// whatever the library screen already loaded, so adding a filter never
/// costs a query round-trip.
///
/// "course" is deliberately absent from [LibraryItemType]: courses
/// (`Courses` table) are never spine works — `worksOf` cannot return one —
/// so a "course" filter option would be a dead control that structurally
/// matches zero rows (ADR-0011).
library;

import '../../db/database.dart' hide Alignment;
import '../listen/spoken_guid.dart';

/// The kinds the Library holds, in the order its chips show them
/// (owner, 12 Nov: "what is library if 'latest' has all, text, and
/// audio?"). Lead's ruling: the Library is what you keep, so its chips are
/// the kinds of thing kept. A pasted or imported text is stored as a
/// `note`, and shown as a Text. A made episode is an episode of its show
/// with a spoken guid, told apart from one kept as it came.
enum LibraryItemType { book, article, note, audiobook, episode, made }

/// The chip's word for [t].
String libraryKindLabel(LibraryItemType t) => switch (t) {
      LibraryItemType.book => 'Books',
      LibraryItemType.article => 'Articles',
      LibraryItemType.note => 'Texts',
      LibraryItemType.audiobook => 'Audiobooks',
      LibraryItemType.episode => 'Episodes',
      LibraryItemType.made => 'Made episodes',
    };

/// The kind [entry] is, as the Library's chips sort it; null for a kind
/// the Library never shows.
LibraryItemType? libraryKindOf(Work work, Episode? episode) =>
    switch (work.kind) {
      'book' => LibraryItemType.book,
      'article' => LibraryItemType.article,
      'note' => LibraryItemType.note,
      'audiobook' => LibraryItemType.audiobook,
      // A kept episode outlives its unfollowed show's episode row.
      'episode' when episode == null => LibraryItemType.episode,
      // A feed's text post is an article too.
      'episode' when episode!.enclosureUrl == null => LibraryItemType.article,
      'episode' when isSpokenGuid(episode!.guid) => LibraryItemType.made,
      'episode' => LibraryItemType.episode,
      _ => null,
    };

enum ReadState { any, unread, read }

/// One library entry as the query sees it: a work, its episode row when
/// it has one (only `kind == 'episode'` works do), and the feed title for
/// display — matching [LibraryQuery.feedId] needs only [episode], never
/// the title.
typedef LibraryQueryEntry = ({Work work, Episode? episode, String? feedTitle});

class LibraryQuery {
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
      types.isEmpty &&
      feedId == null &&
      readState == ReadState.any &&
      pinned == null;

  Map<String, Object?> toJson() => {
        if (types.isNotEmpty) 'types': [for (final t in types) t.name],
        if (feedId != null) 'feedId': feedId,
        if (readState != ReadState.any) 'readState': readState.name,
        if (pinned != null) 'pinned': pinned,
      };

  /// A view saved before a kind was renamed keeps its other parts and
  /// drops the kind it no longer names (and its words, which the search
  /// bar holds now): one household's views, quicker to save again than to
  /// carry a translation table for.
  factory LibraryQuery.fromJson(Map<String, Object?> json) => LibraryQuery(
        types: {
          for (final t
              in (json['types'] as List?)?.cast<String>() ?? const <String>[])
            for (final k in LibraryItemType.values)
              if (k.name == t) k
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

  if (query.types.isNotEmpty) {
    final type = libraryKindOf(work, episode);
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
