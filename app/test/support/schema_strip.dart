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
String get stripV28 => 'ALTER TABLE feeds DROP COLUMN language;';
