import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jobs_core/jobs_core.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:transcribe_core/transcribe_core.dart' show LangSource;
import 'package:trellis/features/transcribe/transcribe_executor.dart';
import 'package:whisper_ffi/whisper_ffi.dart';

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

  group('language lock and the job-scoped engine', () {
    // Four words: a shorter window is not trusted to name the language.
    List<String> speech() => [
          jsonEncode({'text': 'hello there my friend.', 't0': 0, 't1': 500}),
        ];

    TranscribeSpec detecting({String jobId = 'job-1'}) => TranscribeSpec(
          jobId: jobId,
          pcmPath: pcmPath(),
          task: WhisperTask.transcribe,
          engine: ScriptedEngineSpec(chunkJsons: speech(), detectedLang: 'ru'),
          windowMs: 1000,
          overlapMs: 200,
        );

    test('without a language the first window detects it and the job '
        'keeps it; the engine is closed once when the job ends', () async {
      final before = ScriptedEngineSpec.closes;
      final store = InMemoryJobStore();
      final outcome =
          await InlineTranscribeExecutor().start(detecting(), store).done;
      expect(outcome.state, JobState.done);
      expect(jsonDecode((await store.load('job-1'))!.checkpoint!)['lang'], 'ru');
      expect(ScriptedEngineSpec.closes, before + 1);
    });

    test('a cancelled job closes its engine too, and the resume keeps the '
        'detected language from the checkpoint', () async {
      final store = InMemoryJobStore();
      final before = ScriptedEngineSpec.closes;
      final run = InlineTranscribeExecutor().start(detecting(), store);
      final sub = run.progress.listen(null);
      sub.onData((p) {
        if (p.doneUnits >= 1) run.cancel();
      });
      expect((await run.done).state, JobState.cancelled);
      await sub.cancel();
      expect(ScriptedEngineSpec.closes, before + 1);
      expect(jsonDecode((await store.load('job-1'))!.checkpoint!)['lang'], 'ru');

      final resumed = TranscribeSpec(
          jobId: 'job-1',
          pcmPath: pcmPath(),
          task: WhisperTask.transcribe,
          engine: ScriptedEngineSpec(chunkJsons: speech(), detectedLang: 'de'),
          windowMs: 1000,
          overlapMs: 200);
      final outcome = await InlineTranscribeExecutor().start(resumed, store).done;
      expect(outcome.state, JobState.done);
      expect(jsonDecode((await store.load('job-1'))!.checkpoint!)['lang'], 'ru',
          reason: 'no second detection');
    });

    test('the language and its source cross the isolate boundary', () {
      final s = TranscribeSpec.fromMap(TranscribeSpec(
              jobId: 'j',
              pcmPath: 'p',
              task: WhisperTask.transcribe,
              lang: 'es',
              langSource: 'feed',
              engine: ScriptedEngineSpec(chunkJsons: const [], detectedLang: 'ru'))
          .toMap());
      expect(s.lang, 'es');
      expect(s.langSource, 'feed');
      expect((s.engine as ScriptedEngineSpec).detectedLang, 'ru');
    });

    test('the whisper engine is built to keep its context between windows',
        () {
      Never unused([Object? a, Object? b, Object? c]) =>
          throw StateError('no native call expected');
      final bindings = WhisperBindings(
        initFromFile: unused,
        free: unused,
        full: (a, b, c, d, e, f, g, h) => unused(),
        nSegments: unused,
        segmentText: unused,
        segmentT0: unused,
        segmentT1: unused,
        nTokens: unused,
        tokenText: unused,
        tokenT0: unused,
        tokenT1: unused,
        tokenIsSpecial: unused,
      );
      final t = WhisperEngineSpec(modelPath: 'm', libraryPath: 'l')
          .transcriberFor(bindings);
      expect(t.keepContext, isTrue);
      expect(t.modelPath, 'm');
    });

    test('a hint with no recorded source is the declared one, never the '
        'feed\'s', () {
      expect(transcribeLangSource(LangSource.hint, null), 'declared');
      expect(transcribeLangSource(LangSource.hint, 'feed'), 'feed');
      expect(transcribeLangSource(LangSource.detected, 'feed'), 'detected');
      expect(transcribeLangSource(LangSource.auto, null), 'auto');
    });

    test('an engine that throws on every attempt fails the job and is still '
        'closed once', () async {
      final before = ScriptedEngineSpec.closes;
      final store = InMemoryJobStore();
      final failing = TranscribeSpec(
          jobId: 'job-1',
          pcmPath: pcmPath(),
          task: WhisperTask.transcribe,
          lang: 'en',
          engine: ScriptedEngineSpec(chunkJsons: script(), throws: true),
          windowMs: 1000,
          overlapMs: 200);
      final outcome = await InlineTranscribeExecutor().start(failing, store).done;
      expect(outcome.state, JobState.failed);
      expect(ScriptedEngineSpec.closes, before + 1);
    });

    test('the reason for a baseline fallback crosses the isolate boundary',
        () {
      final s = TranscribeSpec.fromMap(TranscribeSpec(
              jobId: 'j',
              pcmPath: 'p',
              task: WhisperTask.transcribe,
              engine: WhisperEngineSpec(
                  modelPath: 'm',
                  libraryPath: 'libwhisper.so',
                  libraryNote: 'no dotprod'))
          .toMap());
      expect((s.engine as WhisperEngineSpec).libraryNote, 'no dotprod');
    });

    test('the run log line names the build, the language and its source',
        () {
      final line = transcribeLogLine(
          windows: 120,
          perWindowMs: 2851,
          threads: 4,
          lib: 'dotprod',
          lang: 'en',
          langSource: 'feed',
          task: WhisperTask.transcribe,
          state: JobState.done);
      expect(line,
          'Trellis transcribe: 120 windows, 2851 ms each, threads 4, '
          'lib dotprod, lang en (feed), transcribe, done');
      expect(
          transcribeLogLine(
              windows: 1,
              perWindowMs: 1,
              threads: 1,
              lib: 'baseline',
              lang: null,
              langSource: 'auto',
              task: WhisperTask.translate,
              state: JobState.cancelled),
          contains('lib baseline, lang auto (auto)'));
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
