// SM-2 spaced-repetition scheduler (pure function).
//
// A deterministic, daily-granularity variant of the classic SuperMemo-2
// algorithm. All scheduling is in whole days since the Unix epoch (UTC), so the
// app is timezone-stable and the scheduler is trivially testable: same inputs
// always produce the same [CardState].
//
// The learner self-rates each recall on the four-point [Grade] scale; that
// rating maps to an SM-2 "quality" `q`:
//
//   again = 2, hard = 3, good = 4, easy = 5
//
// `q < 3` is a *lapse* (failed recall): the card is reset to relearn this
// session. `q >= 3` graduates the card and grows the interval by the ease
// factor, with `hard`/`easy` shrinking/stretching the `good` interval.

import 'package:study_core/src/models.dart';

/// The lowest an ease factor is ever allowed to fall, per SM-2.
const double _minEase = 1.3;

/// Maps a [Grade] to the SM-2 quality score `q` (0..5; we use 2..5).
int _quality(Grade grade) {
  switch (grade) {
    case Grade.again:
      return 2;
    case Grade.hard:
      return 3;
    case Grade.good:
      return 4;
    case Grade.easy:
      return 5;
  }
}

/// Advance a card's spaced-repetition state by one graded review.
///
/// Pure and deterministic: depends only on its arguments.
///
/// * [state] – the card's current SRS state.
/// * [grade] – the learner's self-rating of the recall just attempted.
/// * [todayEpochDay] – whole days since the Unix epoch (UTC) for "now".
///
/// Returns a new [CardState] (via [CardState.copyWith], so `itemId` is
/// preserved) with the updated ease, interval, due day, reps and lapses.
CardState scheduleSm2(CardState state, Grade grade, int todayEpochDay,
    {int firstIntervalDays = 1}) {
  final int q = _quality(grade);

  // Ease update (the SM-2 EF' recurrence), then clamp to the floor.
  final double rawEase =
      state.ease + (0.1 - (5 - q) * (0.08 + (5 - q) * 0.02));
  final double newEase = rawEase < _minEase ? _minEase : rawEase;

  if (q < 3) {
    // Lapse: failed recall. Reset reps, count a lapse, and make the card due
    // again immediately so it is relearned in this session.
    return state.copyWith(
      ease: newEase,
      intervalDays: 0,
      dueEpochDay: todayEpochDay,
      reps: 0,
      lapses: state.lapses + 1,
    );
  }

  // Successful recall: graduate the card.
  final int newReps = state.reps + 1;

  // The "good"-grade base interval for this repetition.
  final int base;
  if (state.reps == 0) {
    base = firstIntervalDays;
  } else if (state.reps == 1) {
    base = 6;
  } else {
    base = (state.intervalDays * newEase).round();
  }

  int newInterval;
  if (q == 3) {
    // hard: shorter than good.
    newInterval = (base * 0.6).round();
  } else if (q == 5) {
    // easy: longer than good.
    newInterval = (base * 1.3).round();
  } else {
    // good.
    newInterval = base;
  }
  // A successful recall must never bring the card back sooner than it was
  // already scheduled for. The `hard` multiplier (0.6) sits on top of
  // interval x ease, and every hard rating also drops ease by 0.14 toward the
  // 1.3 floor — so once ease fell below ~1.67 the product went under 1 and a
  // card the learner kept GETTING RIGHT started returning sooner each time:
  // 1, 4, 5, 6, 7, 7, 7, 6, 5, 4, 3, 2, 2, 2... with no way out.
  //
  // That inverted the whole model. Intervals crossing back below the mastery
  // threshold un-mastered nodes, which re-locked concepts the learner had
  // already opened and stranded the rest of the course behind a gate that
  // could no longer be passed. In SM-2 the quality rating governs how fast an
  // interval grows, never whether it grows; contraction is what a *lapse* is
  // for, and a lapse returns above without reaching this line.
  //
  // `+ 1` rather than a plain floor at the current interval: equality would
  // leave a card parked on the same interval forever (the 7-day plateau in
  // the sequence above), which stalls mastery just as effectively.
  final int floor = state.intervalDays + 1;
  if (newInterval < floor) newInterval = floor;

  return state.copyWith(
    ease: newEase,
    intervalDays: newInterval,
    dueEpochDay: todayEpochDay + newInterval,
    reps: newReps,
    lapses: state.lapses,
  );
}
