/// The full-text index behind search (ADR-0016 section 4): FTS5 tables
/// kept in step with their source rows by triggers.
///
/// Each index stores its own copy of the text rather than pointing at the
/// source table: `segments` has no INTEGER PRIMARY KEY, so its rowids can
/// move under VACUUM, and a copy is what lets `snippet()` work at all.
/// Only transcript sentences (segments with an alignment) go to
/// `segments_fts`, since a book's whole body would double its storage for
/// a search the brief never asked for.
///
/// Every table stems (porter) and folds case and accents, so "machines"
/// finds "machine" and "cafe" finds "Café" (1.5.4).
library;

import 'dart:developer' as developer;

import 'package:drift/drift.dart';

import 'busy_retry.dart';

/// Packs a segment's composite key into one rowid. 2^20 segments per work
/// is far past any transcript (a 10 h episode is a few thousand).
const segmentRowidStride = 1048576;

const _tokenize =
    "tokenize = 'porter unicode61 remove_diacritics 2', prefix = '2 3'";

/// A feed item's own words that are neither title nor transcript: its
/// body segments (a post's text, an episode's short description). Full
/// show notes replace these once they are stored.
String _bodyOf(String workId) => '''
    (SELECT group_concat(s.body, ' ') FROM segments s
      WHERE s.work_id = $workId AND NOT EXISTS (SELECT 1 FROM alignments a
        WHERE a.work_id = s.work_id AND a.segment_idx = s.idx))''';

/// [_bodyOf], or the stored show notes when there are some. `work_notes`
/// only exists from v26's hop on, and a trigger can't name a table that
/// isn't there yet, so the v25 hop builds without it.
String _notesOf(String workId, {required bool withNotes}) => withNotes
    ? '''COALESCE((SELECT NULLIF(plain, '') FROM work_notes
          WHERE work_id = $workId), ${_bodyOf(workId)}, '')'''
    : "COALESCE(${_bodyOf(workId)}, '')";

/// Feeds are written on every refresh (validators, breaker); only a
/// renamed show reindexes. `UPDATE OF title` alone fires whenever the
/// column is in the SET list, changed or not, and 1.5.3 reindexed every
/// episode of a 118-show profile on each refresh that way: the WHEN is
/// what makes the comment true.
const _feedTitleTrigger =
    '''CREATE TRIGGER IF NOT EXISTS items_fts_feed_au AFTER UPDATE OF title ON feeds
     WHEN old.title IS NOT new.title
     BEGIN
       UPDATE items_fts SET show = new.title
         WHERE rowid IN (SELECT work_id FROM episodes WHERE feed_id = new.id);
       UPDATE feeds_fts SET title = new.title WHERE rowid = new.id;
     END''';

/// Triggers name only ids, titles and bodies. The migration fixtures drop
/// other columns from a current-schema file, and SQLite refuses to drop a
/// column a trigger mentions.
List<String> _ddl({required bool withNotes}) => [
      // One row per work: its title, its show's name and its notes (or
      // body), so "serial episode 5" finds an episode whose title says
      // "Episode 5" on a show called Serial, and a word in the title
      // beside one in the notes still finds it. Search reads the title
      // and show columns apart from the notes to section its results.
      'CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5('
          'title, show, notes, $_tokenize)',
      'CREATE VIRTUAL TABLE IF NOT EXISTS segments_fts USING fts5('
          'body, $_tokenize)',
      // Followed shows by name, so a show with no items is findable and
      // its name matches the way every other word does.
      'CREATE VIRTUAL TABLE IF NOT EXISTS feeds_fts USING fts5('
          'title, $_tokenize)',
      '''CREATE TRIGGER IF NOT EXISTS items_fts_ai AFTER INSERT ON works BEGIN
       INSERT INTO items_fts(rowid, title, show, notes)
         VALUES (new.id, new.title, '', '');
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
      // A work is inserted before its episode row, and ingest writes its
      // segments in between, so the show and the body arrive here.
      '''CREATE TRIGGER IF NOT EXISTS items_fts_episode_ai AFTER INSERT ON episodes
     BEGIN
       UPDATE items_fts
         SET show = COALESCE((SELECT title FROM feeds WHERE id = new.feed_id), ''),
             notes = ${_notesOf('new.work_id', withNotes: withNotes)}
         WHERE rowid = new.work_id;
     END''',
      // A promoted work outlives its unfollowed feed's episode row, and
      // keeps its notes.
      '''CREATE TRIGGER IF NOT EXISTS items_fts_episode_ad AFTER DELETE ON episodes
     BEGIN
       UPDATE items_fts SET show = '' WHERE rowid = old.work_id;
     END''',
      _feedTitleTrigger,
      '''CREATE TRIGGER IF NOT EXISTS feeds_fts_ai AFTER INSERT ON feeds BEGIN
       INSERT INTO feeds_fts(rowid, title) VALUES (new.id, new.title);
     END''',
      '''CREATE TRIGGER IF NOT EXISTS feeds_fts_ad AFTER DELETE ON feeds BEGIN
       DELETE FROM feeds_fts WHERE rowid = old.id;
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
      // A post's text is its notes: when its segments change (a full
      // article replacing a feed's excerpt), so does what is searched.
      // Only a text item's: an episode's segments are its description,
      // then its transcript, which `segments_fts` holds.
      for (final (name, event, row) in const [
        ('items_body_ai', 'INSERT', 'new'),
        ('items_body_ad', 'DELETE', 'old'),
        ('items_body_au', 'UPDATE OF body', 'new'),
      ])
        '''CREATE TRIGGER IF NOT EXISTS $name AFTER $event ON segments
       WHEN EXISTS (SELECT 1 FROM episodes
         WHERE work_id = $row.work_id AND enclosure_url IS NULL)
       BEGIN
         UPDATE items_fts
           SET notes = ${_notesOf('$row.work_id', withNotes: withNotes)}
           WHERE rowid = $row.work_id;
       END''',
      if (withNotes) ...[
        // A note cleaned down to nothing keeps the body in its place.
        '''CREATE TRIGGER IF NOT EXISTS items_notes_ai AFTER INSERT ON work_notes
       WHEN new.plain <> ''
       BEGIN
         UPDATE items_fts SET notes = new.plain WHERE rowid = new.work_id;
       END''',
        '''CREATE TRIGGER IF NOT EXISTS items_notes_ad AFTER DELETE ON work_notes
       BEGIN
         UPDATE items_fts SET notes = COALESCE(${_bodyOf('old.work_id')}, '')
           WHERE rowid = old.work_id;
       END''',
        '''CREATE TRIGGER IF NOT EXISTS items_notes_au AFTER UPDATE OF plain
       ON work_notes BEGIN
         UPDATE items_fts
           SET notes = ${_notesOf('new.work_id', withNotes: true)}
           WHERE rowid = new.work_id;
       END''',
      ],
    ];

/// The items row of every work in `w`, as a SELECT for an INSERT into
/// `items_fts`; [range] narrows it to a batch.
String _itemsRows({required bool withNotes, String range = ''}) => '''
       SELECT w.id, w.title, COALESCE(f.title, ''),
         CASE WHEN e.work_id IS NULL THEN ''
           ELSE ${_notesOf('w.id', withNotes: withNotes)} END
       FROM works w
       LEFT JOIN episodes e ON e.work_id = w.id
       LEFT JOIN feeds f ON f.id = e.feed_id
       ${range.isEmpty ? '' : 'WHERE $range'}''';

/// Every transcript sentence, as a SELECT for `segments_fts`.
String _segmentRows([String range = '']) => '''
       SELECT s.work_id * $segmentRowidStride + s.idx, s.body
       FROM segments s
       JOIN alignments a ON a.work_id = s.work_id AND a.segment_idx = s.idx
       ${range.isEmpty ? '' : 'WHERE $range'}''';

/// Clearing first makes the backfill safe to run over an index that a
/// current-schema file already carries (every migration fixture).
List<String> _backfill({required bool withNotes}) => [
      'DELETE FROM items_fts',
      'INSERT INTO items_fts(rowid, title, show, notes) '
          '${_itemsRows(withNotes: withNotes)}',
      'DELETE FROM segments_fts',
      'INSERT INTO segments_fts(rowid, body) ${_segmentRows()}',
      ..._feedsBackfill,
    ];

/// Followed shows: tens or hundreds of rows, cheap enough for any hop.
const _feedsBackfill = [
  'DELETE FROM feeds_fts',
  'INSERT INTO feeds_fts(rowid, title) SELECT id, title FROM feeds',
];

/// Where a deferred backfill has reached: the last work id indexed, and
/// the last one it has to index (the largest when the index was rebuilt;
/// every later work is indexed by the triggers as it is written). Both
/// absent once it is done, or when there never was one.
const searchBackfillAfterKey = 'search_backfill_after';
const searchBackfillThroughKey = 'search_backfill_through';

/// Why the last fill stopped, when it stopped on an error rather than a
/// lost lock; cleared when a launch tries again.
const searchBackfillErrorKey = 'search_backfill_error';

Future<bool> _hasTable(GeneratedDatabase db, String name) async => (await db
        .customSelect("SELECT 1 FROM sqlite_master "
            "WHERE type = 'table' AND name = ?",
            variables: [Variable.withString(name)])
        .get())
    .isNotEmpty;

Future<String?> _setting(GeneratedDatabase db, String key) async {
  final rows = await db.customSelect(
      'SELECT value FROM device_settings WHERE key = ?',
      variables: [Variable.withString(key)]).get();
  return rows.isEmpty ? null : rows.single.read<String>('value');
}

Future<void> _setSetting(GeneratedDatabase db, String key, String value) =>
    db.customStatement(
        'INSERT INTO device_settings(key, value) VALUES (?, ?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        [key, value]);

Future<void> _clearSetting(GeneratedDatabase db, String key) => db
    .customStatement('DELETE FROM device_settings WHERE key = ?', [key]);

/// Whether a pending fill stopped on an error this launch.
Future<bool> searchBackfillStalled(GeneratedDatabase db) async =>
    await _hasTable(db, 'device_settings') &&
    await _setting(db, searchBackfillErrorKey) != null;

Future<void> _clearBackfill(GeneratedDatabase db) async {
  if (!await _hasTable(db, 'device_settings')) return;
  await db.customStatement(
      'DELETE FROM device_settings WHERE key IN (?, ?, ?)',
      [searchBackfillAfterKey, searchBackfillThroughKey, searchBackfillErrorKey]);
}

/// Every trigger any version installed, so a rebuild leaves none of an
/// older shape behind (`IF NOT EXISTS` would keep it).
const _triggers = [
  'items_fts_ai', 'items_fts_ad', 'items_fts_au', 'items_fts_episode_ai',
  'items_fts_episode_ad', 'items_fts_feed_au', 'feeds_fts_ai',
  'feeds_fts_ad', 'segments_fts_align', 'segments_fts_unalign',
  'segments_fts_ad', 'segments_fts_au', 'items_notes_ai', 'items_notes_ad',
  'items_notes_au', 'items_body_ai', 'items_body_ad', 'items_body_au',
  // 1.5.4 before the rebuild: show notes had a table of their own.
  'notes_fts_ai', 'notes_fts_ad', 'notes_fts_au',
];

const _tables = ['notes_fts', 'items_fts', 'segments_fts', 'feeds_fts'];

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

/// Creates (if missing) and fills the whole index at once: a new file,
/// or a restore, which has its own progress. A no-op without FTS5.
/// Show notes join it once their table exists. Ends any pending
/// deferred backfill, since nothing is left for it to do.
Future<void> installSearchIndex(GeneratedDatabase db) async {
  if (!await hasFts5(db)) return;
  final withNotes = await _hasTable(db, 'work_notes');
  for (final s in _ddl(withNotes: withNotes)) {
    await db.customStatement(s);
  }
  for (final s in _backfill(withNotes: withNotes)) {
    await db.customStatement(s);
  }
  await _clearBackfill(db);
}

/// Drops every index table and trigger, then builds the current shape
/// empty, for [SearchBackfill] to fill after the first frame: at 20k
/// works the fill is seconds of work, and inside a migration that is a
/// launch logo that never moves (1.4.0). For a file whose index is an
/// older shape (the v29 hop: a new tokenizer, notes in the items table);
/// triggers go first, since one naming a dropped table fails the next
/// write to its own table.
Future<void> rebuildSearchIndex(GeneratedDatabase db) async {
  if (!await hasFts5(db)) return;
  for (final t in _triggers) {
    await db.customStatement('DROP TRIGGER IF EXISTS $t');
  }
  for (final t in _tables) {
    await db.customStatement('DROP TABLE IF EXISTS $t');
  }
  final withNotes = await _hasTable(db, 'work_notes');
  for (final s in _ddl(withNotes: withNotes)) {
    await db.customStatement(s);
  }
  for (final s in _feedsBackfill) {
    await db.customStatement(s);
  }
  final last = (await db
          .customSelect('SELECT COALESCE(MAX(id), 0) AS n FROM works')
          .getSingle())
      .read<int>('n');
  // device_settings arrives in the v21 hop; an older file's v25 rebuild
  // fills in full, as there is nowhere to keep a place.
  if (!await _hasTable(db, 'device_settings')) {
    for (final s in _backfill(withNotes: withNotes)) {
      await db.customStatement(s);
    }
    return;
  }
  await _setSetting(db, searchBackfillAfterKey, '0');
  await _setSetting(db, searchBackfillThroughKey, '$last');
}

/// How far a deferred backfill has come, 0 to 100; null when none is
/// pending.
Future<int?> searchBackfillPercent(GeneratedDatabase db) async {
  if (!await _hasTable(db, 'device_settings')) return null;
  final after = int.tryParse(await _setting(db, searchBackfillAfterKey) ?? '');
  final through =
      int.tryParse(await _setting(db, searchBackfillThroughKey) ?? '');
  if (after == null || through == null) return null;
  final row = await db.customSelect(
      'SELECT (SELECT count(*) FROM works WHERE id <= ?) AS done, '
      '(SELECT count(*) FROM works WHERE id <= ?) AS total',
      variables: [Variable.withInt(after), Variable.withInt(through)]).getSingle();
  final total = row.read<int>('total');
  return total == 0 ? 100 : row.read<int>('done') * 100 ~/ total;
}

/// Fills the index the v29 hop left empty, [batch] works per
/// transaction, once the app may write (ADR-0018: after any background
/// check has handed over). Each batch writes its rows and its place
/// together, so a kill resumes at the next batch. It clears and refills
/// its own range, so a sentence a trigger indexed meanwhile is never
/// doubled; works written since the rebuild are past its range and the
/// triggers index them.
class SearchBackfill {
  final GeneratedDatabase db;
  final int batch;

  /// How long one batch retries a lost lock before [run] backs off.
  final Duration busyBudget;
  final Duration firstBackoff;
  bool _stopped = false;

  SearchBackfill(this.db,
      {this.batch = 500,
      this.busyBudget = const Duration(seconds: 10),
      this.firstBackoff = const Duration(seconds: 1)});

  /// Indexes the next batch. False once nothing is left (and the place is
  /// cleared), or when no backfill is pending.
  Future<bool> step() => retryWhileBusy(budget: busyBudget, _step);

  Future<bool> _step() => db.transaction(() async {
        // The write lock first, as ingest takes it: a transaction that
        // read before writing can't take the lock once another
        // connection has committed since (SQLITE_BUSY_SNAPSHOT), and no
        // retry inside it helps.
        await db.customStatement(
            'UPDATE device_settings SET value = value WHERE key = ?',
            [searchBackfillAfterKey]);
        // A batch that lands answers the last launch's failure. Inside
        // the transaction, not before it: a lone write that lost the lock
        // left its statement open on the measured host, and every later
        // commit failed with "SQL statements in progress".
        await _clearSetting(db, searchBackfillErrorKey);
        final after =
            int.tryParse(await _setting(db, searchBackfillAfterKey) ?? '');
        final through =
            int.tryParse(await _setting(db, searchBackfillThroughKey) ?? '');
        if (after == null || through == null) return false;
        final ids = await db.customSelect(
            'SELECT id FROM works WHERE id > ? AND id <= ? '
            'ORDER BY id LIMIT ?',
            variables: [
              Variable.withInt(after),
              Variable.withInt(through),
              Variable.withInt(batch),
            ]).get();
        if (ids.isEmpty) {
          await _clearBackfill(db);
          return false;
        }
        final hi = ids.last.read<int>('id');
        final withNotes = await _hasTable(db, 'work_notes');
        await db.customStatement(
            'DELETE FROM items_fts WHERE rowid > ? AND rowid <= ?',
            [after, hi]);
        await db.customStatement(
            'INSERT INTO items_fts(rowid, title, show, notes) '
            '${_itemsRows(withNotes: withNotes, range: 'w.id > $after AND w.id <= $hi')}');
        await db.customStatement(
            'DELETE FROM segments_fts WHERE rowid >= ? AND rowid < ?',
            [(after + 1) * segmentRowidStride, (hi + 1) * segmentRowidStride]);
        await db.customStatement('INSERT INTO segments_fts(rowid, body) '
            '${_segmentRows('s.work_id > $after AND s.work_id <= $hi')}');
        await _setSetting(db, searchBackfillAfterKey, '$hi');
        return true;
      });

  /// Waits for [after] (the hand-over), then steps until done or [stop],
  /// pausing between batches so the app's own reads and writes get their
  /// turn. A lost lock backs off and tries again, doubling up to
  /// [maxBackoff]. Any other failure is logged and recorded, so search
  /// says the update stopped instead of sitting at its percent, and the
  /// next launch tries again from the saved place.
  Future<void> run(
      {Future<void>? after,
      Duration pause = const Duration(milliseconds: 50),
      Duration maxBackoff = const Duration(seconds: 30)}) async {
    if (after != null) await after;
    if (_stopped) return;
    var backoff = firstBackoff;
    while (!_stopped) {
      try {
        if (!await step()) return;
        backoff = firstBackoff;
        await Future<void>.delayed(pause);
      } catch (e) {
        // The app going away closes the database under a running batch;
        // the place is saved and the next launch carries on.
        if (_stopped) return;
        if (isDatabaseBusy(e)) {
          await Future<void>.delayed(backoff);
          backoff = backoff * 2 > maxBackoff ? maxBackoff : backoff * 2;
          continue;
        }
        developer.log('Search index fill stopped: $e', name: 'trellis.search');
        try {
          await _setSetting(db, searchBackfillErrorKey, '$e');
        } catch (_) {
          // Nowhere to say it; the log has it.
        }
        return;
      }
    }
  }

  void stop() => _stopped = true;
}
