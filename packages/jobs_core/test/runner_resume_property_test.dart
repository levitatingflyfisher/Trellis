import 'dart:convert';

import 'package:jobs_core/jobs_core.dart';
import 'package:test/test.dart';

import 'helpers/fakes.dart';

/// THE resume law (proposal-2 §9, step 5): kill the process at ANY unit
/// boundary of a 7-unit task, resume in a fresh process, and the final
/// output is byte-identical to an uninterrupted run.
///
/// The sweep covers every boundary twice over:
///  - "commit landed, then died"  → 1..7 units on disk when the lights went out
///  - "died before the commit"    → the unit ran but its transaction was lost
/// Between them, every possible on-disk state 0..7 is a resume start point.
void main() {
  late List<int> referenceBytes;

  setUpAll(() async {
    // The uninterrupted run: one process, no kills.
    final clock = FakeClock();
    final store = InMemoryJobStore();
    final task = ChainedTask(clock);
    final runner =
        JobRunner(store: store, now: clock.now, sleep: SleepRecorder().call);
    final job =
        await runner.run(jobId: 'ref', kind: 'transcribe', task: task);
    expect(job.state, JobState.done);
    referenceBytes = utf8.encode(task.output);
    expect(referenceBytes, isNotEmpty);
  });

  Future<void> killAndResume(
      {required int killOnCommit, required bool commitLands}) async {
    final clock = FakeClock();
    final store = InMemoryJobStore();

    // Process 1: runs until the kill.
    final killing = KillingStore(store,
        killOnCommit: killOnCommit, commitLands: commitLands);
    final runner1 =
        JobRunner(store: killing, now: clock.now, sleep: SleepRecorder().call);
    await expectLater(
      runner1.run(jobId: 'ep', kind: 'transcribe', task: ChainedTask(clock)),
      throwsA(isA<KilledProcess>()),
    );

    // The row the dead process left behind: still 'running' (no shutdown
    // hook ran — kills don't run shutdown hooks), doneUnits = exactly the
    // commits that landed.
    final landed = commitLands ? killOnCommit : killOnCommit - 1;
    final orphan = (await store.load('ep'))!;
    expect(orphan.state, JobState.running);
    expect(orphan.doneUnits, landed);

    // Process 2: a FRESH task instance (instance memory died with the
    // process), the same underlying store.
    final resumedTask = ChainedTask(clock);
    final runner2 =
        JobRunner(store: store, now: clock.now, sleep: SleepRecorder().call);
    final job = await runner2.run(
        jobId: 'ep', kind: 'transcribe', task: resumedTask);

    expect(job.state, JobState.done);
    expect(job.doneUnits, 7);
    // Byte-identical to the uninterrupted run:
    expect(utf8.encode(resumedTask.output), equals(referenceBytes));
    // And it NEVER restarted from zero: only the uncommitted units ran.
    expect(resumedTask.unitsRun,
        equals([for (var u = landed; u < 7; u++) u]));
  }

  group('kill after the commit landed (boundaries 1..7)', () {
    for (var n = 1; n <= 7; n++) {
      test('killed after commit $n → resume completes byte-identical', () async {
        await killAndResume(killOnCommit: n, commitLands: true);
      });
    }
  });

  group('kill before the commit applied (boundaries 0..6)', () {
    for (var n = 1; n <= 7; n++) {
      test('killed during commit $n (lost) → resume completes byte-identical',
          () async {
        await killAndResume(killOnCommit: n, commitLands: false);
      });
    }
  });

  group('resume hygiene', () {
    test('running a done job is idempotent: the task is never touched',
        () async {
      final clock = FakeClock();
      final store = InMemoryJobStore();
      final runner =
          JobRunner(store: store, now: clock.now, sleep: SleepRecorder().call);
      await runner.run(
          jobId: 'ep', kind: 'transcribe', task: ChainedTask(clock));

      final again = ChainedTask(clock);
      final job =
          await runner.run(jobId: 'ep', kind: 'transcribe', task: again);
      expect(job.state, JobState.done);
      expect(again.unitsRun, isEmpty);
      expect(again.restoreCalled, isFalse);
    });

    test('resuming with a task of a DIFFERENT shape is refused', () async {
      final clock = FakeClock();
      final store = InMemoryJobStore();
      final killing = KillingStore(store, killOnCommit: 3, commitLands: true);
      final runner1 = JobRunner(
          store: killing, now: clock.now, sleep: SleepRecorder().call);
      await expectLater(
        runner1.run(jobId: 'ep', kind: 'transcribe', task: ChainedTask(clock)),
        throwsA(isA<KilledProcess>()),
      );

      final runner2 =
          JobRunner(store: store, now: clock.now, sleep: SleepRecorder().call);
      await expectLater(
        runner2.run(
            jobId: 'ep',
            kind: 'transcribe',
            task: ChainedTask(clock, totalUnits: 5)),
        throwsStateError,
      );
    });
  });
}
