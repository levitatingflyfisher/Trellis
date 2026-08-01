/// The river's decay presentation, as pure functions (proposal-2 §12: "the
/// river sheds leaves as ephemera decay — deletion made visible and calm").
///
/// These narrate — never decide — the sweep law (`loom_core.sweepEphemera`,
/// ADR-0003 law 2): an ephemeron decays when `today - firstSeen >
/// retentionDays`, and the boundary day itself survives. Everything here is
/// derived from that same whole-epoch-day arithmetic so the story on screen
/// can never disagree with the deletion the boot sweep executes.
///
/// Calm by construction (ADR-0003, no guilt): the leaf fades but never
/// vanishes, the drift notice exists only on the last two days, and nothing
/// here knows how to be red or urgent.
library;

/// Whole days of life left before the sweep takes an ephemeron. On the day
/// an item first arrives this is `retentionDays + 1` (the 30-day window plus
/// the boundary day); `1` on the boundary day — its last — and `<= 0` once
/// the sweep's verdict would name it.
int ephemeraDaysLeft(
        {required int firstSeenEpochDay,
        required int todayEpochDay,
        int retentionDays = 30}) =>
    firstSeenEpochDay + retentionDays + 1 - todayEpochDay;

/// The leaf never fades to nothing: deletion is made visible, not hidden,
/// and a ghost-faint icon at small sizes reads as a rendering bug.
const double kLeafMinOpacity = 0.25;

/// Leaf opacity for an ephemeron with [daysLeft] to live: fully there on
/// arrival, fading linearly to [kLeafMinOpacity] as decay approaches.
/// Out-of-range inputs clamp — a leaf is never brighter than new nor
/// fainter than the floor.
double leafOpacity(int daysLeft, {int retentionDays = 30}) {
  final life = retentionDays + 1;
  final t = (daysLeft / life).clamp(0.0, 1.0);
  return kLeafMinOpacity + (1.0 - kLeafMinOpacity) * t;
}

/// The one-line drift notice, shown on the LAST two days only — before that
/// the fading leaf says everything worth saying (no countdown urgency).
/// Null means say nothing. An overdue-but-unswept item (the sweep runs at
/// boot) still reads as one day.
String? driftSubtitle(int daysLeft) {
  if (daysLeft > 2) return null;
  return daysLeft >= 2 ? 'drifts away in 2 days' : 'drifts away in 1 day';
}
