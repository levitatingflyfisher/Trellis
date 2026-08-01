// FSRS-5 scheduler tests.
//
// Source for the algorithm under test: the open-spaced-repetition project's
// published FSRS-5 specification —
// https://github.com/open-spaced-repetition/awesome-fsrs/wiki/The-Algorithm
// (retrievability constants and default weights cross-checked against
// https://borretti.me/article/implementing-fsrs-in-100-lines, which quotes
// the identical 19-value default weight vector). See fsrs_scheduler.dart's
// doc comments for the full citation and the self-consistency check
// (R(t=S, S) == 0.9 exactly, by definition of stability) that verified the
// constants across two independent secondary sources.
//
// This scheduler is *additive*: it does not touch models.dart or
// sm2_scheduler.dart. FsrsCardState is a standalone type, not a change to
// the sealed CardState.

import 'dart:convert';
import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:study_core/src/models.dart';
import 'package:study_core/src/fsrs_scheduler.dart';

/// A fresh, never-reviewed FSRS card for item [id], due today.
FsrsCardState newFsrsCard(String id, int today) =>
    FsrsCardState.initial(id, today);

void main() {
  const today = 20000;

  group('fsrsRetrievability — the forgetting curve', () {
    test('R(0, S) == 1 for any positive stability (no time has passed)', () {
      expect(fsrsRetrievability(0, 5), closeTo(1.0, 1e-9));
      expect(fsrsRetrievability(0, 500), closeTo(1.0, 1e-9));
    });

    test('R(S, S) == 0.9 — the defining property of stability', () {
      for (final s in [1.0, 5.0, 30.0, 365.0]) {
        expect(fsrsRetrievability(s, s), closeTo(0.9, 1e-9),
            reason: 'stability is defined as the elapsed time at which '
                'retrievability has dropped to exactly 90%');
      }
    });

    test('retrievability decreases monotonically with elapsed time', () {
      final r0 = fsrsRetrievability(1, 10);
      final r1 = fsrsRetrievability(5, 10);
      final r2 = fsrsRetrievability(20, 10);
      expect(r0, greaterThan(r1));
      expect(r1, greaterThan(r2));
    });
  });

  group('fsrsInitialStability / fsrsInitialDifficulty — first review', () {
    test('initial stability is w[grade-1] for each grade', () {
      expect(fsrsInitialStability(Grade.again), kFsrsDefaultWeights[0]);
      expect(fsrsInitialStability(Grade.hard), kFsrsDefaultWeights[1]);
      expect(fsrsInitialStability(Grade.good), kFsrsDefaultWeights[2]);
      expect(fsrsInitialStability(Grade.easy), kFsrsDefaultWeights[3]);
    });

    test('initial difficulty follows D0(G) = w4 - e^(w5*(G-1)) + 1, clamped',
        () {
      final w = kFsrsDefaultWeights;
      final expectedGood = w[4] - math.exp(w[5] * 2) + 1;
      expect(fsrsInitialDifficulty(Grade.good), closeTo(expectedGood, 1e-9));
    });

    test('initial difficulty is clamped to [1, 10]', () {
      for (final g in Grade.values) {
        expect(fsrsInitialDifficulty(g), inInclusiveRange(1.0, 10.0));
      }
    });

    test('a harder first grade produces a higher initial difficulty', () {
      expect(fsrsInitialDifficulty(Grade.again),
          greaterThan(fsrsInitialDifficulty(Grade.hard)));
      expect(fsrsInitialDifficulty(Grade.hard),
          greaterThan(fsrsInitialDifficulty(Grade.good)));
      expect(fsrsInitialDifficulty(Grade.good),
          greaterThan(fsrsInitialDifficulty(Grade.easy)));
    });
  });

  group('scheduleFsrs — pure function, same shape as scheduleSm2', () {
    test('a brand-new card graded good seeds stability/difficulty and '
        'schedules a due day strictly in the future', () {
      final s = scheduleFsrs(newFsrsCard('a', today), Grade.good, today);
      expect(s.itemId, 'a');
      expect(s.stability, closeTo(kFsrsDefaultWeights[2], 1e-9));
      expect(s.reps, 1);
      expect(s.lapses, 0);
      expect(s.dueEpochDay, greaterThan(today));
      expect(s.lastReviewEpochDay, today);
    });

    test('determinism: identical inputs produce identical outputs', () {
      final a = scheduleFsrs(newFsrsCard('a', today), Grade.good, today);
      final b = scheduleFsrs(newFsrsCard('a', today), Grade.good, today);
      expect(a, equals(b));
    });

    test('monotonicity under repeated Good: stability and the resulting '
        'interval both grow with each successive successful review', () {
      var state = newFsrsCard('a', today);
      var day = today;
      int? prevInterval;
      double prevStability = 0;
      for (var i = 0; i < 6; i++) {
        final next = scheduleFsrs(state, Grade.good, day);
        final interval = next.dueEpochDay - day;
        if (i > 0) {
          expect(next.stability, greaterThan(prevStability),
              reason: 'review #$i should grow stability over #${i - 1}');
          expect(interval, greaterThanOrEqualTo(prevInterval!),
              reason: 'review #$i interval should not shrink vs #${i - 1}');
        }
        prevInterval = interval;
        prevStability = next.stability;
        day = next.dueEpochDay;
        state = next;
      }
    });

    test('a lapse (Again) shrinks stability relative to the pre-lapse value',
        () {
      // Build up some stability with a couple of Good reviews first.
      var state = newFsrsCard('a', today);
      state = scheduleFsrs(state, Grade.good, today);
      state = scheduleFsrs(state, Grade.good, state.dueEpochDay);
      final preLapseStability = state.stability;

      final lapsed = scheduleFsrs(state, Grade.again, state.dueEpochDay);
      expect(lapsed.stability, lessThan(preLapseStability));
      expect(lapsed.lapses, state.lapses + 1);
    });

    test('a lapse never grows stability above its pre-lapse value even for '
        'an already-tiny stability (min-with-S clamp)', () {
      final tiny = FsrsCardState(
        itemId: 'a',
        stability: 0.05,
        difficulty: 8,
        dueEpochDay: today,
        reps: 3,
        lapses: 0,
        lastReviewEpochDay: today - 1,
      );
      final lapsed = scheduleFsrs(tiny, Grade.again, today);
      expect(lapsed.stability, lessThanOrEqualTo(tiny.stability));
    });

    test('interval growth is bounded even for an extreme stability', () {
      final huge = FsrsCardState(
        itemId: 'a',
        stability: 1e12,
        difficulty: 1,
        dueEpochDay: today,
        reps: 10,
        lastReviewEpochDay: today - 5,
        lapses: 0,
      );
      final next = scheduleFsrs(huge, Grade.easy, today);
      final interval = next.dueEpochDay - today;
      expect(interval, lessThanOrEqualTo(kFsrsMaxIntervalDays));
    });

    test('difficulty stays within [1, 10] across many reviews', () {
      var state = newFsrsCard('a', today);
      var day = today;
      for (var i = 0; i < 20; i++) {
        final grade = i.isEven ? Grade.again : Grade.easy;
        state = scheduleFsrs(state, grade, day);
        expect(state.difficulty, inInclusiveRange(1.0, 10.0));
        day = state.dueEpochDay;
      }
    });

    test('a same-day repeat review (elapsed 0) does not throw or produce '
        'NaN — the day-granularity simplification degrades gracefully '
        '(FSRS-5\'s same-day/short-term formula, w17/w18, is out of scope '
        'for a day-granularity scheduler; see fsrs_scheduler.dart doc)', () {
      final state = scheduleFsrs(newFsrsCard('a', today), Grade.good, today);
      // Re-grade on the same day the card was last reviewed: elapsed == 0.
      final sameDay = state.copyWith(lastReviewEpochDay: state.dueEpochDay);
      final result =
          scheduleFsrs(sameDay, Grade.good, sameDay.lastReviewEpochDay!);
      expect(result.stability.isNaN, isFalse);
      expect(result.stability.isFinite, isTrue);
    });
  });

  group('FsrsCardState JSON — additive persistence', () {
    test('toJson / fromJson round-trips every field', () {
      const state = FsrsCardState(
        itemId: 'x',
        stability: 12.5,
        difficulty: 4.75,
        dueEpochDay: 20100,
        reps: 3,
        lapses: 1,
        lastReviewEpochDay: 20090,
      );
      final decoded =
          FsrsCardState.fromJson('x', jsonDecode(jsonEncode(state.toJson())));
      expect(decoded, equals(state));
    });

    test('a missing lastReviewEpochDay decodes as null, not a throw', () {
      final json = {
        'stability': 1.0,
        'difficulty': 5.0,
        'dueEpochDay': today,
        'reps': 0,
        'lapses': 0,
      };
      final decoded = FsrsCardState.fromJson('x', json);
      expect(decoded.lastReviewEpochDay, isNull);
    });
  });

  group('seedFsrsFromClassic — switching Classic -> FSRS', () {
    test('stability seeds from the classic interval (SM-2\'s own estimate '
        'of the forget horizon)', () {
      final classic = CardState(
        itemId: 'a',
        ease: 2.5,
        intervalDays: 14,
        dueEpochDay: today + 14,
        reps: 3,
        lapses: 0,
      );
      final seeded = seedFsrsFromClassic(classic, today);
      expect(seeded.stability, closeTo(14, 1e-9));
      expect(seeded.itemId, 'a');
      expect(seeded.reps, 3);
      expect(seeded.lapses, 0);
    });

    test('a brand-new classic card (interval 0) seeds a small positive '
        'stability, never zero (FSRS cannot divide by a zero stability)',
        () {
      final classic = CardState(
        itemId: 'a',
        ease: 2.5,
        intervalDays: 0,
        dueEpochDay: today,
        reps: 0,
        lapses: 0,
      );
      final seeded = seedFsrsFromClassic(classic, today);
      expect(seeded.stability, greaterThan(0));
    });

    test('difficulty is a monotone decreasing function of ease: a higher '
        'ease (easier card) seeds a lower or equal difficulty', () {
      final low = CardState(
          itemId: 'a', ease: 1.3, intervalDays: 5, dueEpochDay: today, reps: 1, lapses: 0);
      final mid = CardState(
          itemId: 'a', ease: 2.5, intervalDays: 5, dueEpochDay: today, reps: 1, lapses: 0);
      final high = CardState(
          itemId: 'a', ease: 3.5, intervalDays: 5, dueEpochDay: today, reps: 1, lapses: 0);
      final dLow = seedFsrsFromClassic(low, today).difficulty;
      final dMid = seedFsrsFromClassic(mid, today).difficulty;
      final dHigh = seedFsrsFromClassic(high, today).difficulty;
      expect(dLow, greaterThan(dMid));
      expect(dMid, greaterThan(dHigh));
    });

    test('seeded difficulty is clamped to [1, 10]', () {
      final extreme = CardState(
          itemId: 'a', ease: 10.0, intervalDays: 5, dueEpochDay: today, reps: 1, lapses: 0);
      final seeded = seedFsrsFromClassic(extreme, today);
      expect(seeded.difficulty, inInclusiveRange(1.0, 10.0));
    });
  });
}
