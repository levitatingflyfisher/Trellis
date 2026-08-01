import 'dart:convert';

import 'package:jobs_core/jobs_core.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:test/test.dart';
import 'package:transcribe_core/transcribe_core.dart';

import 'helpers/fakes.dart';

/// VAD gating (proposal-2 §5, the "Careless Whisper" mitigation): a silent
/// window never reaches the engine — hallucinated phrases concentrate in
/// silences — but the unit still counts and the checkpoint still advances.
void main() {
  // 60s -> windows at 0, 25000, 50000. The middle one is silent.
  ScriptedPcmSource makeSource() =>
      ScriptedPcmSource(totalMs: 60000, silentStarts: const {25000});

  Map<int, List<TranscriptChunk>> script() => {
        0: [TranscriptChunk(text: 'Before the pause.', tStartMs: 0, tEndMs: 4000)],
        25000: [
          TranscriptChunk(text: 'HALLUCINATED', tStartMs: 0, tEndMs: 1000)
        ],
        50000: [TranscriptChunk(text: 'After the pause.', tStartMs: 0, tEndMs: 2000)],
      };

  Future<Job> drive(TranscribeEpisodeTask task) {
    final clock = FakeClock();
    final runner = JobRunner(
        store: InMemoryJobStore(), now: clock.now, sleep: SleepRecorder().call);
    return runner.run(jobId: 'ep', kind: 'transcribe', task: task);
  }

  test('a silent window is skipped: the engine never hears it', () async {
    final transcriber = WindowScriptTranscriber(script());
    final task = TranscribeEpisodeTask(
        source: makeSource(),
        transcriber: transcriber,
        vad: FakeVad(),
        lang: 'sv',
        minSegmentChars: 1);
    final job = await drive(task);

    expect(job.state, JobState.done);
    expect(job.doneUnits, 3, reason: 'the silent unit still counts');
    expect(transcriber.seen.map((s) => s.startMs), [0, 50000]);

    final texts = task.buildResult().segments.map((s) => s.text);
    expect(texts, ['Before the pause.', 'After the pause.']);
    expect(texts, isNot(contains('HALLUCINATED')));
  });

  test('a silent unit commits an advanced checkpoint with no new chunks',
      () async {
    final task = TranscribeEpisodeTask(
        source: makeSource(),
        transcriber: WindowScriptTranscriber(script()),
        vad: FakeVad(),
        lang: 'sv',
        minSegmentChars: 1);

    await task.runUnit(0);
    final afterSpeech = jsonDecode(task.checkpoint()) as Map<String, dynamic>;
    await task.runUnit(1); // silent
    final afterSilence = jsonDecode(task.checkpoint()) as Map<String, dynamic>;

    expect(afterSilence['nextWindowStartMs'], 50000,
        reason: 'the checkpoint advances past the silent window');
    expect(afterSilence['chunks'], afterSpeech['chunks'],
        reason: 'silence adds nothing');
    expect((afterSilence['chunks'] as List), hasLength(1));
  });

  test('without a Vad the gate is open: every window reaches the engine',
      () async {
    final transcriber = WindowScriptTranscriber(script());
    final task = TranscribeEpisodeTask(
        source: makeSource(),
        transcriber: transcriber,
        lang: 'sv',
        minSegmentChars: 1);
    await drive(task);
    expect(transcriber.seen, hasLength(3),
        reason: 'gating is opt-in; the silent window went through');
  });

  test('an entirely silent episode completes with an empty transcript',
      () async {
    final transcriber = WindowScriptTranscriber(script());
    final task = TranscribeEpisodeTask(
        source: ScriptedPcmSource(
            totalMs: 60000, silentStarts: const {0, 25000, 50000}),
        transcriber: transcriber,
        vad: FakeVad(),
        lang: 'sv');
    final job = await drive(task);

    expect(job.state, JobState.done);
    expect(job.doneUnits, 3);
    expect(transcriber.seen, isEmpty);
    final result = task.buildResult();
    expect(result.segments, isEmpty);
    expect(result.alignments, isEmpty);
    expect(result.layers, isEmpty);
  });
}
