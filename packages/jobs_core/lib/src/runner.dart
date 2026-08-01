/// The job runner: drives a [ChunkedTask] through the store, one committed
/// unit at a time.
library;

import 'backoff.dart';
import 'chunked_task.dart';
import 'eta.dart';
import 'job.dart';
import 'job_store.dart';

/// Milliseconds since epoch, injected — the runner owns no clock.
typedef NowFn = int Function();

/// Wait [ms] milliseconds, injected — the runner owns no timer. Tests pass
/// an immediate fake; the app passes a real `Future.delayed`.
typedef SleepFn = Future<void> Function(int ms);

/// Cooperative cancellation. Checked before every attempt, so a cancel
/// lands at the next unit boundary (or before the next retry) — never
/// mid-unit, never losing a committed checkpoint.
class CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// One progress beat, emitted after every committed unit.
class JobProgress {
  final int doneUnits;
  final int totalUnits;

  /// Honest estimate of ms remaining — a moving average of measured unit
  /// durations (retries included: the user waits through those too).
  final int? etaMs;

  const JobProgress(
      {required this.doneUnits, required this.totalUnits, this.etaMs});
}

/// Executes jobs under the resume laws (proposal-2 §9):
///
///  - after every successful unit, checkpoint + doneUnits commit atomically;
///  - resume (after a kill, a cancel, or a failure) restores the checkpoint
///    into a fresh task and continues at `doneUnits` — byte-identical to an
///    uninterrupted run, never restarting from zero;
///  - a failing unit retries under bounded [BackoffPolicy] through the
///    injected [sleep] seam — the runner itself is pure of timers;
///  - cancel keeps the checkpoint; [abandon] deletes it.
class JobRunner {
  final JobStore store;
  final NowFn now;
  final SleepFn sleep;
  final BackoffPolicy backoff;
  final void Function(JobProgress progress)? onProgress;

  JobRunner({
    required this.store,
    required this.now,
    required this.sleep,
    this.backoff = const BackoffPolicy(),
    this.onProgress,
  });

  /// Run [jobId] to completion, resuming if the store already knows it.
  /// Returns the final row; its [Job.state] is the outcome (done /
  /// cancelled / failed). Running an already-done job returns it untouched.
  Future<Job> run({
    required String jobId,
    required String kind,
    required ChunkedTask task,
    CancelToken? cancelToken,
  }) async {
    final existing = await store.load(jobId);
    if (existing != null && existing.state == JobState.done) return existing;

    Job job;
    if (existing != null) {
      if (existing.totalUnits != task.totalUnits) {
        throw StateError(
            'job "$jobId" has ${existing.totalUnits} units on record but the '
            'task brought ${task.totalUnits} — refusing to resume a '
            'different shape');
      }
      final checkpoint = existing.checkpoint;
      if (checkpoint != null) task.restore(checkpoint);
      job = existing.copyWith(state: JobState.running);
    } else {
      job = Job(
        id: jobId,
        kind: kind,
        state: JobState.running,
        checkpoint: null,
        totalUnits: task.totalUnits,
        doneUnits: 0,
        createdAtMs: now(),
      );
    }
    await store.save(job);

    // Estimates start fresh on every (re)run: a dead process's timings are
    // stale evidence, and honesty beats continuity.
    final eta = EtaTracker();

    for (var unit = job.doneUnits; unit < job.totalUnits; unit++) {
      final unitStart = now();
      var attempt = 1;
      while (true) {
        if (cancelToken?.isCancelled ?? false) {
          job = job.copyWith(state: JobState.cancelled);
          await store.save(job); // checkpoint intact — cancel is resumable
          return job;
        }
        try {
          await task.runUnit(unit);
          break;
        } on Object {
          if (attempt >= backoff.maxAttempts) {
            job = job.copyWith(state: JobState.failed);
            await store.save(job); // checkpoint kept for a later retry
            return job;
          }
          await sleep(backoff.delayForRetry(attempt));
          attempt++;
        }
      }
      // Duration from first attempt to success — retries and backoff
      // included, because that is what the user actually waited.
      eta.addSample(now() - unitStart);

      await store.saveCheckpoint(jobId, task.checkpoint(), unit + 1);
      job = job.copyWith(checkpoint: task.checkpoint(), doneUnits: unit + 1);
      onProgress?.call(JobProgress(
        doneUnits: job.doneUnits,
        totalUnits: job.totalUnits,
        etaMs: eta.etaMsFor(job.totalUnits - job.doneUnits),
      ));
    }

    job = job.copyWith(state: JobState.done);
    await store.save(job);
    return job;
  }

  /// The user's "throw it away": forget the job, checkpoint and all.
  /// (Cancel, by contrast, keeps everything — see [CancelToken].)
  Future<void> abandon(String jobId) => store.delete(jobId);
}
