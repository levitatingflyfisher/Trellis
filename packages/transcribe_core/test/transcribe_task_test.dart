import 'dart:convert';

import 'package:jobs_core/jobs_core.dart';
import 'package:loom_core/loom_core.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:test/test.dart';
import 'package:transcribe_core/transcribe_core.dart';

import 'helpers/fakes.dart';

/// 60s of audio under the canonical 30s/5s recipe: windows at 0, 25000 and
/// 50000ms (the last one 10s long). sampleRate 100 keeps windows small.
ScriptedPcmSource makeSource({int totalMs = 60000}) =>
    ScriptedPcmSource(totalMs: totalMs);

WindowScriptTranscriber makeTranscriber() => WindowScriptTranscriber({
      0: [TranscriptChunk(text: 'Hello there.', tStartMs: 0, tEndMs: 4000)],
      25000: [
        TranscriptChunk(text: 'General Kenobi!', tStartMs: 0, tEndMs: 2000, words: [
          WordTiming(word: 'General', tStartMs: 0, tEndMs: 800),
          WordTiming(word: 'Kenobi!', tStartMs: 900, tEndMs: 2000),
        ]),
      ],
      50000: [TranscriptChunk(text: 'Bye.', tStartMs: 500, tEndMs: 1500)],
    });

Future<Job> drive(TranscribeEpisodeTask task,
    {JobStore? store, String jobId = 'ep'}) {
  final clock = FakeClock();
  final runner = JobRunner(
      store: store ?? InMemoryJobStore(),
      now: clock.now,
      sleep: SleepRecorder().call);
  return runner.run(jobId: jobId, kind: 'transcribe', task: task);
}

void main() {
  group('shape', () {
    test('totalUnits follows the window plan over the source length', () {
      final task = TranscribeEpisodeTask(
          source: makeSource(), transcriber: makeTranscriber());
      expect(task.totalUnits, 3);

      final empty = TranscribeEpisodeTask(
          source: makeSource(totalMs: 0), transcriber: makeTranscriber());
      expect(empty.totalUnits, 0);
    });
  });

  group('pipeline through the runner', () {
    test('each unit transcribes exactly its window', () async {
      final source = makeSource();
      final transcriber = makeTranscriber();
      final task = TranscribeEpisodeTask(
          source: source,
          transcriber: transcriber,
          lang: 'sv',
          minSegmentChars: 1);

      final job = await drive(task);
      expect(job.state, JobState.done);
      expect(job.doneUnits, 3);

      expect(source.readCalls, [(0, 30000), (25000, 30000), (50000, 10000)]);
      expect(transcriber.seen.map((s) => s.startMs), [0, 25000, 50000]);
      expect(transcriber.seen.map((s) => s.sampleCount), [3000, 3000, 1000]);
      for (final s in transcriber.seen) {
        expect(s.lang, 'sv');
        expect(s.task, WhisperTask.transcribe);
        expect(s.wordTimings, isTrue);
      }
    });

    test('chunk times are shifted from window-relative to absolute', () async {
      final task = TranscribeEpisodeTask(
          source: makeSource(),
          transcriber: makeTranscriber(),
          lang: 'sv',
          minSegmentChars: 1);
      await drive(task);

      final merged = task.buildResult().mergedChunks;
      expect(merged.map((c) => (c.tStartMs, c.tEndMs)),
          [(0, 4000), (25000, 27000), (50500, 51500)]);
      final words = merged[1].words!;
      expect(words.map((w) => (w.tStartMs, w.tEndMs)),
          [(25000, 25800), (25900, 27000)]);
    });

    test('the result is spine-ready: segments, alignments, layers', () async {
      final task = TranscribeEpisodeTask(
          source: makeSource(),
          transcriber: makeTranscriber(),
          lang: 'sv',
          minSegmentChars: 1);
      await drive(task);
      final result = task.buildResult();

      expect(result.lang, 'sv');
      expect(result.layerKind, LayerKind.transcript);
      expect(result.segments.map((s) => s.text),
          ['Hello there.', 'General Kenobi!', 'Bye.']);
      for (var i = 0; i < result.segments.length; i++) {
        expect(result.segments[i].idx, i);
        expect(result.segments[i].kind, SegmentKind.prose);
      }
      expect(
          result.alignments.map((a) => (a.segmentIdx, a.tStartMs, a.tEndMs)),
          [(0, 0, 4000), (1, 25000, 27000), (2, 50500, 51500)]);
      for (var i = 0; i < result.layers.length; i++) {
        final l = result.layers[i];
        expect(l.segmentIdx, i);
        expect(l.lang, 'sv');
        expect(l.kind, LayerKind.transcript);
        expect(l.text, result.segments[i].text);
      }
    });

    test('the spine accepts the result and projects through it', () async {
      final task = TranscribeEpisodeTask(
          source: makeSource(),
          transcriber: makeTranscriber(),
          lang: 'sv',
          minSegmentChars: 1);
      await drive(task);
      final result = task.buildResult();

      final spine = Spine(
          segments: result.segments,
          layers: result.layers,
          alignments: result.alignments);
      final pos = spine.positionAtAudioTime(26000);
      expect(pos.segmentIdx, 1);
      expect(spine.projectText(pos, lang: 'sv'), 'General Kenobi!');
    });

    test('segment length bounds default to the sentence-ish recipe', () async {
      // With the default minSegmentChars, the short tail 'Bye.' merges back.
      final task = TranscribeEpisodeTask(
          source: makeSource(), transcriber: makeTranscriber(), lang: 'sv');
      await drive(task);
      expect(task.buildResult().segments.map((s) => s.text),
          ['Hello there.', 'General Kenobi! Bye.']);
    });

    test('an empty episode completes with an empty result', () async {
      final transcriber = makeTranscriber();
      final task = TranscribeEpisodeTask(
          source: makeSource(totalMs: 0), transcriber: transcriber);
      final job = await drive(task);
      expect(job.state, JobState.done);
      expect(transcriber.seen, isEmpty);

      final result = task.buildResult();
      expect(result.segments, isEmpty);
      expect(result.alignments, isEmpty);
      expect(result.layers, isEmpty);
      expect(result.mergedChunks, isEmpty);
    });

    test('wordTimings: false is passed through and honored', () async {
      final transcriber = makeTranscriber();
      final task = TranscribeEpisodeTask(
          source: makeSource(),
          transcriber: transcriber,
          lang: 'sv',
          wordTimings: false,
          minSegmentChars: 1);
      await drive(task);
      expect(transcriber.seen.every((s) => s.wordTimings == false), isTrue);
      expect(task.buildResult().mergedChunks.every((c) => c.words == null),
          isTrue);
    });
  });

  group('checkpoint law', () {
    test('checkpoint = {nextWindowStartMs, chunks so far}', () async {
      final task = TranscribeEpisodeTask(
          source: makeSource(),
          transcriber: makeTranscriber(),
          lang: 'sv',
          minSegmentChars: 1);
      await task.runUnit(0);

      final decoded = jsonDecode(task.checkpoint()) as Map<String, dynamic>;
      expect(decoded['nextWindowStartMs'], 25000);
      final chunks = decoded['chunks'] as List;
      expect(chunks, hasLength(1));
      final first = chunks.first as Map<String, dynamic>;
      expect(first['text'], 'Hello there.');
      expect(first['t0'], 0);
      expect(first['t1'], 4000);
    });

    test('restore into a fresh instance reproduces the checkpoint bytes',
        () async {
      final task = TranscribeEpisodeTask(
          source: makeSource(),
          transcriber: makeTranscriber(),
          lang: 'sv',
          minSegmentChars: 1);
      await task.runUnit(0);
      await task.runUnit(1);
      final cp = task.checkpoint();

      final fresh = TranscribeEpisodeTask(
          source: makeSource(),
          transcriber: makeTranscriber(),
          lang: 'sv',
          minSegmentChars: 1);
      fresh.restore(cp);
      expect(fresh.checkpoint(), cp);

      await fresh.runUnit(2);
      await task.runUnit(2);
      expect(jsonEncode(fresh.buildResult().toJson()),
          jsonEncode(task.buildResult().toJson()));
    });

    test('running a unit out of order is refused', () async {
      final task = TranscribeEpisodeTask(
          source: makeSource(), transcriber: makeTranscriber());
      await expectLater(task.runUnit(1), throwsStateError);
    });

    test('buildResult before every unit committed is refused', () async {
      final task = TranscribeEpisodeTask(
          source: makeSource(), transcriber: makeTranscriber());
      expect(() => task.buildResult(), throwsStateError);
      await task.runUnit(0);
      expect(() => task.buildResult(), throwsStateError);
    });
  });

  group('language', () {
    test('an explicit lang wins and the detector is never consulted',
        () async {
      var detectorCalls = 0;
      final task = TranscribeEpisodeTask(
          source: makeSource(),
          transcriber: makeTranscriber(),
          lang: 'sv',
          detectLang: (_) {
            detectorCalls++;
            return 'eo';
          },
          minSegmentChars: 1);
      await drive(task);
      expect(task.buildResult().lang, 'sv');
      expect(detectorCalls, 0);
    });

    test('without a lang the detector sees the merged chunks and decides',
        () async {
      List<TranscriptChunk>? seenByDetector;
      final task = TranscribeEpisodeTask(
          source: makeSource(),
          transcriber: makeTranscriber(),
          detectLang: (merged) {
            seenByDetector = merged;
            return 'eo';
          },
          minSegmentChars: 1);
      await drive(task);
      final result = task.buildResult();
      expect(result.lang, 'eo');
      expect(result.layers.every((l) => l.lang == 'eo'), isTrue);
      expect(seenByDetector, hasLength(3));
    });

    test('no lang, no detector answer: honest undetermined', () async {
      final a = TranscribeEpisodeTask(
          source: makeSource(),
          transcriber: makeTranscriber(),
          minSegmentChars: 1);
      await drive(a);
      expect(a.buildResult().lang, 'und');

      final b = TranscribeEpisodeTask(
          source: makeSource(),
          transcriber: makeTranscriber(),
          detectLang: (_) => null,
          minSegmentChars: 1);
      await drive(b);
      expect(b.buildResult().lang, 'und');
    });
  });

  group('mid-unit failure', () {
    test('a flaky window retries clean: no partial chunks ever land',
        () async {
      final clean = TranscribeEpisodeTask(
          source: makeSource(),
          transcriber: makeTranscriber(),
          lang: 'sv',
          minSegmentChars: 1);
      await drive(clean);
      final reference = jsonEncode(clean.buildResult().toJson());

      final flakyTask = TranscribeEpisodeTask(
          source: makeSource(),
          transcriber: FlakyTranscriber(makeTranscriber(),
              failStarts: {25000: 2}),
          lang: 'sv',
          minSegmentChars: 1);
      final job = await drive(flakyTask);
      expect(job.state, JobState.done);
      expect(job.checkpoint, isNot(contains('partial garbage')));
      expect(jsonEncode(flakyTask.buildResult().toJson()), reference);
    });
  });
}
