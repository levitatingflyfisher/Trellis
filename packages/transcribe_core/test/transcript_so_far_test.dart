import 'dart:convert';

import 'package:jobs_core/jobs_core.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:test/test.dart';
import 'package:transcribe_core/transcribe_core.dart';

import 'helpers/fakes.dart';

/// The transcript as it is made: [transcriptSoFar] assembles whatever the
/// committed checkpoint holds, through the same merge and segmentize as
/// [TranscribeEpisodeTask.buildResult]. Because it is a pure function of
/// the checkpoint, a kill leaves exactly the partial transcript of the last
/// committed window, and a resume replaces it without repeating a word.
void main() {
  // 100s: windows at 0, 25, 50 and 75 s. Each window hears the seam it
  // shares with the next, as whisper does, so the overlap merge has work.
  const totalMs = 100000;
  WindowScriptTranscriber script() => WindowScriptTranscriber({
        0: [
          TranscriptChunk(text: 'One fish.', tStartMs: 1000, tEndMs: 4000),
          TranscriptChunk(
              text: 'Two fish swim by.', tStartMs: 26000, tEndMs: 29000),
        ],
        25000: [
          // The same words, heard again at the start of the next window.
          TranscriptChunk(
              text: 'Two fish swim by.', tStartMs: 1000, tEndMs: 4000),
          TranscriptChunk(text: 'Red fish.', tStartMs: 10000, tEndMs: 12000),
        ],
        50000: [
          TranscriptChunk(text: 'Blue fish.', tStartMs: 3000, tEndMs: 6000),
        ],
        75000: [
          TranscriptChunk(text: 'The end.', tStartMs: 5000, tEndMs: 8000),
        ],
      });

  TranscribeEpisodeTask makeTask() => TranscribeEpisodeTask(
        source: ScriptedPcmSource(totalMs: totalMs),
        transcriber: script(),
        lang: 'en',
        minSegmentChars: 1,
      );

  /// Every committed checkpoint of an uninterrupted run, in order.
  Future<(List<String>, TranscribeEpisodeTask)> reference() async {
    final store = _RecordingStore(InMemoryJobStore());
    final task = makeTask();
    final job = await JobRunner(
            store: store, now: FakeClock().now, sleep: SleepRecorder().call)
        .run(jobId: 'ep', kind: 'transcribe', task: task);
    expect(job.state, JobState.done);
    return (store.checkpoints, task);
  }

  String text(TranscriptionResult r) =>
      [for (final s in r.segments) s.text].join(' ');

  test('the whole checkpoint assembles to exactly the finished result',
      () async {
    final (checkpoints, task) = await reference();
    expect(jsonEncode(transcriptSoFar(checkpoints.last, lang: 'en').toJson()),
        jsonEncode(task.buildResult().toJson()));
  });

  test(
      'each window adds its words, and the seam two windows heard is said '
      'once', () async {
    final (checkpoints, _) = await reference();
    expect(checkpoints, hasLength(4));
    final texts = [
      for (final c in checkpoints) text(transcriptSoFar(c, lang: 'en'))
    ];
    expect(texts, [
      'One fish. Two fish swim by.',
      'One fish. Two fish swim by. Red fish.',
      'One fish. Two fish swim by. Red fish. Blue fish.',
      'One fish. Two fish swim by. Red fish. Blue fish. The end.',
    ]);
    // Rows that are spine-ready at every step: one layer and one
    // alignment per segment, in transcript order.
    for (final c in checkpoints) {
      final r = transcriptSoFar(c, lang: 'en');
      expect(r.layers.map((l) => l.segmentIdx),
          [for (var i = 0; i < r.segments.length; i++) i]);
      expect(r.alignments.map((a) => a.segmentIdx),
          [for (var i = 0; i < r.segments.length; i++) i]);
    }
  });

  test('a translate run is labelled as English translation so far', () {
    final cp = jsonEncode({
      'nextWindowStartMs': 25000,
      'chunks': [
        {'text': 'Hello.', 't0': 0, 't1': 1000, 'words': null}
      ],
    });
    final r = transcriptSoFar(cp, task: WhisperTask.translate, lang: 'sv');
    expect(r.lang, 'en');
    expect(r.layers.single.kind.name, 'mt');
  });

  test('before any window lands there is nothing to show', () {
    final r = transcriptSoFar(
        jsonEncode({'nextWindowStartMs': 0, 'chunks': []}),
        lang: 'en');
    expect(r.segments, isEmpty);
  });

  group(
      'a kill at any window leaves the partial of the last committed '
      'window, and the resume never repeats a word', () {
    for (var kill = 1; kill <= 4; kill++) {
      for (final lands in [true, false]) {
        test('killed at commit $kill (${lands ? 'landed' : 'lost'})', () async {
          final (checkpoints, finished) = await reference();
          final store = InMemoryJobStore();
          await expectLater(
              JobRunner(
                      store: KillingStore(store,
                          killOnCommit: kill, commitLands: lands),
                      now: FakeClock().now,
                      sleep: SleepRecorder().call)
                  .run(jobId: 'ep', kind: 'transcribe', task: makeTask()),
              throwsA(isA<KilledProcess>()));

          final orphan = (await store.load('ep'))!;
          final committed = lands ? kill : kill - 1;
          if (committed == 0) {
            expect(orphan.checkpoint, isNull);
          } else {
            // What the reader sees after the kill: the uninterrupted run's
            // transcript at the same window, byte for byte.
            expect(
                jsonEncode(
                    transcriptSoFar(orphan.checkpoint!, lang: 'en').toJson()),
                jsonEncode(
                    transcriptSoFar(checkpoints[committed - 1], lang: 'en')
                        .toJson()));
          }

          final resumed = _RecordingStore(store);
          await JobRunner(
                  store: resumed,
                  now: FakeClock().now,
                  sleep: SleepRecorder().call)
              .run(jobId: 'ep', kind: 'transcribe', task: makeTask());
          // Every partial the resumed run shows matches the reference's at
          // that window, and the last is the finished transcript.
          expect(resumed.checkpoints, checkpoints.sublist(committed));
          final last = resumed.checkpoints.isEmpty
              ? orphan.checkpoint!
              : resumed.checkpoints.last;
          expect(jsonEncode(transcriptSoFar(last, lang: 'en').toJson()),
              jsonEncode(finished.buildResult().toJson()));
        });
      }
    }
  });
}

class _RecordingStore implements JobStore {
  final JobStore inner;
  final List<String> checkpoints = [];
  _RecordingStore(this.inner);

  @override
  Future<Job?> load(String jobId) => inner.load(jobId);

  @override
  Future<void> save(Job job) => inner.save(job);

  @override
  Future<void> saveCheckpoint(
      String jobId, String checkpoint, int doneUnits) async {
    checkpoints.add(checkpoint);
    await inner.saveCheckpoint(jobId, checkpoint, doneUnits);
  }

  @override
  Future<void> delete(String jobId) => inner.delete(jobId);
}
