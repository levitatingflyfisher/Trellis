/// The queries behind history and search (ADR-0016 section 4). Both are
/// ordered by time, never by relevance: a ranked list is the thing
/// ADR-0003 law 1 keeps out, and "the one I heard a month ago" is found by
/// when, not by a score. Search answers in sections by where the words
/// were found (ADR-0003, 1.5.4), each newest first: a fixed place, not a
/// score.
///
/// Every local search box goes through [SearchStore], so the same words
/// match the same way everywhere.
library;

import 'dart:async';

import 'package:drift/drift.dart';

import '../../db/database.dart';
import '../../db/search_index.dart';
import '../shared/shelf_key.dart';

/// One work as history and search show it. [episode] is null for a book,
/// a note or anything else that did not come from a feed.
class SearchItem {
  final Work work;
  final Episode? episode;
  final String? showTitle;
  const SearchItem(this.work, this.episode, this.showTitle);
}

class HistoryEntry {
  final SearchItem item;
  final int atMs;
  const HistoryEntry(this.item, this.atMs);
}

/// A transcript sentence that matched. [snippet] marks each match between
/// U+0002 and U+0003; [parseSnippet] splits it.
class TranscriptHit {
  final SearchItem item;
  final int segmentIdx;
  final int? tStartMs;
  final String snippet;
  const TranscriptHit(this.item, this.segmentIdx, this.tStartMs, this.snippet);
}

/// One section of search results: its first rows and how many there
/// are in all, so nothing is cut off without saying so.
class SearchSection<T> {
  final List<T> rows;
  final int count;
  const SearchSection(this.rows, this.count);
  bool get hasMore => count > rows.length;
}

/// Where a work's words were found. A work is listed in its first tier
/// only.
enum SearchTier {
  /// Its title, or for an episode its show's name.
  titles,

  /// "In the text": its show notes, a post's text or an episode's
  /// description; or words split between those and its title.
  notes,
}

class SearchResults {
  /// Followed shows whose name matches, in shelf order. A show with no
  /// items (never fetched, failing, or every item skipped by a rule) is
  /// otherwise unfindable: items carry a show's name, not the show.
  final SearchSection<Feed> showSection;
  final SearchSection<SearchItem> titleSection;
  final SearchSection<SearchItem> notesSection;

  /// Transcript sentences, of any work: a work found above also lists
  /// its sentences here, for the jump to where it was said.
  final SearchSection<TranscriptHit> saidSection;

  const SearchResults({
    this.showSection = const SearchSection([], 0),
    this.titleSection = const SearchSection([], 0),
    this.notesSection = const SearchSection([], 0),
    this.saidSection = const SearchSection([], 0),
  });
  static const empty = SearchResults();

  List<Feed> get shows => showSection.rows;

  /// The first rows of both work sections, titles first.
  List<SearchItem> get items => [...titleSection.rows, ...notesSection.rows];
  List<TranscriptHit> get said => saidSection.rows;

  bool get isEmpty =>
      showSection.count == 0 &&
      titleSection.count == 0 &&
      notesSection.count == 0 &&
      saidSection.count == 0;
}

const _open = '\u0002';
const _close = '\u0003';

List<({String text, bool match})> parseSnippet(String raw) {
  final out = <({String text, bool match})>[];
  var match = false;
  final buf = StringBuffer();
  void flush() {
    if (buf.isNotEmpty) out.add((text: buf.toString(), match: match));
    buf.clear();
  }

  for (final ch in raw.split('')) {
    if (ch == _open || ch == _close) {
      flush();
      match = ch == _open;
    } else {
      buf.write(ch);
    }
  }
  flush();
  return out;
}

final _term = RegExp(r'[\p{L}\p{N}]+', unicode: true);

/// A word, with any contraction kept whole; phone keyboards type the
/// curly apostrophe.
final _word = RegExp(
    r"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*", // copy-typography: code
    unicode: true);
final _apostrophe = RegExp("['’]"); // copy-typography: code

/// How many rows each section shows before "Show all"; the rest come a
/// page at a time.
const searchPageSize = 10;

class SearchStore {
  final AppDatabase db;

  /// Skips the index even where it exists, so the fallback stays tested.
  final bool forceLike;
  bool? _fts;

  /// How many rows of each section [search] returns.
  final int pageSize;

  SearchStore(this.db, {this.forceLike = false, this.pageSize = searchPageSize});

  /// The user's words as an FTS5 query: each word quoted, so nothing they
  /// type is read as syntax, and each one a prefix, so "tim machine"
  /// finds "Time machine" and results follow the typing. Null when there
  /// is no word at all.
  static String? matchQuery(String input) {
    final phrases = _phrases(input);
    return phrases.isEmpty ? null : phrases.join(' ');
  }

  /// One quoted phrase per word. A contraction is the index's two
  /// adjacent tokens ("it's" is stored as "it" then "s"), so it stays a
  /// phrase with no prefix: "it" and any word starting with s is noise.
  static List<String> _phrases(String input) {
    const q = '"';
    return [
      for (final m in _word.allMatches(input))
        if (m.group(0)!.split(_apostrophe) case final parts)
          parts.length == 1
              ? '$q${parts.single}$q*'
              : '$q${parts.join(' ')}$q',
    ];
  }

  /// [matchQuery] with every word held to the title and show columns.
  static String? _titleQuery(String input) {
    final phrases = _phrases(input);
    return phrases.isEmpty
        ? null
        : [for (final p in phrases) '{title show} : $p'].join(' ');
  }

  /// Whether searches go through the FTS index rather than LIKE.
  Future<bool> get usesIndex => _useFts();

  /// How far the index's fill after the v29 hop has come, 0 to 100; null
  /// when it is complete. Until then search answers by LIKE over titles,
  /// show names, show notes and transcripts, filled or not; a post's text
  /// and an episode's short description wait for the index.
  Future<int?> get indexProgress => searchBackfillPercent(db);

  /// Whether the fill stopped on an error; it tries again next launch.
  Future<bool> get indexStalled => searchBackfillStalled(db);

  bool _indexFilled = false;

  Future<bool> _useFts() async {
    if (forceLike) return false;
    if (Zone.current[_ftsDecided] case final bool decided) return decided;
    final available = _fts ??= await hasFts5(db) &&
        (await db
                .customSelect("SELECT 1 FROM sqlite_master "
                    "WHERE type = 'table' AND name = 'items_fts'")
                .get())
            .isNotEmpty;
    if (!available) return false;
    // Once filled it stays filled; only a migration empties it.
    return _indexFilled = _indexFilled || await indexProgress == null;
  }

  /// Decided once per [search], so a fill that finishes partway through
  /// never answers some sections by LIKE and the rest by the index.
  static const _ftsDecided = #searchStoreFts;

  Future<SearchResults> search(int profileId, String query) async {
    if (matchQuery(query) == null) return SearchResults.empty;
    final fts = await _useFts();
    return runZoned(() => _search(profileId, query),
        zoneValues: {_ftsDecided: fts});
  }

  Future<SearchResults> _search(int profileId, String query) async {
    final shows = await showsMatching(profileId, query);
    final titles = await _itemsPage(profileId, query, SearchTier.titles,
        offset: 0, limit: pageSize, withCount: true);
    final notes = await _itemsPage(profileId, query, SearchTier.notes,
        offset: 0, limit: pageSize, withCount: true);
    final said = await _saidPage(profileId, query,
        offset: 0, limit: pageSize, withCount: true);
    return SearchResults(
      showSection:
          SearchSection(shows.take(pageSize).toList(), shows.length),
      titleSection: SearchSection(titles.rows, titles.count),
      notesSection: SearchSection(notes.rows, notes.count),
      saidSection: SearchSection(said.rows, said.count),
    );
  }

  /// The rows of a work section after the first [offset], newest first.
  Future<List<SearchItem>> itemsPage(
          int profileId, String query, SearchTier tier,
          {required int offset, int limit = 100}) async =>
      (await _itemsPage(profileId, query, tier,
              offset: offset, limit: limit, withCount: false))
          .rows;

  /// Transcript hits after the first [offset], newest first.
  Future<List<TranscriptHit>> saidPage(int profileId, String query,
          {required int offset, int limit = 100}) async =>
      (await _saidPage(profileId, query,
              offset: offset, limit: limit, withCount: false))
          .rows;

  /// Every Library work (anything kept) the words find, in any section:
  /// the Library's filter, matched as every other search box matches.
  Future<Set<int>> libraryMatches(int profileId, String query) async {
    if (matchQuery(query) == null) return const {};
    final any = _workFilter(query, null, await _useFts());
    final rows = await db.customSelect('''
      SELECT w.id AS id FROM ${any.from}
      WHERE w.profile_id = ? AND w.persistence <> 'ephemeron' AND ${any.where}
      UNION
      ${await _saidWorksSql()}
    ''', variables: [
      Variable.withInt(profileId),
      ...any.vars,
      ...await _saidWorksVars(profileId, query),
    ]).get();
    return {for (final r in rows) r.read<int>('id')};
  }

  /// Every word must appear in the show's name, matched as every other
  /// word is: through the index where there is one. All of them, in
  /// shelf order: a profile follows tens or hundreds of shows.
  Future<List<Feed>> showsMatching(int profileId, String query) async {
    final terms = [for (final m in _term.allMatches(query)) m.group(0)!];
    if (terms.isEmpty) return const [];
    final match = matchQuery(query)!;
    final rows = await _useFts()
        ? await db.customSelect('''
      SELECT f.* FROM feeds_fts JOIN feeds f ON f.id = feeds_fts.rowid
      WHERE feeds_fts MATCH ? AND f.profile_id = ?
    ''', variables: [
            Variable.withString(match),
            Variable.withInt(profileId),
          ], readsFrom: {db.feeds}).get()
        : await db.customSelect('''
      SELECT * FROM feeds WHERE profile_id = ? AND
        ${[for (final _ in terms) "title LIKE ? ESCAPE '\\'"].join(' AND ')}
    ''', variables: [
            Variable.withInt(profileId),
            for (final t in terms) Variable.withString(_like(t)),
          ], readsFrom: {db.feeds}).get();
    return [for (final r in rows) db.feeds.map(r.data)]
      ..sort((a, b) => shelfKey(a.title).compareTo(shelfKey(b.title)));
  }

  static const _recency =
      'COALESCE(e.published_at_ms, w.first_seen_epoch_day * 86400000)';

  /// Which works [tier] holds (all of them, for null), as a FROM and a
  /// WHERE over `w` (works) and `e` (episodes). The index matches the
  /// title tier against the title and show columns only, and the notes
  /// tier as every column less that; LIKE applies the same split.
  ({String from, String where, List<Variable> vars}) _workFilter(
      String query, SearchTier? tier, bool fts) {
    if (fts) {
      final all = matchQuery(query)!;
      final titles = _titleQuery(query)!;
      return (
        from: 'works w LEFT JOIN episodes e ON e.work_id = w.id',
        where: 'w.id IN (SELECT rowid FROM items_fts WHERE items_fts MATCH ?)',
        vars: [
          Variable.withString(switch (tier) {
            null => all,
            SearchTier.titles => titles,
            SearchTier.notes => '($all) NOT ($titles)',
          }),
        ],
      );
    }
    final terms = [for (final m in _term.allMatches(query)) m.group(0)!];
    String each(List<String> columns) {
      final any = [for (final c in columns) _likeOf(c)].join(' OR ');
      return [for (final _ in terms) '($any)'].join(' AND ');
    }

    List<Variable> vars(int n) => [
          for (final t in terms)
            for (var i = 0; i < n; i++) Variable.withString(_like(t)),
        ];
    final inTitles = each(['w.title', 'f.title']);
    final inAny = each(['w.title', 'f.title', 'n.plain']);
    return (
      from: 'works w LEFT JOIN episodes e ON e.work_id = w.id '
          'LEFT JOIN feeds f ON f.id = e.feed_id '
          'LEFT JOIN work_notes n ON n.work_id = w.id',
      where: switch (tier) {
        SearchTier.titles => '($inTitles)',
        null => '($inAny)',
        SearchTier.notes => '($inAny) AND NOT ($inTitles)',
      },
      vars: switch (tier) {
        SearchTier.titles => vars(2),
        null => vars(3),
        SearchTier.notes => [...vars(3), ...vars(2)],
      },
    );
  }

  /// One page of a work section. With [withCount], the section's total
  /// rides on the page in the same pass.
  Future<({List<SearchItem> rows, int count})> _itemsPage(
      int profileId, String query, SearchTier tier,
      {required int offset, required int limit, required bool withCount}) async {
    final f = _workFilter(query, tier, await _useFts());
    final rows = await db.customSelect('''
      SELECT w.id AS id${withCount ? ', COUNT(*) OVER () AS n' : ''}
      FROM ${f.from}
      WHERE w.profile_id = ? AND ${f.where}
      ORDER BY $_recency DESC, w.id DESC
      LIMIT ? OFFSET ?
    ''', variables: [
      Variable.withInt(profileId),
      ...f.vars,
      Variable.withInt(limit),
      Variable.withInt(offset),
    ]).get();
    // Asked for on the first page only, where no rows means none at all.
    final count = withCount && rows.isNotEmpty ? rows.first.read<int>('n') : 0;
    final ids = [for (final r in rows) r.read<int>('id')];
    final items = await _items(ids.toSet());
    return (rows: [for (final id in ids) ?items[id]], count: count);
  }

  /// The transcript query, public so a test can read its plan. The
  /// segment's key is unpacked from the index rowid, so every join after
  /// the MATCH is a primary-key lookup and `segments` is never scanned.
  /// Every sentence lists, even of a work found by its title or text:
  /// the jump to the sentence is the point.
  static const saidSql = '''
      SELECT segments_fts.rowid / $segmentRowidStride AS work_id,
             segments_fts.rowid % $segmentRowidStride AS idx,
             a.t_start_ms AS t,
             snippet(segments_fts, 0, char(2), char(3), '…', 12) AS snip
      FROM segments_fts
      JOIN alignments a
        ON a.work_id = segments_fts.rowid / $segmentRowidStride
       AND a.segment_idx = segments_fts.rowid % $segmentRowidStride
      JOIN works w ON w.id = a.work_id
      LEFT JOIN episodes e ON e.work_id = w.id
      WHERE segments_fts MATCH ? AND w.profile_id = ?
      ORDER BY $_recency DESC, w.id DESC, idx
      LIMIT ? OFFSET ?
    ''';

  /// How many [saidSql] would list in all. Apart from it: `snippet()`
  /// can't run beside a window function.
  static const _saidCountSql = '''
      SELECT COUNT(*) AS n
      FROM segments_fts
      JOIN alignments a
        ON a.work_id = segments_fts.rowid / $segmentRowidStride
       AND a.segment_idx = segments_fts.rowid % $segmentRowidStride
      JOIN works w ON w.id = a.work_id
      WHERE segments_fts MATCH ? AND w.profile_id = ?
    ''';

  Future<({List<TranscriptHit> rows, int count})> _saidPage(
      int profileId, String query,
      {required int offset, required int limit, required bool withCount}) async {
    final List<({int workId, int idx, int? t, String snip})> hits;
    var count = 0;
    if (await _useFts()) {
      final match = matchQuery(query)!;
      final rows = await db.customSelect(saidSql, variables: [
        Variable.withString(match),
        Variable.withInt(profileId),
        Variable.withInt(limit),
        Variable.withInt(offset),
      ]).get();
      if (withCount && rows.isNotEmpty) {
        count = (await db.customSelect(_saidCountSql, variables: [
          Variable.withString(match),
          Variable.withInt(profileId),
        ]).getSingle())
            .read<int>('n');
      }
      hits = [
        for (final r in rows)
          (
            workId: r.read<int>('work_id'),
            idx: r.read<int>('idx'),
            t: r.read<int?>('t'),
            snip: r.read<String>('snip'),
          ),
      ];
    } else {
      final rows = await db.customSelect('''
        SELECT s.work_id AS work_id, s.idx AS idx, a.t_start_ms AS t,
               s.body AS body, COUNT(*) OVER () AS n
        FROM segments s
        JOIN alignments a ON a.work_id = s.work_id AND a.segment_idx = s.idx
        JOIN works w ON w.id = s.work_id
        LEFT JOIN episodes e ON e.work_id = w.id
        WHERE w.profile_id = ? AND s.body LIKE ? ESCAPE '\\'
        ORDER BY $_recency DESC, w.id DESC, s.idx
        LIMIT ? OFFSET ?
      ''', variables: [
        Variable.withInt(profileId),
        Variable.withString(_like(query.trim())),
        Variable.withInt(limit),
        Variable.withInt(offset),
      ]).get();
      if (rows.isNotEmpty) count = rows.first.read<int>('n');
      hits = [
        for (final r in rows)
          (
            workId: r.read<int>('work_id'),
            idx: r.read<int>('idx'),
            t: r.read<int?>('t'),
            snip: likeSnippet(r.read<String>('body'), query.trim()),
          ),
      ];
    }
    final items = await _items({for (final h in hits) h.workId});
    return (
      rows: [
        for (final h in hits)
          if (items[h.workId] case final item?)
            TranscriptHit(item, h.idx, h.t, h.snip),
      ],
      count: withCount ? count : 0,
    );
  }

  /// The works with a transcript sentence the words find, as a SELECT of
  /// `id` for [libraryMatches] (Library works only).
  Future<String> _saidWorksSql() async => await _useFts()
      ? '''SELECT DISTINCT a.work_id AS id FROM segments_fts
        JOIN alignments a
          ON a.work_id = segments_fts.rowid / $segmentRowidStride
         AND a.segment_idx = segments_fts.rowid % $segmentRowidStride
        JOIN works w ON w.id = a.work_id
        WHERE segments_fts MATCH ? AND w.profile_id = ?
          AND w.persistence <> 'ephemeron' '''
      : '''SELECT DISTINCT s.work_id AS id FROM segments s
        JOIN alignments a ON a.work_id = s.work_id AND a.segment_idx = s.idx
        JOIN works w ON w.id = s.work_id
        WHERE s.body LIKE ? ESCAPE '\\' AND w.profile_id = ?
          AND w.persistence <> 'ephemeron' ''';

  Future<List<Variable>> _saidWorksVars(int profileId, String query) async => [
        Variable.withString(
            await _useFts() ? matchQuery(query)! : _like(query.trim())),
        Variable.withInt(profileId),
      ];

  static String _likeOf(String column) =>
      "$column LIKE ? ESCAPE '\\'"; // copy-typography: code

  static String _like(String term) =>
      '%${term.replaceAll('\\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}%';

  /// What the user actually listened to or read, latest touch first: a
  /// listening place past the start, a reading place past the first
  /// word, or a finish by ear. Never "seen" or "Mark played", which
  /// triage and clean-up set without anyone listening.
  Future<List<HistoryEntry>> history(int profileId, {int limit = 500}) async {
    final rows = await db.customSelect('''
      SELECT t.work_id AS work_id, MAX(t.at) AS at FROM (
        SELECT work_id, updated_at_ms AS at FROM positions
          WHERE profile_id = ? AND (segment_idx > 0 OR word_idx > 0)
        UNION ALL
        SELECT work_id, updated_at_ms FROM player_positions
          WHERE profile_id = ? AND t_ms > 0
        UNION ALL
        -- The work's finished day is stamped only by playback reaching
        -- the end; "Mark played" leaves it alone.
        SELECT e.work_id, e.finished_at_ms FROM episodes e
          JOIN works fw ON fw.id = e.work_id
          WHERE e.finished_at_ms IS NOT NULL
            AND fw.finished_epoch_day IS NOT NULL
      ) t
      JOIN works w ON w.id = t.work_id
      WHERE w.profile_id = ?
      GROUP BY t.work_id
      ORDER BY at DESC, t.work_id DESC
      LIMIT ?
    ''', variables: [
      Variable.withInt(profileId),
      Variable.withInt(profileId),
      Variable.withInt(profileId),
      Variable.withInt(limit),
    ]).get();
    final items =
        await _items({for (final r in rows) r.read<int>('work_id')});
    return [
      for (final r in rows)
        if (items[r.read<int>('work_id')] case final item?)
          HistoryEntry(item, r.read<int>('at')),
    ];
  }

  Future<Map<int, SearchItem>> _items(Set<int> ids) async {
    if (ids.isEmpty) return const {};
    final q = db.select(db.works).join([
      leftOuterJoin(db.episodes, db.episodes.workId.equalsExp(db.works.id)),
      leftOuterJoin(db.feeds, db.feeds.id.equalsExp(db.episodes.feedId)),
    ])
      ..where(db.works.id.isIn(ids));
    return {
      for (final r in await q.get())
        r.readTable(db.works).id: SearchItem(
          r.readTable(db.works),
          r.readTableOrNull(db.episodes),
          r.readTableOrNull(db.feeds)?.title,
        ),
    };
  }
}

/// The fallback's snippet: a window of the sentence around the first
/// place the words appear, marked the same way FTS5 marks its own.
String likeSnippet(String body, String query, {int context = 40}) {
  final at = body.toLowerCase().indexOf(query.toLowerCase());
  if (at < 0) return body;
  final start = (at - context).clamp(0, body.length);
  final end = (at + query.length + context).clamp(0, body.length);
  return '${start > 0 ? '…' : ''}${body.substring(start, at)}'
      '$_open${body.substring(at, at + query.length)}$_close'
      '${body.substring(at + query.length, end)}'
      '${end < body.length ? '…' : ''}';
}
