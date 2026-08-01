import 'dart:convert';

import 'package:jobs_core/jobs_core.dart';
import 'package:test/test.dart';

import 'helpers/fakes.dart';

/// Cancel is a pause you can walk away from: the checkpoint is KEPT and the
/// job resumes exactly where it stopped. Abandon is the user's "throw it
/// away": the row — checkpoint and all — is deleted.
void main() {
  test('cancel mid-run stops at the next boundary and keeps the checkpoint',
      () async {
    final clock = FakeClock();
    final store = InMemoryJobStore();
    final token = CancelToken();
    final task = ChainedTask(clock, afterUnit: (u) {
      if (u == 2) token.cancel(); // the user taps ✕ while unit 2 wraps up
    });
    final runner =
        JobRunner(store: store, now: clock.now, sleep: SleepRecorder().call);

    final job = await runner.run(
        jobId: 'ep', kind: 'transcribe', task: task, cancelToken: token);

    expect(job.state, JobState.cancelled);
    expect(job.doneUnits, 3); // unit 2's commit landed before the stop
    expect(task.unitsRun, equals([0, 1, 2])); // no unit ran past the cancel
    final row = (await store.load('ep'))!;
    expect(row.state, JobState.cancelled);
    expect(row.doneUnits, 3);
    expect(row.checkpoint, isNotNull); // resumable — that's the law
  });

  test('a cancelled job resumes byte-identical to an uninterrupted run',
      () async {
    final clock = FakeClock();

    // Reference: never interrupted.
    final refTask = ChainedTask(clock);
    await JobRunner(
            store: InMemoryJobStore(),
            now: clock.now,
            sleep: SleepRecorder().call)
        .run(jobId: 'ref', kind: 'transcribe', task: refTask);

    // Cancel at unit 4, then resume with a fresh task instance.
    final store = InMemoryJobStore();
    final token = CancelToken();
    final runner =
        JobRunner(store: store, now: clock.now, sleep: SleepRecorder().call);
    await runner.run(
        jobId: 'ep',
        kind: 'transcribe',
        task: ChainedTask(clock, afterUnit: (u) {
          if (u == 3) token.cancel();
        }),
        cancelToken: token);

    final resumed = ChainedTask(clock);
    final job =
        await runner.run(jobId: 'ep', kind: 'transcribe', task: resumed);

    expect(job.state, JobState.done);
    expect(resumed.unitsRun, equals([4, 5, 6]));
    expect(utf8.encode(resumed.output), equals(utf8.encode(refTask.output)));
  });

  test('an already-cancelled token stops the job before any unit runs',
      () async {
    final clock = FakeClock();
    final store = InMemoryJobStore();
    final task = ChainedTask(clock);
    final runner =
        JobRunner(store: store, now: clock.now, sleep: SleepRecorder().call);

    final job = await runner.run(
        jobId: 'ep',
        kind: 'transcribe',
        task: task,
        cancelToken: CancelToken()..cancel());

    expect(job.state, JobState.cancelled);
    expect(job.doneUnits, 0);
    expect(task.unitsRun, isEmpty);
  });

  test('cancellation set during a backoff sleep stops before the next attempt',
      () async {
    final clock = FakeClock();
    final store = InMemoryJobStore();
    final token = CancelToken();
    // Unit 1 keeps failing; the user cancels while the runner backs off.
    final task = ChainedTask(clock, failures: {1: 99});
    Future<void> cancellingSleep(int ms) async {
      token.cancel();
    }

    final runner = JobRunner(
        store: store,
        now: clock.now,
        sleep: cancellingSleep,
        backoff: const BackoffPolicy(maxAttempts: 4));

    final job = await runner.run(
        jobId: 'ep', kind: 'transcribe', task: task, cancelToken: token);

    expect(job.state, JobState.cancelled);
    expect(task.unitsRun, equals([0, 1])); // unit 1 was NOT re-attempted
    expect((await store.load('ep'))!.doneUnits, 1); // unit 0 kept
  });

  test('abandon deletes the row, checkpoint and all', () async {
    final clock = FakeClock();
    final store = InMemoryJobStore();
    final token = CancelToken();
    final runner =
        JobRunner(store: store, now: clock.now, sleep: SleepRecorder().call);
    await runner.run(
        jobId: 'ep',
        kind: 'transcribe',
        task: ChainedTask(clock, afterUnit: (u) {
          if (u == 2) token.cancel();
        }),
        cancelToken: token);
    expect(await store.load('ep'), isNotNull);

    await runner.abandon('ep');

    expect(await store.load('ep'), isNull); // nothing left to resume
  });
}
