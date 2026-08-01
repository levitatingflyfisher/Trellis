import 'package:test/test.dart';
import 'package:transcribe_core/transcribe_core.dart';

/// The design recipe (proposal-2 §9): 30s windows, 5s overlap. The plan is
/// pure arithmetic — every resume law upstream depends on it being a
/// deterministic function of totalMs alone.
void main() {
  group('defaults', () {
    test('carry the canonical recipe: 30s window, 5s overlap, 25s stride', () {
      final plan = WindowPlan();
      expect(plan.windowMs, 30000);
      expect(plan.overlapMs, 5000);
      expect(plan.strideMs, 25000);
    });

    test('reject a degenerate geometry', () {
      expect(() => WindowPlan(windowMs: 5000, overlapMs: 5000),
          throwsArgumentError);
      expect(() => WindowPlan(windowMs: 5000, overlapMs: 6000),
          throwsArgumentError);
      expect(() => WindowPlan(windowMs: 0, overlapMs: 0), throwsArgumentError);
      expect(() => WindowPlan(windowMs: 30000, overlapMs: -1),
          throwsArgumentError);
    });
  });

  group('unitCount', () {
    final plan = WindowPlan();

    test('empty audio has zero windows', () {
      expect(plan.unitCount(0), 0);
    });

    test('anything shorter than one window is one window', () {
      expect(plan.unitCount(1), 1);
      expect(plan.unitCount(4000), 1); // shorter than the overlap itself
      expect(plan.unitCount(25000), 1);
      expect(plan.unitCount(30000), 1);
    });

    test('a window opens only for audio beyond the previous overlap', () {
      // 30001ms: 1ms of audio past window 1 -> window 2 exists.
      expect(plan.unitCount(30001), 2);
      // 55000ms: window 2 = 25000..55000 covers to the end exactly.
      expect(plan.unitCount(55000), 2);
      // 55001ms: 1ms past window 2 -> window 3.
      expect(plan.unitCount(55001), 3);
      expect(plan.unitCount(60000), 3);
      // 2.5 minutes -> 6 windows (0,25,50,75,100,125 s starts).
      expect(plan.unitCount(150000), 6);
    });
  });

  group('window geometry', () {
    final plan = WindowPlan();

    test('starts advance by the stride', () {
      expect(plan.startMsOf(0), 0);
      expect(plan.startMsOf(1), 25000);
      expect(plan.startMsOf(5), 125000);
    });

    test('length is the full window except at the tail', () {
      expect(plan.lenMsOf(0, 150000), 30000);
      expect(plan.lenMsOf(4, 150000), 30000);
      expect(plan.lenMsOf(5, 150000), 25000); // 125000..150000
      expect(plan.lenMsOf(0, 12000), 12000); // short episode
    });

    test('windows tile the audio: every ms is inside some window', () {
      for (final totalMs in [1, 12000, 30000, 30001, 55000, 61234, 150000]) {
        final n = plan.unitCount(totalMs);
        // Window 0 starts at 0; each next window starts inside the previous
        // (that is what overlap means); the last window ends at totalMs.
        expect(plan.startMsOf(0), 0);
        for (var u = 1; u < n; u++) {
          expect(plan.startMsOf(u),
              lessThan(plan.startMsOf(u - 1) + plan.lenMsOf(u - 1, totalMs)));
        }
        expect(plan.startMsOf(n - 1) + plan.lenMsOf(n - 1, totalMs), totalMs);
      }
    });
  });
}
