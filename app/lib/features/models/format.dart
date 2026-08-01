/// Calm formatting for bytes and time-left. The consent dialog and every
/// progress surface speak through these, so sizes and ETAs read the same
/// everywhere.
library;

String formatBytes(int bytes) {
  if (bytes < 1000) return '$bytes B';
  if (bytes < 1000000) return '${(bytes / 1000).toStringAsFixed(1)} kB';
  if (bytes < 1000000000) {
    return '${(bytes / 1000000).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1000000000).toStringAsFixed(1)} GB';
}

/// An approximation, never a stopwatch; empty when there is no honest
/// estimate yet.
String formatEta(int? etaMs) {
  if (etaMs == null) return '';
  if (etaMs < 60000) return 'under a minute left';
  final minutes = (etaMs / 60000).round();
  if (minutes < 60) return 'about $minutes min left';
  return 'about ${(etaMs / 3600000).round()} h left';
}
