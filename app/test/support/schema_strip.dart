import 'package:trellis/db/indexes.dart';

/// What v26 added, as SQL that takes it back off a file first made at the
/// current schema. Every migration fixture runs this first: SQLite refuses
/// to drop a column an index names, and a fixture that kept a v26 column
/// would hit a duplicate-column error on the v26 hop.
String get stripV26 => [
      for (final name in appIndexes.keys) 'DROP INDEX IF EXISTS $name;',
      'ALTER TABLE feeds DROP COLUMN body_hash;',
    ].join('\n');
