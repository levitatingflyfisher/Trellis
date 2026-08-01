/// The chunk protocol: what a task must promise for the resume law to hold.
library;

/// A long task cut into [totalUnits] resumable units (transcription
/// windows, TTS sentences, translation batches).
///
/// The contract, on which the byte-identical resume guarantee rests:
///
///  1. **The checkpoint carries EVERYTHING.** After `restore(c)` on a fresh
///     instance, running the remaining units must produce output
///     byte-identical to the instance that wrote `c` — instance memory is
///     worth nothing, because a process kill erases it.
///  2. **Units are deterministic given restored state.** `runUnit(u)` may
///     not depend on the clock, on randomness, or on how many times it was
///     attempted before. A unit whose commit was lost WILL be re-run.
///  3. **Unit output rides with the checkpoint.** In the real adapter a
///     unit's output rows and `JobStore.saveCheckpoint` commit in ONE Drift
///     transaction; in pure form, the checkpoint string is the output's
///     vehicle. Either way: no commit, no side effect.
abstract class ChunkedTask {
  int get totalUnits;

  /// Run unit [unit] (0-based). May throw — the runner retries it under
  /// its backoff policy.
  Future<void> runUnit(int unit);

  /// Serialize all state a fresh instance needs to continue. Called after
  /// every successful unit, committed atomically with the unit count.
  String checkpoint();

  /// Rehydrate from a checkpoint written by [checkpoint]. Called once,
  /// before any unit, when resuming.
  void restore(String checkpoint);
}
