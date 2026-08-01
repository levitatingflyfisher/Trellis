import 'dart:convert';

import 'package:jobs_core/jobs_core.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:test/test.dart';
import 'package:transcribe_core/transcribe_core.dart';

import 'helpers/fakes.dart';

/// THE resume law, inherited from jobs_core and proved for THIS task
/// (proposal-2 §9 step 5): kill the process at ANY window boundary of a
/// 6-window episode, resume in a fresh process, and the transcript is
/// byte-identical to an uninterrupted run.
///
/// The transcriber hashes the exact samples it receives, so any divergence
/// on resume — the wrong window read, a window skipped, a committed window
/// re-transcribed and double-appended — changes the bytes. One window is
/// silent and VAD-gated, so the sweep also proves empty units resume clean.
void main() {
  // 150s of audio -> 6 windows at 0/25/50/75/100/125s. Window 50000 silent.
  const totalMs = 150000;
  const silentStart = 50000;
  const allStarts = [0, 25000, 50000, 75000, 100000, 125000];

  TranscribeEpisodeTask makeTask(HashingTranscriber transcriber) =>
      TranscribeEpisodeTask(
        source: ScriptedPcmSource(
            totalMs: totalMs, silentStarts: const {silentStart}),
        transcriber: transcriber,
        vad: FakeVad(),
        lang: 'sv',
        minSegmentChars: 1,
      );

  late String referenceCheckpoint;
  late String referenceResult;

  setUpAll(() async {
    final clock = FakeClock();
    final task = makeTask(HashingTranscriber());
    final runner = JobRunner(
        store: InMemoryJobStore(), now: clock.now, sleep: SleepRecorder().call);
    final job = await runner.run(jobId: 'ref', kind: 'transcribe', task: task);
    expect(job.state, JobState.done);
    referenceCheckpoint = task.checkpoint();
    referenceResult = jsonEncode(task.buildResult().toJson());
    // Sanity: the reference actually transcribed something.
    expect(task.buildResult().mergedChunks, hasLength(5));
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
      runner1.run(
          jobId: 'ep', kind: 'transcribe', task: makeTask(HashingTranscriber())),
      throwsA(isA<KilledProcess>()),
    );

    final landed = commitLands ? killOnCommit : killOnCommit - 1;
    final orphan = (await store.load('ep'))!;
    expect(orphan.state, JobState.running);
    expect(orphan.doneUnits, landed);

    // Process 2: fresh task, fresh transcriber — instance memory is gone.
    final resumedTranscriber = HashingTranscriber();
    final resumedTask = makeTask(resumedTranscriber);
    final runner2 =
        JobRunner(store: store, now: clock.now, sleep: SleepRecorder().call);
    final job =
        await runner2.run(jobId: 'ep', kind: 'transcribe', task: resumedTask);

    expect(job.state, JobState.done);
    expect(job.doneUnits, 6);

    // Byte-identical: the raw chunk state AND the assembled spine rows.
    expect(resumedTask.checkpoint(), referenceCheckpoint);
    expect(jsonEncode(resumedTask.buildResult().toJson()), referenceResult);

    // And it never restarted from zero: only the uncommitted, non-silent
    // windows reached the engine.
    expect(
      resumedTranscriber.transcribedStarts,
      [
        for (var u = landed; u < 6; u++)
          if (allStarts[u] != silentStart) allStarts[u]
      ],
    );
  }

  group('kill after the commit landed (boundaries 1..6)', () {
    for (var n = 1; n <= 6; n++) {
      test('killed after commit $n → resume is byte-identical', () async {
        await killAndResume(killOnCommit: n, commitLands: true);
      });
    }
  });

  group('kill before the commit applied (boundaries 0..5)', () {
    for (var n = 1; n <= 6; n++) {
      test('killed during commit $n (lost) → resume is byte-identical',
          () async {
        await killAndResume(killOnCommit: n, commitLands: false);
      });
    }
  });
}
