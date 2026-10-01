// One card's progress, whichever scheduler graded it.
//
// A card's stored state has two halves: SM-2's [CardState] and FSRS's
// [FsrsCardState]. A grade writes only the half of the scheduler that made
// it, so a learner who switches schedulers leaves the other half frozen at
// its last review. Anything that asks "how far along is this card?" (unlock
// gates, mastery, due counts) must read the half that was graded last, never
// a fixed one: reading only SM-2's half made every FSRS-graded card look
// unstarted, and a course on FSRS never unlocked past its first nodes.
//
// ## Switching keeps progress
//
// Grading under a scheduler whose half is missing or stale seeds that half
// from the newer one, so a switch in either direction carries the learner's
// progress over:
//
// * SM-2 -> FSRS: [seedFsrsFromClassic] (stability := interval).
// * FSRS -> SM-2: [seedClassicFromFsrs] (interval := the interval FSRS
//   scheduled, which at the default 0.9 retention is its stability rounded;
//   ease := the inverse of the classic->FSRS difficulty map).
//
// Neither direction is a published conversion; both treat "days until this
// is due again" as the one quantity the two models agree on.

import 'dart:math' as math;

import 'package:study_core/src/fsrs_scheduler.dart';
import 'package:study_core/src/models.dart';

/// The two schedulers a profile can pick. The names are the stored setting.
enum Scheduler { classic, fsrs }

/// What every progress reader needs, in the same units for both schedulers.
class CardProgress {
  const CardProgress({
    required this.started,
    required this.reps,
    required this.intervalDays,
    required this.lapses,
    required this.dueEpochDay,
  });

  final bool started;
  final int reps;

  /// Days from the last review to the next: SM-2's interval, or the
  /// interval FSRS scheduled. Mastery compares this against its threshold.
  final int intervalDays;
  final int lapses;
  final int dueEpochDay;

  bool isDue(int todayEpochDay) => dueEpochDay <= todayEpochDay;

  factory CardProgress.fromClassic(CardState c) => CardProgress(
        started: true,
        reps: c.reps,
        intervalDays: c.intervalDays,
        lapses: c.lapses,
        dueEpochDay: c.dueEpochDay,
      );

  factory CardProgress.fromFsrs(FsrsCardState f) => CardProgress(
        started: true,
        reps: f.reps,
        intervalDays: _fsrsScheduledInterval(f),
        lapses: f.lapses,
        dueEpochDay: f.dueEpochDay,
      );
}

int _fsrsScheduledInterval(FsrsCardState f) {
  final last = f.lastReviewEpochDay;
  if (last == null) return f.stability.round();
  return math.max(0, f.dueEpochDay - last);
}

/// The day SM-2 last reviewed [c]: its interval was counted from there.
int _classicLastReview(CardState c) => c.dueEpochDay - c.intervalDays;

/// A stored card: one or both halves, and which scheduler graded it last.
class StudyCard {
  StudyCard({
    required this.itemId,
    this.classic,
    this.fsrs,
    Scheduler? lastGradedBy,
  })  : assert(classic != null || fsrs != null, 'a card has some state'),
        lastGradedBy = _resolveNewer(classic, fsrs, lastGradedBy);

  final String itemId;
  final CardState? classic;
  final FsrsCardState? fsrs;

  /// Always the scheduler whose half is present and newest. A stamp naming
  /// a half the card doesn't have is ignored; without a stamp, two halves
  /// compare by the day each was last reviewed (classic on a tie).
  final Scheduler lastGradedBy;

  static Scheduler _resolveNewer(
      CardState? classic, FsrsCardState? fsrs, Scheduler? stamp) {
    if (fsrs == null) return Scheduler.classic;
    if (classic == null) return Scheduler.fsrs;
    if (stamp != null) return stamp;
    final fsrsLast = fsrs.lastReviewEpochDay;
    if (fsrsLast != null && fsrsLast > _classicLastReview(classic)) {
      return Scheduler.fsrs;
    }
    return Scheduler.classic;
  }

  CardProgress get progress => cardProgress(this);

  /// The SM-2 state a classic grade should start from: the classic half if
  /// it is the newer one, else a seed from the FSRS half.
  CardState classicToGradeFrom() {
    final c = classic;
    if (c != null && lastGradedBy == Scheduler.classic) return c;
    return seedClassicFromFsrs(fsrs!);
  }

  /// The FSRS state an FSRS grade should start from: the FSRS half if it is
  /// the newer one, else a seed from the classic half.
  FsrsCardState fsrsToGradeFrom(int todayEpochDay) {
    final f = fsrs;
    if (f != null && lastGradedBy == Scheduler.fsrs) return f;
    return seedFsrsFromClassic(classic!, todayEpochDay);
  }
}

/// The scheduler-neutral view every progress reader goes through.
CardProgress cardProgress(StudyCard card) =>
    card.lastGradedBy == Scheduler.fsrs
        ? CardProgress.fromFsrs(card.fsrs!)
        : CardProgress.fromClassic(card.classic!);

/// Seeds an SM-2 [CardState] from an FSRS one, for a learner switching back
/// to Classic after grading under FSRS.
///
/// * intervalDays := the interval FSRS scheduled (due - last review). SM-2's
///   interval and FSRS's are the same claim: days until the next review.
/// * ease := the inverse of [seedFsrsFromClassic]'s linear ease->difficulty
///   map, floored at SM-2's 1.3, so a round trip through FSRS returns the
///   ease it started from.
/// * reps := at least 2 once reviewed, so SM-2's next good grade multiplies
///   the carried interval by ease instead of restarting at 1 then 6 days.
CardState seedClassicFromFsrs(FsrsCardState f) {
  final interval = _fsrsScheduledInterval(f);
  return CardState(
    itemId: f.itemId,
    ease: easeFromFsrsDifficulty(f.difficulty),
    intervalDays: interval,
    dueEpochDay: f.dueEpochDay,
    reps: f.reps == 0 ? 0 : math.max(2, f.reps),
    lapses: f.lapses,
  );
}
