/// [WhisperTranscriber] — whisper.cpp behind the [Transcriber] seam.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:ml_runtime/ml_runtime.dart';

import 'bindings.dart';

/// A whisper engine failure (model load or inference), carrying the reason.
class WhisperException implements Exception {
  final String message;

  WhisperException(this.message);

  @override
  String toString() => 'WhisperException: $message';
}

/// Streams [TranscriptChunk]s — one per whisper segment — off a 16kHz mono
/// [PcmChunkSource].
///
/// Lifecycle: each [transcribe] call inits a fresh whisper context from
/// [modelPath] and frees it when the stream completes, errors, or is
/// cancelled — no context outlives its stream.
///
/// Windows are treated as consecutive, non-overlapping audio: timestamps of
/// window *k* are offset by the total duration of windows `0..k-1` (the
/// seam carries no window positions). If the source uses overlapping
/// windows, resolve the seams downstream with `mergeOverlap`.
class WhisperTranscriber implements Transcriber {
  /// The only sample rate the whisper pipeline accepts.
  static const int requiredSampleRate = 16000;

  final WhisperBindings bindings;
  final String modelPath;

  /// Whisper's own worker threads per inference; defaults to cores − 1
  /// (floored at 1), per the ML plan.
  final int threads;

  /// Maps to `whisper_full_params.no_context`. On (the default), each
  /// window is decoded independently — the right setting for checkpointed
  /// windowed jobs, where resumed windows must not depend on decoder state
  /// that died with the process.
  final bool noContext;

  WhisperTranscriber({
    required this.bindings,
    required this.modelPath,
    int? threads,
    this.noContext = true,
  }) : threads = threads ?? math.max(1, Platform.numberOfProcessors - 1) {
    if (this.threads < 1) {
      throw ArgumentError.value(threads, 'threads', 'must be >= 1');
    }
  }

  @override
  Stream<TranscriptChunk> transcribe(
    PcmChunkSource src, {
    String? lang,
    WhisperTask task = WhisperTask.transcribe,
    bool wordTimings = true,
  }) async* {
    if (src.sampleRate != requiredSampleRate) {
      throw ArgumentError.value(src.sampleRate, 'src.sampleRate',
          'whisper requires ${requiredSampleRate}Hz mono PCM');
    }
    final ctx = _init();
    var offsetSamples = 0;
    try {
      await for (final window in src.chunks()) {
        if (window.isEmpty) continue;
        _runFull(
          ctx,
          window,
          lang: lang,
          translate: task == WhisperTask.translate,
          wordTimings: wordTimings,
        );
        final offsetMs = offsetSamples * 1000 ~/ requiredSampleRate;
        final segments = bindings.nSegments(ctx);
        for (var i = 0; i < segments; i++) {
          yield _chunk(ctx, i, offsetMs, wordTimings: wordTimings);
        }
        offsetSamples += window.length;
      }
    } finally {
      bindings.free(ctx);
    }
  }

  Pointer<Void> _init() {
    final pathPtr = modelPath.toNativeUtf8();
    try {
      final ctx = bindings.initFromFile(pathPtr);
      if (ctx == nullptr) {
        throw WhisperException('failed to load model: $modelPath');
      }
      return ctx;
    } finally {
      malloc.free(pathPtr);
    }
  }

  void _runFull(
    Pointer<Void> ctx,
    List<double> window, {
    required String? lang,
    required bool translate,
    required bool wordTimings,
  }) {
    final samples = malloc<Float>(window.length);
    final Pointer<Utf8> langPtr = lang?.toNativeUtf8() ?? nullptr;
    try {
      final native = samples.asTypedList(window.length);
      for (var i = 0; i < window.length; i++) {
        native[i] = window[i];
      }
      final status = bindings.full(
        ctx,
        samples,
        window.length,
        langPtr,
        translate ? 1 : 0,
        wordTimings ? 1 : 0,
        threads,
        noContext ? 1 : 0,
      );
      if (status != 0) {
        throw WhisperException('whisper_full failed with status $status');
      }
    } finally {
      malloc.free(samples);
      if (langPtr != nullptr) malloc.free(langPtr);
    }
  }

  TranscriptChunk _chunk(
    Pointer<Void> ctx,
    int segment,
    int offsetMs, {
    required bool wordTimings,
  }) =>
      TranscriptChunk(
        text: bindings.segmentText(ctx, segment).toDartString().trim(),
        tStartMs: bindings.segmentT0(ctx, segment) * 10 + offsetMs,
        tEndMs: bindings.segmentT1(ctx, segment) * 10 + offsetMs,
        words: wordTimings ? _words(ctx, segment, offsetMs) : null,
      );

  /// Groups token-level timestamps into best-effort word timings: a token
  /// starting with a space opens a new word, everything else continues the
  /// current one. Control tokens and tokens whisper left unstamped (t < 0)
  /// are dropped.
  List<WordTiming> _words(Pointer<Void> ctx, int segment, int offsetMs) {
    final words = <WordTiming>[];
    var text = '';
    var t0 = 0;
    var t1 = 0;

    void flush() {
      final word = text.trim();
      if (word.isNotEmpty) {
        words.add(WordTiming(word: word, tStartMs: t0, tEndMs: t1));
      }
      text = '';
    }

    final tokens = bindings.nTokens(ctx, segment);
    for (var j = 0; j < tokens; j++) {
      if (bindings.tokenIsSpecial(ctx, segment, j) != 0) continue;
      final rawT0 = bindings.tokenT0(ctx, segment, j);
      final rawT1 = bindings.tokenT1(ctx, segment, j);
      if (rawT0 < 0 || rawT1 < 0) continue;
      final tok = bindings.tokenText(ctx, segment, j).toDartString();
      final tokT0 = rawT0 * 10 + offsetMs;
      final tokT1 = rawT1 * 10 + offsetMs;
      if (text.isEmpty || tok.startsWith(' ')) {
        flush();
        text = tok;
        t0 = tokT0;
        t1 = tokT1;
      } else {
        text += tok;
        t1 = math.max(t1, tokT1);
      }
    }
    flush();
    return words;
  }
}
