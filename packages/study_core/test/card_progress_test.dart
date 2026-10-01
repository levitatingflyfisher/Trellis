import 'package:study_core/study_core.dart';
import 'package:test/test.dart';

const _today = 20000;

CardState _classic({int interval = 10, int due = _today, int reps = 3,
        int lapses = 1, double ease = 2.5}) =>
    CardState(itemId: 'a', ease: ease, intervalDays: interval,
        dueEpochDay: due, reps: reps, lapses: lapses);

FsrsCardState _fsrs({double stability = 12, int due = _today + 12,
        int? last = _today, int reps = 4, int lapses = 2,
        double difficulty = 5}) =>
    FsrsCardState(itemId: 'a', stability: stability, difficulty: difficulty,
        dueEpochDay: due, reps: reps, lapses: lapses,
        lastReviewEpochDay: last);

void main() {
  group('cardProgress reads whichever half the card was last graded under',
      () {
    test('classic only: the SM-2 numbers, unchanged', () {
      final p = cardProgress(StudyCard(itemId: 'a', classic: _classic()));
      expect(p.started, isTrue);
      expect(p.reps, 3);
      expect(p.intervalDays, 10);
      expect(p.lapses, 1);
      expect(p.dueEpochDay, _today);
    });

    test('FSRS only: the interval it scheduled, not the classic half that '
        'was never written', () {
      final p = cardProgress(StudyCard(itemId: 'a', fsrs: _fsrs()));
      expect(p.started, isTrue);
      expect(p.reps, 4);
      expect(p.intervalDays, 12);
      expect(p.lapses, 2);
      expect(p.dueEpochDay, _today + 12);
    });

    test('FSRS with no last-review day falls back to its stability', () {
      final p = cardProgress(StudyCard(
          itemId: 'a', fsrs: _fsrs(stability: 8.6, last: null)));
      expect(p.intervalDays, 9);
    });

    test('both halves: the stamp decides, even on the same day', () {
      final both = StudyCard(itemId: 'a', classic: _classic(interval: 2),
          fsrs: _fsrs(stability: 30, due: _today + 30));
      expect(
          cardProgress(StudyCard(itemId: 'a', classic: both.classic,
                  fsrs: both.fsrs, lastGradedBy: Scheduler.fsrs))
              .intervalDays,
          30);
      expect(
          cardProgress(StudyCard(itemId: 'a', classic: both.classic,
                  fsrs: both.fsrs, lastGradedBy: Scheduler.classic))
              .intervalDays,
          2);
    });

    test('both halves, no stamp: the later review day wins', () {
      // Classic last reviewed on due - interval = today - 8.
      final card = StudyCard(itemId: 'a',
          classic: _classic(interval: 10, due: _today + 2),
          fsrs: _fsrs(last: _today - 3, due: _today + 9));
      expect(card.lastGradedBy, Scheduler.fsrs);
      expect(cardProgress(card).dueEpochDay, _today + 9);
    });
  });

  group('the state to grade from keeps progress across a switch', () {
    test('switching to FSRS seeds from the newer classic half', () {
      final classic = _classic(interval: 14, due: _today);
      final card = StudyCard(itemId: 'a', classic: classic,
          fsrs: _fsrs(stability: 2), lastGradedBy: Scheduler.classic);
      final f = card.fsrsToGradeFrom(_today);
      expect(f.stability, closeTo(14, 1e-9));
      expect(f.lastReviewEpochDay, _today - 14,
          reason: 'the day classic last saw it, so FSRS knows how much '
              'time has passed');
    });

    test('an FSRS half that is already the newer one is graded as is', () {
      final fsrs = _fsrs();
      final card = StudyCard(itemId: 'a', classic: _classic(), fsrs: fsrs,
          lastGradedBy: Scheduler.fsrs);
      expect(card.fsrsToGradeFrom(_today), fsrs);
    });

    test('switching back to classic seeds from the newer FSRS half', () {
      final card = StudyCard(itemId: 'a', classic: _classic(interval: 1),
          fsrs: _fsrs(stability: 20, due: _today + 20),
          lastGradedBy: Scheduler.fsrs);
      final c = card.classicToGradeFrom();
      expect(c.intervalDays, 20);
      expect(c.dueEpochDay, _today + 20);
      expect(c.lapses, 2);
    });

    test('a classic half that is already the newer one is graded as is', () {
      final classic = _classic();
      final card = StudyCard(itemId: 'a', classic: classic, fsrs: _fsrs(),
          lastGradedBy: Scheduler.classic);
      expect(card.classicToGradeFrom(), classic);
    });

    test('a first FSRS Good after switching grows stability (the seed is '
        'not pretending the classic review happened today)', () {
      final card = StudyCard(itemId: 'a',
          classic: _classic(interval: 10, due: _today));
      final before = card.fsrsToGradeFrom(_today);
      final after = scheduleFsrs(before, Grade.good, _today);
      expect(after.stability, greaterThan(before.stability));
    });
  });

  group('seedClassicFromFsrs', () {
    test('interval is the FSRS scheduled interval; due, lapses kept', () {
      final c = seedClassicFromFsrs(_fsrs(stability: 12, due: _today + 12));
      expect(c.intervalDays, 12);
      expect(c.dueEpochDay, _today + 12);
      expect(c.lapses, 2);
    });

    test('a reviewed card seeds at least two reps, so SM-2 grows it by '
        'ease next rather than restarting its 1-then-6 ladder', () {
      final c = seedClassicFromFsrs(_fsrs(reps: 1));
      expect(c.reps, greaterThanOrEqualTo(2));
    });

    test('ease inverts the classic->FSRS difficulty map', () {
      for (final ease in [1.3, 1.8, 2.5]) {
        final there = seedFsrsFromClassic(_classic(ease: ease), _today);
        final back = seedClassicFromFsrs(_fsrs(difficulty: there.difficulty));
        expect(back.ease, closeTo(ease, 1e-9));
      }
    });

    test('ease never drops below SM-2\'s 1.3 floor', () {
      expect(seedClassicFromFsrs(_fsrs(difficulty: 10)).ease,
          greaterThanOrEqualTo(1.3));
    });
  });

  group('mastery needs at least two reviews', () {
    const course = Course(id: 'c', title: 'C', nodes: [
      KnowledgeNode(id: 'a', title: 'A', intake: 'i', items: [
        QaItem(id: 'a', rung: 1, prompt: 'p', answer: 'x'),
      ]),
      KnowledgeNode(id: 'b', title: 'B', intake: 'i', prereqs: ['a'], items: [
        QaItem(id: 'b', rung: 1, prompt: 'q', answer: 'y'),
      ]),
    ]);

    test('one first-ever Easy under FSRS schedules past a week but does not '
        'master the card or unlock the next node', () {
      final easy =
          scheduleFsrs(FsrsCardState.initial('a', _today), Grade.easy, _today);
      expect(easy.dueEpochDay - _today, greaterThanOrEqualTo(7));
      final progress = {'a': CardProgress.fromFsrs(easy)};
      expect(isMastered(progress['a']!), isFalse);
      expect(nodeProgress(course.nodes.first, progress, _today).mastered, 0);
      expect(nodeUnlocked(course.nodes.last, course, progress, _today),
          isFalse);
    });

    test('a second review past the threshold masters it', () {
      final p = CardProgress.fromFsrs(_fsrs(reps: 2, stability: 12));
      expect(isMastered(p), isTrue);
    });
  });

  group('a lapsed classic card seeding into FSRS', () {
    test('keeps its difficulty from ease instead of starting as brand new',
        () {
      final lapsed = _classic(interval: 0, reps: 0, lapses: 2, ease: 1.4);
      final seeded = seedFsrsFromClassic(lapsed, _today);
      expect(seeded.reps, greaterThan(0),
          reason: 'reps 0 sends scheduleFsrs down its first-review branch, '
              'which throws the seed away');
      final graded = scheduleFsrs(seeded, Grade.good, _today);
      expect(graded.difficulty,
          greaterThan(fsrsInitialDifficulty(Grade.good) + 1),
          reason: 'a hard-won card (ease near the floor) stays hard');
    });

    test('a never-reviewed classic card still starts FSRS fresh', () {
      final fresh = CardState.initial('a', const SrsDefaults(), _today);
      final graded =
          scheduleFsrs(seedFsrsFromClassic(fresh, _today), Grade.good, _today);
      expect(graded.stability, closeTo(kFsrsDefaultWeights[2], 1e-9));
    });
  });
}
