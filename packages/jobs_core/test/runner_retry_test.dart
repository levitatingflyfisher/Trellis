import 'dart:convert';

import 'package:jobs_core/jobs_core.dart';
import 'package:test/test.dart';

import 'helpers/fakes.dart';

/// Retry law: a failed unit retries with BOUNDED backoff, purely — the
/// runner never touches a real timer; every wait goes through the injected
/// sleep seam, every timestamp through the injected clock.
void main() {
  Future<String> uninterruptedOutput() async {
    final clock = FakeClock();
    final store = InMemoryJobStore();
    final task = ChainedTask(clock);
    final runner =
        JobRunner(store: store, now: clock.now, sleep: SleepRecorder().call);
    await runner.run(jobId: 'ref', kind: 'transcribe', task: task);
    return task.output;
  }

  test('a flaky unit retries through the sleep seam and the output is unharmed',
      () async {
    final clock = FakeClock();
    final store = InMemoryJobStore();
    final sleeps = SleepRecorder();
    // Unit 3 throws twice, then succeeds.
    final task = ChainedTask(clock, failures: {3: 2});
    final runner = JobRunner(
      store: store,
      now: clock.now,
      sleep: sleeps.call,
      backoff: const BackoffPolicy(
          maxAttempts: 4, baseDelayMs: 500, multiplier: 2.0, maxDelayMs: 60000),
    );

    final job = await runner.run(jobId: 'ep', kind: 'transcribe', task: task);

    expect(job.state, JobState.done);
    // Exactly the policy's schedule went through the seam: 500, then 1000.
    expect(sleeps.slept, equals([500, 1000]));
    // Unit 3 ran three times; retries did not corrupt the chain.
    expect(task.unitsRun, equals([0, 1, 2, 3, 3, 3, 4, 5, 6]));
    expect(utf8.encode(task.output),
        equals(utf8.encode(await uninterruptedOutput())));
  });

  test('every slept delay respects the maxDelayMs bound', () async {
    final clock = FakeClock();
    final store = InMemoryJobStore();
    final sleeps = SleepRecorder();
    final task = ChainedTask(clock, failures: {0: 3});
    final runner = JobRunner(
      store: store,
      now: clock.now,
      sleep: sleeps.call,
      backoff: const BackoffPolicy(
          maxAttempts: 4, baseDelayMs: 500, multiplier: 2.0, maxDelayMs: 800),
    );

    await runner.run(jobId: 'ep', kind: 'transcribe', task: task);

    expect(sleeps.slept, equals([500, 800, 800])); // 1000 and 2000 capped
  });

  test('retry budget exhausted → state failed, checkpoint KEPT', () async {
    final clock = FakeClock();
    final store = InMemoryJobStore();
    final sleeps = SleepRecorder();
    // Unit 2 fails more times than the budget allows.
    final task = ChainedTask(clock, failures: {2: 3});
    final runner = JobRunner(
      store: store,
      now: clock.now,
      sleep: sleeps.call,
      backoff: const BackoffPolicy(
          maxAttempts: 3, baseDelayMs: 500, multiplier: 2.0, maxDelayMs: 60000),
    );

    final job = await runner.run(jobId: 'ep', kind: 'transcribe', task: task);

    expect(job.state, JobState.failed);
    // Attempts were bounded: 3 total, so 2 sleeps.
    expect(sleeps.slept, equals([500, 1000]));
    expect(task.unitsRun, equals([0, 1, 2, 2, 2]));
    // The two good units survive in the store for a later retry.
    final row = (await store.load('ep'))!;
    expect(row.state, JobState.failed);
    expect(row.doneUnits, 2);
    expect(row.checkpoint, isNotNull);
  });

  test('a failed job resumes once the world heals — byte-identical', () async {
    final clock = FakeClock();
    final store = InMemoryJobStore();
    final runner = JobRunner(
      store: store,
      now: clock.now,
      sleep: SleepRecorder().call,
      backoff: const BackoffPolicy(maxAttempts: 2),
    );
    await runner.run(
        jobId: 'ep',
        kind: 'transcribe',
        task: ChainedTask(clock, failures: {4: 5}));
    expect((await store.load('ep'))!.state, JobState.failed);

    // The network came back / the file unlocked: run again, no failures.
    final healed = ChainedTask(clock);
    final job =
        await runner.run(jobId: 'ep', kind: 'transcribe', task: healed);

    expect(job.state, JobState.done);
    expect(healed.unitsRun, equals([4, 5, 6])); // continued, not restarted
    expect(utf8.encode(healed.output),
        equals(utf8.encode(await uninterruptedOutput())));
  });
}
