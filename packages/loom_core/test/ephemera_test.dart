import 'package:test/test.dart';
import 'package:loom_core/loom_core.dart';

/// ADR-0003 law 2: ephemera decay by default; works persist; promotion
/// requires the user's hand. The sweep is pure — storage adapters execute
/// its verdict.
void main() {
  Work eph(String id, int seenDay) => Work(
      id: id,
      kind: WorkKind.episode,
      persistence: Persistence.ephemeron,
      firstSeenEpochDay: seenDay);

  group('ephemera decay', () {
    test('an ephemeron older than the retention window is swept', () {
      final verdict = sweepEphemera([eph('old', 100)], todayEpochDay: 131);
      expect(verdict, ['old']);
    });

    test('an ephemeron inside the window survives', () {
      final verdict = sweepEphemera([eph('fresh', 110)], todayEpochDay: 131);
      expect(verdict, isEmpty);
    });

    test('the boundary day survives; one past it does not', () {
      // retention 30: day 100 + 30 = 130 is the last kept day.
      expect(sweepEphemera([eph('edge', 100)], todayEpochDay: 130), isEmpty);
      expect(sweepEphemera([eph('edge', 100)], todayEpochDay: 131), ['edge']);
    });

    test('a promoted work is NEVER swept, at any age', () {
      final promoted = eph('kept', 0).promote();
      expect(promoted.persistence, Persistence.work);
      expect(sweepEphemera([promoted], todayEpochDay: 10000), isEmpty);
    });

    test('promotion is idempotent and does not touch identity', () {
      final w = eph('id1', 5).promote().promote();
      expect(w.id, 'id1');
      expect(w.persistence, Persistence.work);
    });

    test('a custom retention window is honored', () {
      expect(sweepEphemera([eph('e', 100)], todayEpochDay: 108, retentionDays: 7),
          ['e']);
      expect(sweepEphemera([eph('e', 100)], todayEpochDay: 107, retentionDays: 7),
          isEmpty);
    });
  });
}
