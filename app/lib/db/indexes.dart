/// The secondary indexes (ADR-0017). Before v26 the schema had none, so
/// every feed refresh, river load and work delete scanned whole tables:
/// fine at a few hundred episodes, minutes at 50k.
///
/// Raw `IF NOT EXISTS` DDL rather than drift's `@TableIndex`: the upgrade
/// path's `createTable` calls build tables without their indexes, and a
/// file first made at the current schema already carries these, so the
/// same statements run safely from `onCreate` and from the v26 hop.
library;

import 'package:drift/drift.dart';

/// Name to DDL. Names are exposed so migration fixtures can strip them
/// back off a current-schema file (SQLite refuses to drop an indexed
/// column).
const appIndexes = <String, String>{
  // The podcast page and the refresh's seen-guid load, both by feed.
  'idx_episodes_feed_published':
      'CREATE INDEX IF NOT EXISTS idx_episodes_feed_published '
          'ON episodes (feed_id, published_at_ms)',
  // One row per item per feed: what ingest's seen-set already promises,
  // now enforced where a concurrent refresh can't slip past it.
  'ux_episodes_feed_guid':
      'CREATE UNIQUE INDEX IF NOT EXISTS ux_episodes_feed_guid '
          'ON episodes (feed_id, guid)',
  // Every work delete clears suppressions pointing at it.
  'idx_episodes_duplicate_of':
      'CREATE INDEX IF NOT EXISTS idx_episodes_duplicate_of '
          'ON episodes (duplicate_of_work_id)',
  // The river, the library and the sweep all start from one profile's
  // works in one persistence.
  'idx_works_profile_persistence':
      'CREATE INDEX IF NOT EXISTS idx_works_profile_persistence '
          'ON works (profile_id, persistence)',
  // Foreign keys are checked on every parent delete; a child column with
  // no index of its own is a full scan per deleted work.
  'idx_queue_work': 'CREATE INDEX IF NOT EXISTS idx_queue_work '
      'ON queue (work_id)',
  'idx_captures_work': 'CREATE INDEX IF NOT EXISTS idx_captures_work '
      'ON captures (work_id)',
  // These two key on (profile_id, work_id), which a lookup by work alone
  // can't use.
  'idx_player_positions_work':
      'CREATE INDEX IF NOT EXISTS idx_player_positions_work '
          'ON player_positions (work_id)',
  'idx_positions_work': 'CREATE INDEX IF NOT EXISTS idx_positions_work '
      'ON positions (work_id)',
  'idx_word_ledger_source_work':
      'CREATE INDEX IF NOT EXISTS idx_word_ledger_source_work '
          'ON word_ledger (source_work_id)',
  // Revlog has no work or course column; its card is the parent.
  'idx_revlog_card': 'CREATE INDEX IF NOT EXISTS idx_revlog_card '
      'ON revlog (card_id)',
};

Future<void> installIndexes(GeneratedDatabase db) async {
  for (final ddl in appIndexes.values) {
    await db.customStatement(ddl);
  }
}
