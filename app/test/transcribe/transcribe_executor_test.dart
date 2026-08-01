import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jobs_core/jobs_core.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:trellis/features/transcribe/transcribe_executor.dart';

/// The executor seam: the same checkpointed run (jobs_core runner +
/// transcribe_core task) driven inline (widget tests, fallback) or in a real
/// background isolate with the JobStore proxied back to this side — the
/// store, and so Drift, never leaves the main isolate.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('trellis-exec');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  /// 5 seconds of silent 16kHz f32 PCM.
  String pcmPath() {
    final f = File('${tmp.path}/audio.f32')
      ..writeAsBytesSync(Uint8List(5 * 16000 * 4));
    return f.path;
  }

  /// One deterministic scripted chunk per window (relative times).
  List<String> script() => [
        jsonEncode({
          'text': 'hello there.',
          't0': 0,
          't1': 500,
          'words': [
            ['hello', 0, 200],
            ['there.', 200, 500],
          ],
        }),
      ];

  TranscribeSpec spec({String jobId = 'job-1'}) => TranscribeSpec(
        jobId: jobId,
        pcmPath: pcmPath(),
        task: WhisperTask.transcribe,
        lang: 'en',
        engine: ScriptedEngineSpec(chunkJsons: script()),
        windowMs: 1000,
        overlapMs: 200,
      );

  group('InlineTranscribeExecutor', () {
    test('runs a job to done with progress and a result', () async {
      final store = InMemoryJobStore();
      final run = InlineTranscribeExecutor().start(spec(), store);

      final beats = <TranscribeProgress>[];
      run.progress.listen(beats.add);
      final outcome = await run.done;

      expect(outcome.state, JobState.done);
      expect(outcome.result, isNotNull);
      expect(outcome.result!.lang, 'en');
      expect(outcome.result!.segments, isNotEmpty);
      expect(beats, isNotEmpty);
      expect(beats.last.doneUnits, beats.last.totalUnits);
      expect((await store.load('job-1'))!.state, JobState.done);
    });

    test('cancel keeps the checkpoint; a fresh run resumes to the same '
        'transcript', () async {
      // Reference: one uninterrupted run.
      final refStore = InMemoryJobStore();
      final ref =
          await InlineTranscribeExecutor().start(spec(jobId: 'ref'), refStore).done;
      final reference = jsonEncode(ref.result!.toJson());

      final store = InMemoryJobStore();
      final s = spec();
      final run = InlineTranscribeExecutor().start(s, store);
      final sub = run.progress.listen(null);
      sub.onData((p) {
        if (p.doneUnits >= 1) run.cancel();
      });
      final outcome = await run.done;
      await sub.cancel();

      expect(outcome.state, JobState.cancelled);
      expect(outcome.result, isNull, reason: 'a partial transcript must '
          'never masquerade as the episode');
      final row = await store.load('job-1');
      expect(row!.state, JobState.cancelled);
      expect(row.checkpoint, isNotNull);
      expect(row.doneUnits, greaterThanOrEqualTo(1));
      expect(row.doneUnits, lessThan(row.totalUnits));

      // Resume: fresh executor, same store — byte-identical to the clean run.
      final resumed = await InlineTranscribeExecutor().start(s, store).done;
      expect(resumed.state, JobState.done);
      expect(jsonEncode(resumed.result!.toJson()), reference);
    });

    test('a job already done in the store yields its result without '
        're-running', () async {
      final store = InMemoryJobStore();
      final s = spec();
      await InlineTranscribeExecutor().start(s, store).done;

      final again = await InlineTranscribeExecutor().start(s, store).done;
      expect(again.state, JobState.done);
      expect(again.result, isNotNull);
    });
  });

  group('IsolateTranscribeExecutor', () {
    test('runs the job in a real isolate against the main-side store',
        () async {
      final store = InMemoryJobStore();
      final run = IsolateTranscribeExecutor().start(spec(), store);

      final beats = <TranscribeProgress>[];
      run.progress.listen(beats.add);
      final outcome = await run.done;

      expect(outcome.state, JobState.done);
      expect(outcome.result!.segments, isNotEmpty);
      expect(beats, isNotEmpty);
      final row = await store.load('job-1');
      expect(row!.state, JobState.done,
          reason: 'checkpoints must have crossed the port into THIS store');
      expect(row.doneUnits, row.totalUnits);
    });

    test('matches the inline executor chunk for chunk', () async {
      final inline =
          await InlineTranscribeExecutor().start(spec(jobId: 'a'), InMemoryJobStore()).done;
      final isolate =
          await IsolateTranscribeExecutor().start(spec(jobId: 'b'), InMemoryJobStore()).done;
      expect(jsonEncode(isolate.result!.toJson()),
          jsonEncode(inline.result!.toJson()));
    });

    test('cancel crosses the port: checkpoint kept, resume completes',
        () async {
      final store = InMemoryJobStore();
      final s = spec();
      final run = IsolateTranscribeExecutor().start(s, store);
      final sub = run.progress.listen(null);
      sub.onData((p) {
        if (p.doneUnits >= 1) run.cancel();
      });
      final outcome = await run.done;
      await sub.cancel();

      expect(outcome.state, JobState.cancelled);
      final row = await store.load('job-1');
      expect(row!.state, JobState.cancelled);
      expect(row.checkpoint, isNotNull);

      final resumed = await IsolateTranscribeExecutor().start(s, store).done;
      expect(resumed.state, JobState.done);
      expect(resumed.result, isNotNull);
    });
  });
}
