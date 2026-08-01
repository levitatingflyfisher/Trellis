/// Scripted, deterministic fakes for the ML seams.
///
/// These are the app's test doubles for the FFI engines: same script, same
/// output, every time — no clocks, no randomness, no platform. Each fake
/// records its calls so tests can assert on how the seam was used.
library;

import 'dart:typed_data';

import 'seams.dart';
import 'transcript.dart';

/// A [PcmChunkSource] that replays a fixed list of windows.
class ListPcmSource implements PcmChunkSource {
  final List<Float32List> windows;

  @override
  final int sampleRate;

  ListPcmSource(this.windows, {this.sampleRate = 16000});

  @override
  Stream<Float32List> chunks() => Stream.fromIterable(windows);
}

/// One recorded [FakeTranscriber.transcribe] invocation.
class TranscribeCall {
  final PcmChunkSource src;
  final String? lang;
  final WhisperTask task;
  final bool wordTimings;

  const TranscribeCall({
    required this.src,
    required this.lang,
    required this.task,
    required this.wordTimings,
  });
}

/// Emits a fixed script of [TranscriptChunk]s, in order, on every call.
///
/// When called with `wordTimings: false` the emitted chunks carry no word
/// timings, mirroring the real engine's contract. The source is accepted but
/// not consumed — scripting decides the output, not the audio.
class FakeTranscriber implements Transcriber {
  final List<TranscriptChunk> script;
  final List<TranscribeCall> calls = [];

  FakeTranscriber(List<TranscriptChunk> script) : script = List.unmodifiable(script);

  @override
  Stream<TranscriptChunk> transcribe(
    PcmChunkSource src, {
    String? lang,
    WhisperTask task = WhisperTask.transcribe,
    bool wordTimings = true,
  }) {
    calls.add(TranscribeCall(
        src: src, lang: lang, task: task, wordTimings: wordTimings));
    final emissions = wordTimings
        ? script
        : script.map((c) => c.copyWith(clearWords: true)).toList();
    return Stream.fromIterable(emissions);
  }
}

/// One recorded [FakeSynthesizer.synthesize] invocation.
class SynthesizeCall {
  final List<String> texts;
  final Voice voice;

  const SynthesizeCall({required this.texts, required this.voice});
}

/// Renders each input text to a deterministic [AudioChunk]: one chunk per
/// text, `runes * samplesPerRune` samples, every sample value a pure
/// function of its position and chunk index. No randomness, no clock.
class FakeSynthesizer implements Synthesizer {
  final int samplesPerRune;
  final int sampleRate;
  final List<SynthesizeCall> calls = [];

  FakeSynthesizer({this.samplesPerRune = 160, this.sampleRate = 16000}) {
    if (samplesPerRune <= 0) {
      throw ArgumentError('samplesPerRune must be positive');
    }
  }

  @override
  Stream<AudioChunk> synthesize(Iterable<String> texts, Voice voice) {
    final list = List<String>.unmodifiable(texts);
    calls.add(SynthesizeCall(texts: list, voice: voice));
    return Stream.fromIterable([
      for (var i = 0; i < list.length; i++) _render(i, list[i]),
    ]);
  }

  AudioChunk _render(int index, String text) {
    final n = text.runes.length * samplesPerRune;
    final samples = Float32List(n);
    for (var s = 0; s < n; s++) {
      // Deterministic, bounded, non-trivial: distinguishes chunks and
      // positions without any source of nondeterminism.
      samples[s] = (((index + 1) * 31 + s) % 997) / 997.0;
    }
    return AudioChunk(inputIndex: index, samples: samples, sampleRate: sampleRate);
  }
}

/// Peak-amplitude voice-activity detection: speech iff any sample's
/// magnitude exceeds [threshold]. Deterministic by construction.
class FakeVad implements Vad {
  final double threshold;

  FakeVad({this.threshold = 0.01});

  @override
  Future<bool> hasSpeech(Float32List window) async {
    for (final s in window) {
      if (s.abs() > threshold) return true;
    }
    return false;
  }
}
