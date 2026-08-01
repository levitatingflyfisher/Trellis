import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/models/format.dart';

void main() {
  group('formatBytes', () {
    test('honest units at each magnitude', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(999), '999 B');
      expect(formatBytes(43537433), '43.5 MB');
      expect(formatBytes(2327524), '2.3 MB');
      expect(formatBytes(546660344), '546.7 MB');
      expect(formatBytes(81768585), '81.8 MB');
      expect(formatBytes(1536), '1.5 kB');
      expect(formatBytes(1200000000), '1.2 GB');
    });
  });

  group('formatEta', () {
    test('speaks in calm approximations, never a stopwatch', () {
      expect(formatEta(null), '');
      expect(formatEta(20000), 'under a minute left');
      expect(formatEta(90000), 'about 2 min left');
      expect(formatEta(60000 * 59), 'about 59 min left');
      expect(formatEta(3600000 * 2 + 60000), 'about 2 h left');
    });
  });

  group('formatClock', () {
    test('mm:ss under an hour, no leading zero on minutes', () {
      expect(formatClock(0), '0:00');
      expect(formatClock(754000), '12:34');
      expect(formatClock(59000), '0:59');
    });

    test('h:mm:ss once it crosses an hour', () {
      expect(formatClock(3661000), '1:01:01');
      expect(formatClock(3600000), '1:00:00');
    });
  });

  group('formatDay / formatEpochDay', () {
    // Local time, matching formatDay's own DateTime.fromMillisecondsSinceEpoch
    // (unconverted from UTC) — the exact behavior river_screen.dart's own
    // precedent already had; lifting it into a shared function preserves
    // it rather than silently changing what either surface shows.
    test('formatDay names the day and month, no year (river\'s own '
        'precedent)', () {
      expect(
          formatDay(DateTime(2026, 8, 5).millisecondsSinceEpoch), '5 Aug');
      expect(
          formatDay(DateTime(2026, 1, 1).millisecondsSinceEpoch), '1 Jan');
    });

    test('formatEpochDay reads the day count as a UTC calendar day, the '
        'same arithmetic epochDayUtcNow uses to WRITE it — a local-time '
        'reinterpretation would drift the date near midnight in any '
        'timezone behind UTC', () {
      final epochDay =
          DateTime.utc(2026, 8, 5).millisecondsSinceEpoch ~/
              Duration.millisecondsPerDay;
      expect(formatEpochDay(epochDay), '5 Aug');
    });
  });
}
