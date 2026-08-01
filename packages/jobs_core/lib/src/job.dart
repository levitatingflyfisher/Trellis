/// The job row (proposal-2 §9): one persisted record per long-running task.
///
/// The engine treats [checkpoint] as an opaque serialized string — its shape
/// belongs to the [ChunkedTask] that wrote it. What the engine guarantees is
/// WHEN it is written: atomically with [doneUnits], after every successful
/// unit (one Drift transaction in the real adapter).
library;

/// Lifecycle of a job.
///
/// A process kill leaves the row at [running] — that is by design: resume
/// looks at [Job.doneUnits] + [Job.checkpoint], never at a shutdown hook
/// that a kill would have skipped.
enum JobState {
  /// Claimed by a runner (or orphaned by a kill — indistinguishable, and
  /// that's fine: both resume the same way).
  running,

  /// Every unit committed.
  done,

  /// Stopped by the user's hand. The checkpoint is KEPT — cancel is a
  /// pause you can walk away from, not a deletion.
  cancelled,

  /// A unit exhausted its retry budget. The checkpoint is kept, so a later
  /// attempt continues instead of starting over.
  failed,
}

/// One checkpointed job. Immutable value row.
class Job {
  final String id;

  /// What kind of work, e.g. 'transcribe', 'tts-render', 'translate'.
  final String kind;
  final JobState state;

  /// Opaque task state, sufficient to resume byte-identically. Null until
  /// the first unit commits.
  final String? checkpoint;
  final int totalUnits;

  /// Units fully committed — the next unit to run is exactly this index.
  final int doneUnits;
  final int createdAtMs;

  const Job({
    required this.id,
    required this.kind,
    required this.state,
    required this.checkpoint,
    required this.totalUnits,
    required this.doneUnits,
    required this.createdAtMs,
  });

  /// Null means "keep". [checkpoint] can never be cleared through here —
  /// forgetting a checkpoint is [JobStore.delete]'s job (abandon), on
  /// purpose.
  Job copyWith({JobState? state, String? checkpoint, int? doneUnits}) => Job(
        id: id,
        kind: kind,
        state: state ?? this.state,
        checkpoint: checkpoint ?? this.checkpoint,
        totalUnits: totalUnits,
        doneUnits: doneUnits ?? this.doneUnits,
        createdAtMs: createdAtMs,
      );
}
