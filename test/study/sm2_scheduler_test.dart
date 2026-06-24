import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/curriculum/domain/models.dart';
import 'package:trellis/features/study/domain/sm2_scheduler.dart';

/// A fresh, never-reviewed card (reps 0) for item [id], due today.
CardState newCard(String id, int today, {double ease = 2.5}) => CardState(
      itemId: id,
      ease: ease,
      intervalDays: 0,
      dueEpochDay: today,
      reps: 0,
      lapses: 0,
    );

void main() {
  group('scheduleSm2 — brand-new card (reps 0)', () {
    const today = 20000; // explicit epoch day

    test('good -> interval 1, due today+1, reps 1', () {
      final s = scheduleSm2(newCard('a', today), Grade.good, today);
      expect(s.intervalDays, 1);
      expect(s.dueEpochDay, today + 1);
      expect(s.reps, 1);
      expect(s.lapses, 0);
      // good leaves the default ease unchanged.
      expect(s.ease, closeTo(2.5, 1e-9));
    });

    test('again -> interval 0, due today, lapses 1, ease dropped & clamped',
        () {
      final s = scheduleSm2(newCard('a', today), Grade.again, today);
      expect(s.intervalDays, 0);
      expect(s.dueEpochDay, today);
      expect(s.reps, 0);
      expect(s.lapses, 1);
      // 2.5 - 0.32 = 2.18, still well above the 1.3 floor.
      expect(s.ease, closeTo(2.18, 1e-9));
      expect(s.ease, greaterThanOrEqualTo(1.3));
    });

    test('hard -> interval 1 (max(1, round(1*0.6))), reps 1', () {
      final s = scheduleSm2(newCard('a', today), Grade.hard, today);
      // base = 1, hard => round(0.6) = 1, then max(1, ...) = 1.
      expect(s.intervalDays, 1);
      expect(s.dueEpochDay, today + 1);
      expect(s.reps, 1);
      // hard ease: 2.5 - 0.14 = 2.36.
      expect(s.ease, closeTo(2.36, 1e-9));
    });

    test('easy -> interval round(1*1.3) = 1, reps 1, ease bumped to 2.6', () {
      final s = scheduleSm2(newCard('a', today), Grade.easy, today);
      // base = 1, easy => round(1.3) = 1.
      expect(s.intervalDays, 1);
      expect(s.dueEpochDay, today + 1);
      expect(s.reps, 1);
      expect(s.ease, closeTo(2.6, 1e-9));
    });
  });

  group('scheduleSm2 — second repetition (reps == 1)', () {
    const today = 30000;

    // A card that has been answered correctly once.
    CardState afterFirst() => CardState(
          itemId: 'b',
          ease: 2.5,
          intervalDays: 1,
          dueEpochDay: today,
          reps: 1,
          lapses: 0,
        );

    test('good -> interval 6, due today+6, reps 2', () {
      final s = scheduleSm2(afterFirst(), Grade.good, today);
      expect(s.intervalDays, 6);
      expect(s.dueEpochDay, today + 6);
      expect(s.reps, 2);
      expect(s.lapses, 0);
      expect(s.ease, closeTo(2.5, 1e-9));
    });

    test('hard -> round(6*0.6) = 4', () {
      final s = scheduleSm2(afterFirst(), Grade.hard, today);
      expect(s.intervalDays, 4);
      expect(s.dueEpochDay, today + 4);
      expect(s.reps, 2);
    });

    test('easy -> round(6*1.3) = 8', () {
      final s = scheduleSm2(afterFirst(), Grade.easy, today);
      expect(s.intervalDays, 8);
      expect(s.dueEpochDay, today + 8);
      expect(s.reps, 2);
    });
  });

  group('scheduleSm2 — mature card (reps >= 2)', () {
    const today = 40000;

    // reps=2, interval=6, ease=2.5: next good interval = round(6*2.5) = 15.
    CardState mature() => CardState(
          itemId: 'c',
          ease: 2.5,
          intervalDays: 6,
          dueEpochDay: today,
          reps: 2,
          lapses: 0,
        );

    test('good -> round(interval * ease) = round(6 * 2.5) = 15', () {
      final s = scheduleSm2(mature(), Grade.good, today);
      expect(s.intervalDays, 15);
      expect(s.dueEpochDay, today + 15);
      expect(s.reps, 3);
      expect(s.lapses, 0);
      // ease unchanged on good.
      expect(s.ease, closeTo(2.5, 1e-9));
    });

    test('good interval respects the (possibly changed) ease', () {
      // ease 2.0, interval 10 => round(10 * 2.0) = 20.
      final s = scheduleSm2(
        CardState(
          itemId: 'c',
          ease: 2.0,
          intervalDays: 10,
          dueEpochDay: today,
          reps: 5,
          lapses: 0,
        ),
        Grade.good,
        today,
      );
      expect(s.intervalDays, 20);
      expect(s.dueEpochDay, today + 20);
      expect(s.reps, 6);
    });

    test('again on a mature card -> interval 0, due today, lapses++, reps 0',
        () {
      final start = mature();
      final s = scheduleSm2(start, Grade.again, today);
      expect(s.intervalDays, 0);
      expect(s.dueEpochDay, today);
      expect(s.reps, 0);
      expect(s.lapses, start.lapses + 1);
      // ease drops by 0.32 from 2.5.
      expect(s.ease, closeTo(2.18, 1e-9));
    });
  });

  group('scheduleSm2 — ordering of hard < good < easy', () {
    const today = 50000;

    // Mature base so the multipliers produce clearly distinct integers.
    // base = round(20 * 2.5) = 50.
    CardState mature() => CardState(
          itemId: 'd',
          ease: 2.5,
          intervalDays: 20,
          dueEpochDay: today,
          reps: 4,
          lapses: 0,
        );

    test('hard interval < good interval < easy interval', () {
      final hard = scheduleSm2(mature(), Grade.hard, today);
      final good = scheduleSm2(mature(), Grade.good, today);
      final easy = scheduleSm2(mature(), Grade.easy, today);

      // Interval uses the UPDATED ease (standard SM-2): base = round(20 * ef').
      // hard ef'=2.36 -> base 47 -> round(47*0.6)=28; good ef'=2.5 -> base 50;
      // easy ef'=2.6 -> base 52 -> round(52*1.3)=68.
      expect(hard.intervalDays, 28);
      expect(good.intervalDays, 50);
      expect(easy.intervalDays, 68);

      expect(hard.intervalDays, lessThan(good.intervalDays));
      expect(good.intervalDays, lessThan(easy.intervalDays));
    });

    test('easy bumps ease above good, which exceeds hard', () {
      final hard = scheduleSm2(mature(), Grade.hard, today);
      final good = scheduleSm2(mature(), Grade.good, today);
      final easy = scheduleSm2(mature(), Grade.easy, today);

      // hard: 2.36, good: 2.5, easy: 2.6.
      expect(hard.ease, lessThan(good.ease));
      expect(good.ease, lessThan(easy.ease));
      expect(hard.ease, closeTo(2.36, 1e-9));
      expect(good.ease, closeTo(2.5, 1e-9));
      expect(easy.ease, closeTo(2.6, 1e-9));
    });
  });

  group('scheduleSm2 — ease floor under repeated again', () {
    const today = 60000;

    test('ease never falls below 1.3 after many lapses', () {
      var s = newCard('e', today);
      // Each again subtracts 0.32 from the ease (until it hits the floor).
      for (var i = 0; i < 20; i++) {
        s = scheduleSm2(s, Grade.again, today);
        expect(s.ease, greaterThanOrEqualTo(1.3));
        expect(s.lapses, i + 1);
        expect(s.reps, 0);
        expect(s.intervalDays, 0);
        expect(s.dueEpochDay, today);
      }
      // It must have bottomed out exactly at the floor.
      expect(s.ease, closeTo(1.3, 1e-9));
    });

    test('a single again from minimum ease stays clamped at 1.3', () {
      final atFloor = CardState(
        itemId: 'e',
        ease: 1.3,
        intervalDays: 0,
        dueEpochDay: today,
        reps: 0,
        lapses: 3,
      );
      final s = scheduleSm2(atFloor, Grade.again, today);
      // 1.3 - 0.32 would be 0.98; must clamp to 1.3.
      expect(s.ease, closeTo(1.3, 1e-9));
      expect(s.lapses, 4);
    });

    test('hard near the floor also clamps to 1.3', () {
      final low = CardState(
        itemId: 'e',
        ease: 1.4,
        intervalDays: 6,
        dueEpochDay: today,
        reps: 2,
        lapses: 0,
      );
      // hard ease = 1.4 - 0.14 = 1.26 -> clamps to 1.3.
      final s = scheduleSm2(low, Grade.hard, today);
      expect(s.ease, closeTo(1.3, 1e-9));
    });
  });

  group('scheduleSm2 — invariants', () {
    const today = 70000;

    test('itemId is preserved across every grade', () {
      for (final g in Grade.values) {
        final s = scheduleSm2(newCard('preserve-me', today), g, today);
        expect(s.itemId, 'preserve-me');
      }
    });

    test('successful grades always yield interval >= 1 and a future due day',
        () {
      for (final g in [Grade.hard, Grade.good, Grade.easy]) {
        final s = scheduleSm2(newCard('f', today), g, today);
        expect(s.intervalDays, greaterThanOrEqualTo(1));
        expect(s.dueEpochDay, greaterThan(today));
        expect(s.dueEpochDay, today + s.intervalDays);
      }
    });

    test('the function is deterministic / pure for identical inputs', () {
      final a = scheduleSm2(newCard('g', today), Grade.good, today);
      final b = scheduleSm2(newCard('g', today), Grade.good, today);
      expect(a.itemId, b.itemId);
      expect(a.ease, b.ease);
      expect(a.intervalDays, b.intervalDays);
      expect(a.dueEpochDay, b.dueEpochDay);
      expect(a.reps, b.reps);
      expect(a.lapses, b.lapses);
    });

    test('different todayEpochDay values shift the due day accordingly', () {
      const dayA = 100;
      const dayB = 99999;
      final a = scheduleSm2(newCard('h', dayA), Grade.good, dayA);
      final b = scheduleSm2(newCard('h', dayB), Grade.good, dayB);
      expect(a.intervalDays, b.intervalDays);
      expect(a.dueEpochDay, dayA + a.intervalDays);
      expect(b.dueEpochDay, dayB + b.intervalDays);
    });

    test('the input state is not mutated', () {
      final start = newCard('i', today);
      scheduleSm2(start, Grade.easy, today);
      expect(start.ease, 2.5);
      expect(start.intervalDays, 0);
      expect(start.dueEpochDay, today);
      expect(start.reps, 0);
      expect(start.lapses, 0);
    });
  });
}
