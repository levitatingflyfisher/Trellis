import 'package:jobs_core/jobs_core.dart';
import 'package:loom_core/loom_core.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:test/test.dart';
import 'package:transcribe_core/transcribe_core.dart';

import 'helpers/fakes.dart';

/// The translate variant: the same windowed pipeline with Whisper's built-in
/// translate task, whose output is English no matter the source language —
/// so the layer rows are `mt` in `'en'`, never `transcript` in the source
/// language.
void main() {
  WindowScriptTranscriber makeTranscriber() => WindowScriptTranscriber({
        0: [TranscriptChunk(text: 'Hello friends.', tStartMs: 0, tEndMs: 4000)],
        25000: [
          TranscriptChunk(text: 'The weather is fine.', tStartMs: 0, tEndMs: 2500)
        ],
        50000: [TranscriptChunk(text: 'Goodbye.', tStartMs: 0, tEndMs: 1500)],
      });

  Future<Job> drive(TranscribeEpisodeTask task) {
    final clock = FakeClock();
    final runner = JobRunner(
        store: InMemoryJobStore(), now: clock.now, sleep: SleepRecorder().call);
    return runner.run(jobId: 'ep', kind: 'translate', task: task);
  }

  test('the engine is asked to translate, with the source-language hint',
      () async {
    final transcriber = makeTranscriber();
    final task = TranscribeEpisodeTask(
        source: ScriptedPcmSource(totalMs: 60000),
        transcriber: transcriber,
        task: WhisperTask.translate,
        lang: 'sv',
        minSegmentChars: 1);
    final job = await drive(task);

    expect(job.state, JobState.done);
    expect(transcriber.seen.map((s) => s.startMs), [0, 25000, 50000]);
    for (final s in transcriber.seen) {
      expect(s.task, WhisperTask.translate);
      expect(s.lang, 'sv', reason: 'the hint names the SOURCE language');
    }
  });

  test("the result is an 'en' mt layer, not a source-language transcript",
      () async {
    final task = TranscribeEpisodeTask(
        source: ScriptedPcmSource(totalMs: 60000),
        transcriber: makeTranscriber(),
        task: WhisperTask.translate,
        lang: 'sv',
        minSegmentChars: 1);
    await drive(task);
    final result = task.buildResult();

    expect(result.lang, 'en');
    expect(result.layerKind, LayerKind.mt);
    expect(result.segments.map((s) => s.text),
        ['Hello friends.', 'The weather is fine.', 'Goodbye.']);
    for (final l in result.layers) {
      expect(l.lang, 'en');
      expect(l.kind, LayerKind.mt);
    }
    expect(result.alignments, hasLength(3));
  });

  test('the detector never overrides translate: output is en by definition',
      () async {
    var detectorCalls = 0;
    final task = TranscribeEpisodeTask(
        source: ScriptedPcmSource(totalMs: 60000),
        transcriber: makeTranscriber(),
        task: WhisperTask.translate,
        detectLang: (_) {
          detectorCalls++;
          return 'sv';
        },
        minSegmentChars: 1);
    await drive(task);

    expect(task.buildResult().lang, 'en');
    expect(detectorCalls, 0);
  });
}
