/// The queries behind history and search (ADR-0016 section 4). Both are
/// ordered by time, never by relevance: a ranked list is the thing
/// ADR-0003 law 1 keeps out, and "the one I heard a month ago" is found by
/// when, not by a score.
library;

import 'package:drift/drift.dart';

import '../../db/database.dart';
import '../../db/search_index.dart';

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

class SearchResults {
  final List<SearchItem> items;
  final List<TranscriptHit> said;
  const SearchResults(this.items, this.said);
  static const empty = SearchResults([], []);
  bool get isEmpty => items.isEmpty && said.isEmpty;
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

/// The cap keeps a common word in a long-followed show from building a
/// list nobody scrolls; narrowing the words is the way past it.
const _limit = 100;

class SearchStore {
  final AppDatabase db;

  /// Skips the index even where it exists, so the fallback stays tested.
  final bool forceLike;
  bool? _fts;

  SearchStore(this.db, {this.forceLike = false});

  /// The user's words as an FTS5 query: each word quoted, so nothing they
  /// type is read as syntax, and the last one a prefix, so results follow
  /// the typing. Null when there is no word at all.
  static String? matchQuery(String input) {
    final terms = [for (final m in _term.allMatches(input)) m.group(0)!];
    if (terms.isEmpty) return null;
    const q = '"';
    return [
      for (final (i, t) in terms.indexed)
        i == terms.length - 1 ? '$q$t$q*' : '$q$t$q',
    ].join(' ');
  }

  /// Whether searches go through the FTS index rather than LIKE.
  Future<bool> get usesIndex => _useFts();

  Future<bool> _useFts() async {
    if (forceLike) return false;
    return _fts ??= await hasFts5(db) &&
        (await db
                .customSelect("SELECT 1 FROM sqlite_master "
                    "WHERE type = 'table' AND name = 'items_fts'")
                .get())
            .isNotEmpty;
  }

  Future<SearchResults> search(int profileId, String query) async {
    final match = matchQuery(query);
    if (match == null) return SearchResults.empty;
    return await _useFts()
        ? _searchFts(profileId, match)
        : _searchLike(profileId, query.trim());
  }

  static const _recency =
      'COALESCE(e.published_at_ms, w.first_seen_epoch_day * 86400000)';

  /// The transcript query, public so a test can read its plan. The
  /// segment's key is unpacked from the index rowid, so every join after
  /// the MATCH is a primary-key lookup and `segments` is never scanned.
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
      LIMIT $_limit
    ''';

  Future<SearchResults> _searchFts(int profileId, String match) async {
    final ids = await db.customSelect('''
      SELECT w.id AS id FROM items_fts
      JOIN works w ON w.id = items_fts.rowid
      LEFT JOIN episodes e ON e.work_id = w.id
      WHERE items_fts MATCH ? AND w.profile_id = ?
      ORDER BY $_recency DESC, w.id DESC
      LIMIT $_limit
    ''', variables: [
      Variable.withString(match),
      Variable.withInt(profileId),
    ]).get();
    final said = await db.customSelect(saidSql, variables: [
      Variable.withString(match),
      Variable.withInt(profileId),
    ]).get();
    return _assemble(
        [for (final r in ids) r.read<int>('id')],
        [
          for (final r in said)
            (
              workId: r.read<int>('work_id'),
              idx: r.read<int>('idx'),
              t: r.read<int?>('t'),
              snip: r.read<String>('snip'),
            ),
        ]);
  }

  static String _like(String term) =>
      '%${term.replaceAll('\\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}%';

  /// Every word must appear in the title or the show's name, the same
  /// rule the index applies.
  Future<SearchResults> _searchLike(int profileId, String query) async {
    final terms = [for (final m in _term.allMatches(query)) m.group(0)!];
    final each = [
      for (final _ in terms)
        "(w.title LIKE ? ESCAPE '\\' OR f.title LIKE ? ESCAPE '\\')",
    ].join(' AND ');
    final ids = await db.customSelect('''
      SELECT w.id AS id FROM works w
      LEFT JOIN episodes e ON e.work_id = w.id
      LEFT JOIN feeds f ON f.id = e.feed_id
      WHERE w.profile_id = ? AND $each
      ORDER BY $_recency DESC, w.id DESC
      LIMIT $_limit
    ''', variables: [
      Variable.withInt(profileId),
      for (final t in terms) ...[
        Variable.withString(_like(t)),
        Variable.withString(_like(t)),
      ],
    ]).get();
    final said = await db.customSelect('''
      SELECT s.work_id AS work_id, s.idx AS idx, a.t_start_ms AS t,
             s.body AS body
      FROM segments s
      JOIN alignments a ON a.work_id = s.work_id AND a.segment_idx = s.idx
      JOIN works w ON w.id = s.work_id
      LEFT JOIN episodes e ON e.work_id = w.id
      WHERE w.profile_id = ? AND s.body LIKE ? ESCAPE '\\'
      ORDER BY $_recency DESC, w.id DESC, s.idx
      LIMIT $_limit
    ''', variables: [
      Variable.withInt(profileId),
      Variable.withString(_like(query)),
    ]).get();
    return _assemble(
        [for (final r in ids) r.read<int>('id')],
        [
          for (final r in said)
            (
              workId: r.read<int>('work_id'),
              idx: r.read<int>('idx'),
              t: r.read<int?>('t'),
              snip: likeSnippet(r.read<String>('body'), query),
            ),
        ]);
  }

  Future<SearchResults> _assemble(List<int> itemIds,
      List<({int workId, int idx, int? t, String snip})> said) async {
    final items = await _items({...itemIds, for (final s in said) s.workId});
    return SearchResults(
      [for (final id in itemIds) ?items[id]],
      [
        for (final s in said)
          if (items[s.workId] case final item?)
            TranscriptHit(item, s.idx, s.t, s.snip),
      ],
    );
  }

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
