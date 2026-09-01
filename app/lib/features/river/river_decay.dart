/// The river's decay presentation, as pure functions (proposal-2 §12: "the
/// river sheds leaves as ephemera decay — deletion made visible and calm").
///
/// These narrate — never decide — the sweep law (`loom_core.sweepEphemera`,
/// ADR-0003 law 2): an ephemeron decays when `today - firstSeen >
/// retentionDays`, and the boundary day itself survives. Everything here is
/// derived from that same whole-epoch-day arithmetic so the story on screen
/// can never disagree with the decay the boot sweep executes. (Decay is a
/// soft state, not a delete: the Inbox's notice offers Restore or Let go.)
///
/// Calm by construction (ADR-0003, no guilt): the leaf fades but never
/// vanishes, every row says in words how long it stays, and nothing here
/// knows how to be red or urgent.
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

/// The row's plain statement of how long it stays, on every ephemeron row
/// from its first day (audit wid-02, visual-02: the fading leaf alone was
/// below any noticeable step and said nothing to a screen reader). "Leaves",
/// not "deleted": what leaves is kept a while longer and can be restored.
/// An overdue-but-unswept item (the sweep runs at start-up) reads as
/// tomorrow.
String driftSubtitle(int daysLeft) => daysLeft <= 1
    ? 'Leaves the Inbox tomorrow'
    : 'Leaves the Inbox in $daysLeft days';

/// What a held row says instead of a countdown: it is in Up Next or has
/// captures, so the sweep leaves it alone (see `SpineDao.heldWorkIds`).
const String heldSubtitle = 'Stays while it’s in Up Next or has captures';
