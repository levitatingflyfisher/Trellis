import 'package:trellis/db/indexes.dart';

/// What v26 and later added, as SQL that takes it back off a file first
/// made at the current schema. Every migration fixture stamped below v26
/// runs this first: SQLite refuses to drop a column an index names, and a
/// fixture that kept a newer column would hit a duplicate-column error on
/// the hop that adds it.
String get stripV26 => [
      for (final name in appIndexes.keys) 'DROP INDEX IF EXISTS $name;',
      'ALTER TABLE feeds DROP COLUMN body_hash;',
      stripV27,
    ].join('\n');

/// What v27 added, for a fixture stamped v26.
String get stripV27 => [
      'DROP INDEX IF EXISTS idx_episodes_published;',
      'ALTER TABLE profiles DROP COLUMN latest_seen_at_ms;',
      stripV28,
    ].join('\n');

/// What v28 added, for a fixture stamped v27.
String get stripV28 =>
    ['ALTER TABLE feeds DROP COLUMN language;', stripV29].join('\n');

/// What v29 added, for a fixture stamped v28.
String get stripV29 => [
      // First: the current index's triggers name work_notes.
      _v28SearchIndex,
      'DROP TABLE IF EXISTS work_notes;',
      'ALTER TABLE works DROP COLUMN read_lang;',
      'ALTER TABLE works DROP COLUMN last_mode;',
      'ALTER TABLE works DROP COLUMN last_mode_at_ms;',
      'ALTER TABLE feeds DROP COLUMN subscribed_url;',
      'ALTER TABLE feeds DROP COLUMN notes_fill_pending;',
      stripV30,
    ].join('\n');

/// What v30 added, for a fixture stamped v29.
String get stripV30 =>
    ['ALTER TABLE episodes DROP COLUMN source_label;', stripV31].join('\n');

/// What v31 added, for a fixture stamped v30.
String get stripV31 => [
      'ALTER TABLE works DROP COLUMN translation_run_lang;',
      stripV32,
    ].join('\n');

/// What v32 added, for a fixture stamped v31.
String get stripV32 => 'ALTER TABLE works DROP COLUMN translation_view;';

/// v28's search index, verbatim: no stemming, two columns, no shows
/// table, and a show trigger with no WHEN guard. Frozen here so the v29
/// rebuild is tested against the shape a phone really carries.
const _v28SearchIndex = """
DROP TRIGGER IF EXISTS items_fts_ai;
DROP TRIGGER IF EXISTS items_fts_ad;
DROP TRIGGER IF EXISTS items_fts_au;
DROP TRIGGER IF EXISTS items_fts_episode_ai;
DROP TRIGGER IF EXISTS items_fts_episode_ad;
DROP TRIGGER IF EXISTS items_fts_feed_au;
DROP TRIGGER IF EXISTS feeds_fts_ai;
DROP TRIGGER IF EXISTS feeds_fts_ad;
DROP TRIGGER IF EXISTS segments_fts_align;
DROP TRIGGER IF EXISTS segments_fts_unalign;
DROP TRIGGER IF EXISTS segments_fts_ad;
DROP TRIGGER IF EXISTS segments_fts_au;
DROP TRIGGER IF EXISTS items_notes_ai;
DROP TRIGGER IF EXISTS items_notes_ad;
DROP TRIGGER IF EXISTS items_notes_au;
DROP TRIGGER IF EXISTS items_body_ai;
DROP TRIGGER IF EXISTS items_body_ad;
DROP TRIGGER IF EXISTS items_body_au;
DROP TABLE IF EXISTS items_fts;
DROP TABLE IF EXISTS segments_fts;
DROP TABLE IF EXISTS feeds_fts;
CREATE VIRTUAL TABLE items_fts USING fts5(title, show,
  tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3');
CREATE VIRTUAL TABLE segments_fts USING fts5(body,
  tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3');
CREATE TRIGGER items_fts_ai AFTER INSERT ON works BEGIN
  INSERT INTO items_fts(rowid, title, show) VALUES (new.id, new.title, '');
END;
CREATE TRIGGER items_fts_ad AFTER DELETE ON works BEGIN
  DELETE FROM items_fts WHERE rowid = old.id;
END;
CREATE TRIGGER items_fts_au AFTER UPDATE OF title ON works BEGIN
  UPDATE items_fts SET title = new.title WHERE rowid = old.id;
END;
CREATE TRIGGER items_fts_episode_ai AFTER INSERT ON episodes BEGIN
  UPDATE items_fts SET show = (SELECT title FROM feeds WHERE id = new.feed_id)
    WHERE rowid = new.work_id;
END;
CREATE TRIGGER items_fts_episode_ad AFTER DELETE ON episodes BEGIN
  UPDATE items_fts SET show = '' WHERE rowid = old.work_id;
END;
CREATE TRIGGER items_fts_feed_au AFTER UPDATE OF title ON feeds BEGIN
  UPDATE items_fts SET show = new.title
    WHERE rowid IN (SELECT work_id FROM episodes WHERE feed_id = new.id);
END;
CREATE TRIGGER segments_fts_align AFTER INSERT ON alignments BEGIN
  INSERT INTO segments_fts(rowid, body)
    SELECT new.work_id * 1048576 + new.segment_idx, body FROM segments
    WHERE work_id = new.work_id AND idx = new.segment_idx;
END;
CREATE TRIGGER segments_fts_unalign AFTER DELETE ON alignments BEGIN
  DELETE FROM segments_fts
    WHERE rowid = old.work_id * 1048576 + old.segment_idx;
END;
CREATE TRIGGER segments_fts_ad AFTER DELETE ON segments BEGIN
  DELETE FROM segments_fts WHERE rowid = old.work_id * 1048576 + old.idx;
END;
CREATE TRIGGER segments_fts_au AFTER UPDATE OF body ON segments BEGIN
  UPDATE segments_fts SET body = new.body
    WHERE rowid = old.work_id * 1048576 + old.idx;
END;
INSERT INTO items_fts(rowid, title, show)
  SELECT w.id, w.title, COALESCE(f.title, '') FROM works w
  LEFT JOIN episodes e ON e.work_id = w.id
  LEFT JOIN feeds f ON f.id = e.feed_id;
INSERT INTO segments_fts(rowid, body)
  SELECT s.work_id * 1048576 + s.idx, s.body FROM segments s
  JOIN alignments a ON a.work_id = s.work_id AND a.segment_idx = s.idx;
""";
