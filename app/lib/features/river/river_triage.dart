/// The river's two fast triage gestures (Campaign 5, "the river gets
/// hands"): Keep promotes a river item into the library — the existing
/// library-add path ([SpineDao.promoteWork]) — and marks it read, since it
/// has left the river's unread flow. Let it pass is the explicit
/// dismissal: marks read, nothing more; decay already handles aging.
///
/// Kept items live in the library, full stop — no river filter chip for
/// "Kept" exists or should (ADR-0011): the never-pollute law cuts both
/// ways.
library;

import '../../db/database.dart';

/// The exact fields Undo needs to restore verbatim — captured by the
/// caller BEFORE either gesture runs, from the [RiverEntry] already in
/// hand (no extra DB round-trip to read "before" state).
typedef TriagePriorState = ({String persistence, int? readAtMs});

class RiverTriage {
  RiverTriage(this.db);
  final AppDatabase db;

  /// Reads the two fields Undo will need back, from a [RiverEntry]'s
  /// already-loaded work/episode — named fields rather than the record
  /// itself so the caller doesn't need to import [RiverEntry] just to
  /// build one.
  TriagePriorState priorStateOf(
          {required String persistence, required int? readAtMs}) =>
      (persistence: persistence, readAtMs: readAtMs);

  /// Keep: into the library, and out of the unread flow.
  Future<void> keep(int workId, {required int nowMs}) async {
    await db.spineDao.promoteWork(workId);
    await db.feedsDao.setReadAt(workId, nowMs);
  }

  /// Let it pass: the explicit "I saw this, no thanks" — marks read,
  /// promotes nothing.
  Future<void> letItPass(int workId, {required int nowMs}) =>
      db.feedsDao.setReadAt(workId, nowMs);

  /// Undoes either gesture — verbatim restore, not "the opposite": an
  /// item that was already read (or already kept) before the gesture ran
  /// stays that way after Undo.
  Future<void> undo(int workId, TriagePriorState prior) async {
    await db.spineDao.setPersistence(workId, prior.persistence);
    await db.feedsDao.setReadAt(workId, prior.readAtMs);
  }
}
