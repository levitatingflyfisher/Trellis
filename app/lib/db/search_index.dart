/// The full-text index behind search (ADR-0016 section 4): two FTS5
/// tables kept in step with their source rows by triggers.
///
/// Each index stores its own copy of the text rather than pointing at the
/// source table: `segments` has no INTEGER PRIMARY KEY, so its rowids can
/// move under VACUUM, and a copy is what lets `snippet()` work at all.
/// Only transcript sentences (segments with an alignment) are indexed,
/// since a book's whole body would double its storage for a search the
/// brief never asked for.
library;

import 'package:drift/drift.dart';

/// Packs a segment's composite key into one rowid. 2^20 segments per work
/// is far past any transcript (a 10 h episode is a few thousand).
const segmentRowidStride = 1048576;

/// Triggers name only ids, titles and bodies. The migration fixtures drop
/// other columns from a current-schema file, and SQLite refuses to drop a
/// column a trigger mentions.
const _ddl = [
  // One row per work, its title beside its show's name, so "serial
  // episode 5" finds an episode whose title says "Episode 5" on a show
  // called Serial: every word has to land in one column or the other.
  "CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5("
      "title, show, tokenize = 'unicode61 remove_diacritics 2', "
      "prefix = '2 3')",
  "CREATE VIRTUAL TABLE IF NOT EXISTS segments_fts USING fts5("
      "body, tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3')",
  '''CREATE TRIGGER IF NOT EXISTS items_fts_ai AFTER INSERT ON works BEGIN
       INSERT INTO items_fts(rowid, title, show) VALUES (new.id, new.title, '');
     END''',
  '''CREATE TRIGGER IF NOT EXISTS items_fts_ad AFTER DELETE ON works BEGIN
       DELETE FROM items_fts WHERE rowid = old.id;
     END''',
  // UPDATE OF title: works change on every pin, finish and promote, and
  // none of those should touch the index.
  '''CREATE TRIGGER IF NOT EXISTS items_fts_au AFTER UPDATE OF title ON works
     BEGIN
       UPDATE items_fts SET title = new.title WHERE rowid = old.id;
     END''',
  // A work is inserted before its episode row, so the show arrives here.
  '''CREATE TRIGGER IF NOT EXISTS items_fts_episode_ai AFTER INSERT ON episodes
     BEGIN
       UPDATE items_fts
         SET show = (SELECT title FROM feeds WHERE id = new.feed_id)
         WHERE rowid = new.work_id;
     END''',
  // A promoted work outlives its unfollowed feed's episode row.
  '''CREATE TRIGGER IF NOT EXISTS items_fts_episode_ad AFTER DELETE ON episodes
     BEGIN
       UPDATE items_fts SET show = '' WHERE rowid = old.work_id;
     END''',
  // Feeds are written on every refresh (validators, breaker); only a
  // renamed show reindexes.
  '''CREATE TRIGGER IF NOT EXISTS items_fts_feed_au AFTER UPDATE OF title ON feeds
     BEGIN
       UPDATE items_fts SET show = new.title
         WHERE rowid IN (SELECT work_id FROM episodes WHERE feed_id = new.id);
     END''',
  // Both writers (transcripts, backup restore) insert segments before
  // their alignments, so the alignment is the moment a sentence becomes
  // a transcript sentence.
  '''CREATE TRIGGER IF NOT EXISTS segments_fts_align AFTER INSERT ON alignments
     BEGIN
       INSERT INTO segments_fts(rowid, body)
         SELECT new.work_id * $segmentRowidStride + new.segment_idx, body
         FROM segments
         WHERE work_id = new.work_id AND idx = new.segment_idx;
     END''',
  '''CREATE TRIGGER IF NOT EXISTS segments_fts_unalign AFTER DELETE ON alignments
     BEGIN
       DELETE FROM segments_fts
         WHERE rowid = old.work_id * $segmentRowidStride + old.segment_idx;
     END''',
  '''CREATE TRIGGER IF NOT EXISTS segments_fts_ad AFTER DELETE ON segments
     BEGIN
       DELETE FROM segments_fts
         WHERE rowid = old.work_id * $segmentRowidStride + old.idx;
     END''',
  '''CREATE TRIGGER IF NOT EXISTS segments_fts_au AFTER UPDATE OF body ON segments
     BEGIN
       UPDATE segments_fts SET body = new.body
         WHERE rowid = old.work_id * $segmentRowidStride + old.idx;
     END''',
];

/// Clearing first makes the backfill safe to run over an index that a
/// current-schema file already carries (every migration fixture).
const _backfill = [
  'DELETE FROM items_fts',
  '''INSERT INTO items_fts(rowid, title, show)
       SELECT w.id, w.title, COALESCE(f.title, '')
       FROM works w
       LEFT JOIN episodes e ON e.work_id = w.id
       LEFT JOIN feeds f ON f.id = e.feed_id''',
  'DELETE FROM segments_fts',
  '''INSERT INTO segments_fts(rowid, body)
       SELECT s.work_id * $segmentRowidStride + s.idx, s.body
       FROM segments s
       JOIN alignments a ON a.work_id = s.work_id AND a.segment_idx = s.idx''',
];

/// Whether this SQLite build has FTS5. The bundled native libraries and
/// the shipped sqlite3.wasm both do; the check is here so a build that
/// doesn't still opens its database, and search falls back to LIKE.
Future<bool> hasFts5(GeneratedDatabase db) async {
  try {
    final rows = await db
        .customSelect(
            "SELECT 1 FROM pragma_module_list WHERE name = 'fts5'")
        .get();
    return rows.isNotEmpty;
  } catch (_) {
    return false;
  }
}

/// Creates (if missing) and refills the index. A no-op without FTS5.
Future<void> installSearchIndex(GeneratedDatabase db) async {
  if (!await hasFts5(db)) return;
  for (final s in _ddl) {
    await db.customStatement(s);
  }
  for (final s in _backfill) {
    await db.customStatement(s);
  }
}
