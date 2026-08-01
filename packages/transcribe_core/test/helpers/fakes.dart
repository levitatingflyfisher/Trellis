/// Test doubles for the transcription pipeline.
///
/// The clock/sleep/killing-store trio replicates jobs_core's kill-sweep
/// pattern (its helpers live in that package's test tree, deliberately not
/// in its public API). The PCM source and transcribers here are pure
/// functions of their inputs — the property tests lean on that.
library;

import 'dart:typed_data';

import 'package:jobs_core/jobs_core.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:transcribe_core/transcribe_core.dart';

/// Deterministic ms clock.
class FakeClock {
  int nowMs;
  FakeClock([this.nowMs = 1722700000000]);
  int now() => nowMs;
  void advance(int ms) {
    nowMs += ms;
  }
}

/// A sleep seam that never touches a timer.
class SleepRecorder {
  final List<int> slept = [];
  Future<void> call(int ms) async {
    slept.add(ms);
  }
}

/// Thrown to simulate the process dying mid-commit.
class KilledProcess implements Exception {
  @override
  String toString() => 'KilledProcess (simulated kill)';
}

/// Wraps a real store and kills the process at the Nth checkpoint commit —
/// either just after the commit landed or just before it applied.
class KillingStore implements JobStore {
  final JobStore inner;
  final int killOnCommit; // 1-based saveCheckpoint call number
  final bool commitLands;
  int _commits = 0;

  KillingStore(this.inner,
      {required this.killOnCommit, required this.commitLands});

  @override
  Future<Job?> load(String jobId) => inner.load(jobId);

  @override
  Future<void> save(Job job) => inner.save(job);

  @override
  Future<void> saveCheckpoint(
      String jobId, String checkpoint, int doneUnits) async {
    _commits++;
    if (_commits == killOnCommit) {
      if (commitLands) {
        await inner.saveCheckpoint(jobId, checkpoint, doneUnits);
      }
      throw KilledProcess();
    }
    await inner.saveCheckpoint(jobId, checkpoint, doneUnits);
  }

  @override
  Future<void> delete(String jobId) => inner.delete(jobId);
}

int fnv32(Iterable<int> values) {
  var h = 0x811c9dc5;
  for (final v in values) {
    h ^= v & 0xFF;
    h = (h * 0x01000193) & 0xFFFFFFFF;
    h ^= (v >> 8) & 0xFF;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

/// A seekable PCM source whose samples are a pure function of position.
///
/// Every window's first sample encodes `startMs + 1` (float32 carries
/// integers exactly up to 2^24), so a transcriber fake can recover WHICH
/// window it was handed from the samples alone. Windows listed in
/// [silentStarts] are all-zero — below any VAD threshold.
class ScriptedPcmSource implements PcmSource {
  @override
  final int sampleRate;
  @override
  final int totalMs;
  final Set<int> silentStarts;
  final List<(int, int)> readCalls = [];

  ScriptedPcmSource({
    required this.totalMs,
    this.sampleRate = 100,
    this.silentStarts = const {},
  });

  @override
  Future<Float32List> readWindow(int startMs, int lenMs) async {
    readCalls.add((startMs, lenMs));
    final n = (lenMs * sampleRate) ~/ 1000;
    final out = Float32List(n);
    if (silentStarts.contains(startMs)) return out; // all zeros
    for (var i = 0; i < n; i++) {
      out[i] = i == 0
          ? (startMs + 1).toDouble()
          : (((startMs ~/ 1000) * 31 + i) % 89 + 1) / 100.0;
    }
    return out;
  }
}

/// One recorded transcribe invocation, with the window start decoded from
/// the samples the fake actually received.
class SeenWindow {
  final int startMs;
  final int sampleCount;
  final String? lang;
  final WhisperTask task;
  final bool wordTimings;
  SeenWindow({
    required this.startMs,
    required this.sampleCount,
    required this.lang,
    required this.task,
    required this.wordTimings,
  });
}

Future<(int, Float32List)> _drainSingleWindow(PcmChunkSource src) async {
  final windows = await src.chunks().toList();
  if (windows.length != 1) {
    throw StateError('pipeline law: one window per transcribe call, '
        'got ${windows.length}');
  }
  final w = windows.single;
  final startMs = w.isEmpty ? -1 : w[0].round() - 1;
  return (startMs, w);
}

/// Replays a per-window script. Times in the script are window-relative,
/// exactly as a real engine reports them for the audio it was handed.
class WindowScriptTranscriber implements Transcriber {
  final Map<int, List<TranscriptChunk>> script; // startMs -> chunks
  final List<SeenWindow> seen = [];

  WindowScriptTranscriber(this.script);

  @override
  Stream<TranscriptChunk> transcribe(
    PcmChunkSource src, {
    String? lang,
    WhisperTask task = WhisperTask.transcribe,
    bool wordTimings = true,
  }) async* {
    final (startMs, w) = await _drainSingleWindow(src);
    seen.add(SeenWindow(
        startMs: startMs,
        sampleCount: w.length,
        lang: lang,
        task: task,
        wordTimings: wordTimings));
    for (final c in script[startMs] ?? const <TranscriptChunk>[]) {
      yield wordTimings ? c : c.copyWith(clearWords: true);
    }
  }
}

/// Output is a hash of the exact samples received — a pure function of the
/// audio, so any resume mistake that feeds different audio (wrong window,
/// wrong length, skipped or doubled unit) changes the final bytes.
class HashingTranscriber implements Transcriber {
  final List<int> transcribedStarts = [];

  @override
  Stream<TranscriptChunk> transcribe(
    PcmChunkSource src, {
    String? lang,
    WhisperTask task = WhisperTask.transcribe,
    bool wordTimings = true,
  }) async* {
    final (startMs, w) = await _drainSingleWindow(src);
    transcribedStarts.add(startMs);
    final h = fnv32(w.map((s) => (s * 1000).round()));
    final lenMs = (w.length * 1000) ~/ src.sampleRate;
    final text = 'w$startMs h${h.toRadixString(16)}.';
    yield TranscriptChunk(
      text: text,
      tStartMs: 0,
      tEndMs: lenMs,
      words: wordTimings
          ? [WordTiming(word: text, tStartMs: 0, tEndMs: lenMs)]
          : null,
    );
  }
}

/// Wraps a transcriber; for [failStarts] windows the stream emits one chunk
/// and then errors, [timesEach] times, before behaving normally — the
/// runner's retry path plus the task's buffer-then-append law under test.
class FlakyTranscriber implements Transcriber {
  final Transcriber inner;
  final Map<int, int> _failuresLeft;

  FlakyTranscriber(this.inner, {required Map<int, int> failStarts})
      : _failuresLeft = Map.of(failStarts);

  @override
  Stream<TranscriptChunk> transcribe(
    PcmChunkSource src, {
    String? lang,
    WhisperTask task = WhisperTask.transcribe,
    bool wordTimings = true,
  }) async* {
    final (startMs, w) = await _drainSingleWindow(src);
    final replay = _ReplaySource(w, src.sampleRate);
    final left = _failuresLeft[startMs] ?? 0;
    if (left > 0) {
      _failuresLeft[startMs] = left - 1;
      yield TranscriptChunk(text: 'partial garbage', tStartMs: 0, tEndMs: 1);
      throw StateError('transcriber flaked on window $startMs');
    }
    yield* inner.transcribe(replay,
        lang: lang, task: task, wordTimings: wordTimings);
  }
}

class _ReplaySource implements PcmChunkSource {
  final Float32List window;
  @override
  final int sampleRate;
  _ReplaySource(this.window, this.sampleRate);

  @override
  Stream<Float32List> chunks() => Stream.value(window);
}
