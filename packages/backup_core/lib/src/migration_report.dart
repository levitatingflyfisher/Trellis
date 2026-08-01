/// A tiny pure diff-report a migration hands to the UI.
///
/// Calm by design: three plain facts, no percentages, no urgency. The UI can
/// render it as "Imported N courses and M cards" plus an optional quiet list
/// of what stayed behind and why.
class MigrationReport {
  /// Rows written, per table (only tables that received rows appear).
  final Map<String, int> imported;

  /// Records that were present but not imported, per human-readable reason
  /// (duplicates, malformed entries, records past the donor's own cap).
  final Map<String, int> skipped;

  /// Whole categories deliberately left behind, as calm complete sentences
  /// (e.g. consents never travel; ML caches are regenerable).
  final List<String> dropped;

  MigrationReport({
    required Map<String, int> imported,
    required Map<String, int> skipped,
    required List<String> dropped,
  })  : imported = Map.unmodifiable(imported),
        skipped = Map.unmodifiable(skipped),
        dropped = List.unmodifiable(dropped);
}
