/// Whole days since the Unix epoch (UTC) — the unit all SRS scheduling uses, so
/// behavior is timezone-stable and deterministic in tests.
int epochDayNow() =>
    DateTime.now().toUtc().millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;
