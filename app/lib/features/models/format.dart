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

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// `5 Aug` — no year, the river's own established date shape (Campaign 9
/// Phase 4 lifts this out of river_screen.dart's own private formatter
/// into the shared home, so the library's date subtitle reads identically
/// rather than growing a second copy).
String formatDay(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.day} ${_months[d.month - 1]}';
}

/// Same shape as [formatDay], from a day count (epoch days, UTC) rather
/// than milliseconds — [Works.firstSeenEpochDay] and its siblings store
/// days, not a timestamp, computed via UTC arithmetic (`epochDayUtcNow`).
/// Deliberately reads that day count back in UTC too, not local time:
/// converting through local [formatDay] would drift the shown date near
/// midnight in any timezone behind UTC.
String formatEpochDay(int epochDay) {
  final d = DateTime.utc(1970, 1, 1).add(Duration(days: epochDay));
  return '${d.day} ${_months[d.month - 1]}';
}

/// A wall-clock position, `mm:ss` (`h:mm:ss` past an hour) — the one
/// shared formatter for every surface that shows a raw playback position
/// (the mini bar's rehydrated-paused caption, a capture's timestamp on the
/// daily review card). Deliberately not a [Duration]-typed API: every
/// caller already has a raw millisecond int (a stored `positionMs`, a
/// player tick) and would otherwise wrap it just to unwrap it here.
String formatClock(int ms) {
  final d = Duration(milliseconds: ms);
  final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return d.inHours > 0
      ? '${d.inHours}:$minutes:$seconds'
      : '${d.inMinutes}:$seconds';
}

/// An episode's length as a listener would say it: `45 min`, `1 hr 5 min`.
/// Anything under a minute reads `1 min`, never `0 min`.
String formatLength(int ms) => _hoursMinutes((ms / 60000).round());

/// What remains of an episode, rounded up so a sliver never reads as
/// nothing: `23 min left`.
String formatTimeLeft(int ms) => '${_hoursMinutes((ms / 60000).ceil())} left';

String _hoursMinutes(int totalMinutes) {
  final m = totalMinutes < 1 ? 1 : totalMinutes;
  if (m < 60) return '$m min';
  final rest = m % 60;
  return rest == 0 ? '${m ~/ 60} hr' : '${m ~/ 60} hr $rest min';
}
