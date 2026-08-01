// FSRS-5 spaced-repetition scheduler (pure function) — additive, opt-in.
//
// This file does not modify models.dart or sm2_scheduler.dart. The sealed
// SM-2 scheduler and its CardState are untouched; FsrsCardState is a
// standalone type living beside it, sharing only the [Grade] enum. A
// profile opts into FSRS per Card; grading calls scheduleFsrs instead of
// scheduleSm2 for that card, using the same "state + grade + today ->
// new state" boundary shape.
//
// ## Source
//
// FSRS-5, the algorithm published by the open-spaced-repetition project:
// https://github.com/open-spaced-repetition/awesome-fsrs/wiki/The-Algorithm
// The default 19-value weight vector and the forgetting-curve constants
// below were fetched from that wiki page and cross-checked against a second,
// independent secondary source describing the same version —
// https://borretti.me/article/implementing-fsrs-in-100-lines — which quotes
// an identical weight vector and the same -0.5/19-81 curve. The two
// constants are also *internally* self-consistent: stability is defined as
// the elapsed time at which retrievability has fallen to exactly 90%, so
// `fsrsRetrievability(s, s) == 0.9` must hold for any s — verified in
// fsrs_scheduler_test.dart and true only for kFsrsDecay == -0.5,
// kFsrsFactor == 19/81 (the FSRS-5 curve; NOT the original FSRS v4 curve,
// which used -1 and 1/9).
//
// ## Scope: day granularity, no same-day/short-term stability
//
// FSRS-5 adds two weights (w17, w18) beyond FSRS-4.5's seventeen for a
// same-day "short-term" stability formula, used when a card is reviewed
// more than once within a single day (Anki's relearning steps). This
// scheduler — like the sealed SM-2 one beside it — operates at whole-day
// granularity (CardState.dueEpochDay is a day, not a timestamp), so that
// formula has no natural home here. w17 and w18 are carried in
// kFsrsDefaultWeights for fidelity to the published vector but are not
// referenced by any formula in this file. A same-day re-grade is handled
// by the ordinary elapsed-time formula with elapsed == 0 (retrievability
// saturates at 1.0), which is a graceful simplification, not a crash.
//
// ## SM-2 -> FSRS seeding
//
// See seedFsrsFromClassic's doc comment: there is no published SM-2 ->
// FSRS conversion formula (verified by direct search — Anki's own
// migration replays each card's review log through FSRS rather than
// converting the two SM-2 summary numbers). The stability half of the seed
// needs no citation (it is a direct restatement of what SM-2's interval
// already means); the difficulty half is declared as our own heuristic,
// not a published one.

import 'dart:math' as math;

import 'package:study_core/src/models.dart';

/// FSRS-5 default parameters, w[0]..w[18], verbatim from the published
/// reference values (see file doc comment for source + cross-check).
const List<double> kFsrsDefaultWeights = [
  0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046, // w0-7
  1.54575, 0.1192, 1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315, // w8-15
  2.9898, 0.51655, 0.6621, // w16-18 (w17/w18: same-day stability, unused here)
];

/// The FSRS-5 forgetting-curve decay exponent (the -0.5/19-81 power-law
/// revision, not FSRS v4's original -1/1-9 curve).
const double kFsrsDecay = -0.5;

/// The FSRS-5 forgetting-curve scale factor. Chosen (by the algorithm's
/// authors) so that `(1 + kFsrsFactor)^kFsrsDecay == 0.9` exactly — i.e. so
/// retrievability is defined to be 90% at t == stability.
const double kFsrsFactor = 19 / 81;

/// A hard ceiling on any single scheduled interval, matching the common
/// spaced-repetition convention (Anki's own default cap is 100 years). FSRS
/// has no natural cap of its own — stability can grow without bound — so
/// this is a safety clamp, not part of the published algorithm.
const int kFsrsMaxIntervalDays = 36500;

/// Retrievability: the probability of successful recall after [elapsedDays]
/// have passed since a card's stability was last [stability] days.
/// Negative elapsed time is clamped to zero; a non-positive stability
/// (only possible before a card's first review) returns 0.
double fsrsRetrievability(double elapsedDays, double stability) {
  if (stability <= 0) return 0;
  final double t = elapsedDays < 0 ? 0.0 : elapsedDays;
  return math.pow(1 + kFsrsFactor * t / stability, kFsrsDecay).toDouble();
}

/// FSRS numbers grades 1 (again) .. 4 (easy); [Grade] is declared again=0
/// in enum order, so this is a +1 shift, not a reuse of SM-2's 2..5 scale.
int _fsrsGradeNumber(Grade g) {
  switch (g) {
    case Grade.again:
      return 1;
    case Grade.hard:
      return 2;
    case Grade.good:
      return 3;
    case Grade.easy:
      return 4;
  }
}

/// Initial stability on a card's first ever review: S0(G) = w[G-1].
double fsrsInitialStability(Grade grade,
        [List<double> w = kFsrsDefaultWeights]) =>
    w[_fsrsGradeNumber(grade) - 1];

/// Initial difficulty on a card's first ever review:
/// D0(G) = w4 - e^(w5*(G-1)) + 1, clamped to [1, 10].
double fsrsInitialDifficulty(Grade grade,
    [List<double> w = kFsrsDefaultWeights]) {
  final int g = _fsrsGradeNumber(grade);
  final double d = w[4] - math.exp(w[5] * (g - 1)) + 1;
  return d.clamp(1.0, 10.0);
}

/// Difficulty update with mean reversion toward D0(easy):
/// ΔD(G) = -w6*(G-3); D' = D + ΔD*(10-D)/9; D'' = w7*D0(4) + (1-w7)*D'.
double _nextDifficulty(double d, Grade grade,
    [List<double> w = kFsrsDefaultWeights]) {
  final int g = _fsrsGradeNumber(grade);
  final double deltaD = -w[6] * (g - 3);
  final double dPrime = d + deltaD * (10 - d) / 9;
  final double meanReversionTarget = fsrsInitialDifficulty(Grade.easy, w);
  final double dPrimePrime =
      w[7] * meanReversionTarget + (1 - w[7]) * dPrime;
  return dPrimePrime.clamp(1.0, 10.0);
}

/// Stability update after a successful recall (hard/good/easy):
/// S' = S * (e^w8 * (11-D) * S^-w9 * (e^(w10*(1-R))-1) * hardPenalty *
/// easyBonus + 1).
double _nextStabilityOnSuccess(
    double d, double s, double r, Grade grade,
    [List<double> w = kFsrsDefaultWeights]) {
  final double hardPenalty = grade == Grade.hard ? w[15] : 1.0;
  final double easyBonus = grade == Grade.easy ? w[16] : 1.0;
  final double growth = math.exp(w[8]) *
      (11 - d) *
      math.pow(s, -w[9]) *
      (math.exp(w[10] * (1 - r)) - 1) *
      hardPenalty *
      easyBonus;
  return s * (growth + 1);
}

/// Stability update after a lapse (again):
/// S'_f = w11 * D^-w12 * ((S+1)^w13 - 1) * e^(w14*(1-R)), never exceeding
/// the pre-lapse stability (a lapse cannot make a card "more stable" than
/// it already was).
double _nextStabilityOnLapse(double d, double s, double r,
    [List<double> w = kFsrsDefaultWeights]) {
  final double sf = w[11] *
      math.pow(d, -w[12]) *
      (math.pow(s + 1, w[13]) - 1) *
      math.exp(w[14] * (1 - r));
  return math.min(sf, s);
}

/// The next review interval for a given [stability] targeting
/// [desiredRetention] (default 90%, matching the "S" in "stability = time
/// to 90% retention" by construction when desiredRetention == 0.9):
/// I = (S / FACTOR) * (desiredRetention^(1/DECAY) - 1), clamped to
/// [1, kFsrsMaxIntervalDays].
int fsrsIntervalDays(double stability, double desiredRetention,
    {int maxDays = kFsrsMaxIntervalDays}) {
  final double raw = (stability / kFsrsFactor) *
      (math.pow(desiredRetention, 1 / kFsrsDecay) - 1);
  final int days = raw.isNaN || raw.isInfinite || raw > maxDays
      ? maxDays
      : raw.round();
  return days.clamp(1, maxDays);
}

/// Per-item FSRS state. Deliberately parallel in shape to [CardState] (same
/// field families: an id, scheduling numbers, dueEpochDay, reps, lapses)
/// but is its own type — [CardState] is not modified. [lastReviewEpochDay]
/// is FSRS-specific: unlike SM-2 (whose interval already encodes elapsed
/// time), FSRS needs to know how long ago the card was last seen to compute
/// retrievability at the next review.
class FsrsCardState {
  const FsrsCardState({
    required this.itemId,
    required this.stability,
    required this.difficulty,
    required this.dueEpochDay,
    required this.reps,
    required this.lapses,
    this.lastReviewEpochDay,
  });

  final String itemId;
  final double stability;
  final double difficulty;
  final int dueEpochDay;
  final int reps;
  final int lapses;

  /// Null only for a card that has never been reviewed under FSRS.
  final int? lastReviewEpochDay;

  factory FsrsCardState.initial(String itemId, int todayEpochDay) =>
      FsrsCardState(
        itemId: itemId,
        stability: 0,
        difficulty: 0,
        dueEpochDay: todayEpochDay,
        reps: 0,
        lapses: 0,
      );

  bool isDue(int todayEpochDay) => dueEpochDay <= todayEpochDay;

  FsrsCardState copyWith({
    double? stability,
    double? difficulty,
    int? dueEpochDay,
    int? reps,
    int? lapses,
    int? lastReviewEpochDay,
  }) =>
      FsrsCardState(
        itemId: itemId,
        stability: stability ?? this.stability,
        difficulty: difficulty ?? this.difficulty,
        dueEpochDay: dueEpochDay ?? this.dueEpochDay,
        reps: reps ?? this.reps,
        lapses: lapses ?? this.lapses,
        lastReviewEpochDay: lastReviewEpochDay ?? this.lastReviewEpochDay,
      );

  /// The additive JSON shape this rides in the app's existing card
  /// persistence blob, alongside the classic {ease, intervalDays, ...}
  /// keys. itemId is not included — it is already the map key the store
  /// uses to find this blob (matching decodeCardState's shape).
  Map<String, dynamic> toJson() => {
        'stability': stability,
        'difficulty': difficulty,
        'dueEpochDay': dueEpochDay,
        'reps': reps,
        'lapses': lapses,
        if (lastReviewEpochDay != null)
          'lastReviewEpochDay': lastReviewEpochDay,
      };

  /// Decodes a blob written by [toJson]. Callers are responsible for
  /// catching malformed entries and skipping them individually (the store's
  /// existing law — see database.dart's decodeCardState precedent); this
  /// constructor does unchecked casts on purpose, so a bad entry throws and
  /// the caller's per-entry try/skip catches it, exactly like the classic
  /// decoder.
  factory FsrsCardState.fromJson(String itemId, Map<String, dynamic> json) =>
      FsrsCardState(
        itemId: itemId,
        stability: (json['stability'] as num).toDouble(),
        difficulty: (json['difficulty'] as num).toDouble(),
        dueEpochDay: json['dueEpochDay'] as int,
        reps: json['reps'] as int,
        lapses: json['lapses'] as int,
        lastReviewEpochDay: json['lastReviewEpochDay'] as int?,
      );

  @override
  bool operator ==(Object other) =>
      other is FsrsCardState &&
      other.itemId == itemId &&
      other.stability == stability &&
      other.difficulty == difficulty &&
      other.dueEpochDay == dueEpochDay &&
      other.reps == reps &&
      other.lapses == lapses &&
      other.lastReviewEpochDay == lastReviewEpochDay;

  @override
  int get hashCode => Object.hash(itemId, stability, difficulty, dueEpochDay,
      reps, lapses, lastReviewEpochDay);
}

/// Advance a card's FSRS state by one graded review. Pure and deterministic:
/// depends only on its arguments. Same boundary shape as [scheduleSm2]:
/// (state, grade, todayEpochDay) -> new state.
FsrsCardState scheduleFsrs(FsrsCardState state, Grade grade, int todayEpochDay,
    {double desiredRetention = 0.9,
    List<double> weights = kFsrsDefaultWeights}) {
  final bool isFirstReview = state.reps == 0;

  final double newDifficulty;
  final double newStability;
  if (isFirstReview) {
    newStability = fsrsInitialStability(grade, weights);
    newDifficulty = fsrsInitialDifficulty(grade, weights);
  } else {
    final int lastReview = state.lastReviewEpochDay ?? todayEpochDay;
    final double elapsed = (todayEpochDay - lastReview).toDouble();
    final double r = fsrsRetrievability(elapsed, state.stability);
    newDifficulty = _nextDifficulty(state.difficulty, grade, weights);
    newStability = grade == Grade.again
        ? _nextStabilityOnLapse(state.difficulty, state.stability, r, weights)
        : _nextStabilityOnSuccess(
            state.difficulty, state.stability, r, grade, weights);
  }

  final int interval = fsrsIntervalDays(newStability, desiredRetention);
  return state.copyWith(
    stability: newStability,
    difficulty: newDifficulty,
    dueEpochDay: todayEpochDay + interval,
    reps: state.reps + 1,
    lapses: grade == Grade.again ? state.lapses + 1 : state.lapses,
    lastReviewEpochDay: todayEpochDay,
  );
}

/// Seeds an [FsrsCardState] from an existing SM-2 [CardState], for a
/// learner switching their profile's scheduler from Classic to FSRS.
///
/// There is no SM-2 -> FSRS conversion formula published by
/// open-spaced-repetition. Anki's own migration path (see
/// fsrs4anki/docs/tutorial.md) does not convert SM-2's two summary numbers
/// at all — it replays each card's full review log through the FSRS update
/// formulas, "assuming that when you did those old reviews, you remembered
/// 90% of the material" wherever elapsed-time data is missing. Replaying a
/// review log is out of scope for an additive, opt-in per-profile setting
/// (it would require folding over `revlog`, which this campaign does not
/// touch), so this uses two explicit heuristics instead of inventing a
/// citation that does not exist:
///
/// * stability := max(intervalDays, a small floor). This needs no external
///   citation: SM-2's interval already *is* its own estimate of "how long
///   until this would likely be forgotten", which is definitionally what
///   FSRS stability measures. A brand-new card (intervalDays == 0) seeds a
///   small positive floor rather than 0, since FSRS divides by stability.
/// * difficulty := a linear map from ease [1.3 (SM-2's floor) .. 2.5 (SM-2's
///   default)] onto FSRS difficulty [10 .. ~5.28], clamped to [1, 10]. The
///   5.28 anchor is FSRS-5's own D0(good) for a fresh card under the
///   default weights (kept in sync with [fsrsInitialDifficulty]), so a
///   deck at SM-2's default ease seeds a "typical first-good-review"
///   difficulty. This mapping is OUR heuristic — not a published one — and
///   is declared as such in the per-profile setting's copy (see ADR-0009).
FsrsCardState seedFsrsFromClassic(CardState classic, int todayEpochDay) {
  const double newCardStabilityFloor = 0.5;
  final double stability = classic.intervalDays > 0
      ? classic.intervalDays.toDouble()
      : newCardStabilityFloor;
  return FsrsCardState(
    itemId: classic.itemId,
    stability: stability,
    difficulty: _difficultyFromEase(classic.ease),
    dueEpochDay: classic.dueEpochDay,
    reps: classic.reps,
    lapses: classic.lapses,
    lastReviewEpochDay: todayEpochDay,
  );
}

double _difficultyFromEase(double ease) {
  const double minEase = 1.3; // SM-2's ease floor -> hardest.
  const double easeAtMidDifficulty = 2.5; // SM-2's default ease.
  const double maxDifficulty = 10.0;
  final double midDifficulty = fsrsInitialDifficulty(Grade.good);
  final double slope =
      (midDifficulty - maxDifficulty) / (easeAtMidDifficulty - minEase);
  final double d = maxDifficulty + slope * (ease - minEase);
  return d.clamp(1.0, maxDifficulty);
}
