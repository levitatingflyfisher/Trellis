/// The ML seams (proposal-2 §5). All `Stream`-based so progress and partial
/// results are first-class. This package holds only the contracts and the
/// scripted fakes; the FFI engines (whisper.cpp, Piper, Kokoro, silero,
/// system TTS) implement these in the app, and the web surface keeps inert
/// variants.
library;

import 'dart:typed_data';

import 'transcript.dart';

/// Whisper's two built-in tasks: transcribe in the source language, or
/// translate X → English (the only target Whisper supports).
enum WhisperTask { transcribe, translate }

/// A pull-based source of mono PCM windows.
///
/// The decode step (proposal-2 §5: ffmpeg → 16kHz mono PCM *file*, never a
/// giant buffer in RAM) sits behind this seam; the transcriber reads windows
/// off it without ever holding the whole episode.
abstract class PcmChunkSource {
  /// Samples per second; the whisper pipeline expects 16000.
  int get sampleRate;

  /// The PCM windows, in order. Each element is one window of mono samples.
  Stream<Float32List> chunks();
}

/// Speech → timed text.
abstract class Transcriber {
  Stream<TranscriptChunk> transcribe(
    PcmChunkSource src, {
    String? lang,
    WhisperTask task = WhisperTask.transcribe,
    bool wordTimings = true,
  });
}

/// A synthesis voice: an engine-scoped id plus the language it speaks.
class Voice {
  final String id;
  final String lang;

  const Voice({required this.id, required this.lang});

  @override
  bool operator ==(Object other) =>
      other is Voice && other.id == id && other.lang == lang;

  @override
  int get hashCode => Object.hash(id, lang);

  @override
  String toString() => 'Voice($id, $lang)';
}

/// One rendered span of audio: the samples for input text [inputIndex].
///
/// Speak-mode streams sentence-by-sentence as it renders (proposal-2 §5);
/// [inputIndex] ties each chunk back to the text it voices so the UI can
/// highlight along.
class AudioChunk {
  final int inputIndex;
  final Float32List samples;
  final int sampleRate;

  const AudioChunk({
    required this.inputIndex,
    required this.samples,
    required this.sampleRate,
  });

  @override
  String toString() =>
      'AudioChunk(#$inputIndex, ${samples.length} samples @ ${sampleRate}Hz)';
}

/// Text → audio, one input text at a time, streamed in input order.
///
/// Inputs are plain strings: the app projects `loom_core` segments to their
/// text before crossing this seam, keeping this package dependency-free.
abstract class Synthesizer {
  Stream<AudioChunk> synthesize(Iterable<String> texts, Voice voice);
}

/// Voice-activity detection over one PCM window.
///
/// Gates silent windows before they reach the transcriber — the "Careless
/// Whisper" mitigation (hallucinated phrases concentrate in silences).
abstract class Vad {
  Future<bool> hasSpeech(Float32List window);
}
