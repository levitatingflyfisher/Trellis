/// [WhisperTranscriber] — whisper.cpp behind the [Transcriber] seam.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:ml_runtime/ml_runtime.dart';

import 'bindings.dart';
import 'threads.dart';

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
/// Lifecycle: by default each [transcribe] call inits a fresh whisper
/// context from [modelPath] and frees it when the stream completes, errors,
/// or is cancelled — no context outlives its stream. With [keepContext] the
/// first call loads the context and every later call reuses it until
/// [close]: a windowed job calls [transcribe] once per window, and loading
/// the model each time is pure waste.
///
/// Where the library exports the `wfs_state_*` set, the context is loaded
/// with no decoder state and each window decodes into a fresh state that
/// is freed once its results are read. A kept context would otherwise
/// carry the sampling RNG from one window into the next, and a resumed job
/// would not match an uninterrupted run. Without that set (an older `.so`)
/// the context's own state is used, as before.
///
/// Windows are treated as consecutive, non-overlapping audio: timestamps of
/// window *k* are offset by the total duration of windows `0..k-1` (the
/// seam carries no window positions). If the source uses overlapping
/// windows, resolve the seams downstream with `mergeOverlap`.
class WhisperTranscriber
    implements Transcriber, ReportsLanguage, ClosableTranscriber {
  /// The only sample rate the whisper pipeline accepts.
  static const int requiredSampleRate = 16000;

  final WhisperBindings bindings;
  final String modelPath;

  /// Whisper's own worker threads per inference; defaults to
  /// [defaultWhisperThreads].
  final int threads;

  /// Maps to `whisper_full_params.no_context`. On (the default), each
  /// window is decoded without the previous window's text as a prompt —
  /// the right setting for checkpointed windowed jobs, where resumed
  /// windows must not depend on decoder state that died with the process.
  /// With a per-window state (a kept model on a `.so` that exports the
  /// `wfs_state_*` set) nothing else carries from one window to the next
  /// either: not the text, nor the sampler's RNG, so a window decodes the
  /// same alone or after another.
  final bool noContext;

  /// Hold one context across [transcribe] calls until [close] (see the
  /// class docs).
  final bool keepContext;

  Pointer<Void>? _kept;
  String? _lastLanguage;

  WhisperTranscriber({
    required this.bindings,
    required this.modelPath,
    int? threads,
    this.noContext = true,
    this.keepContext = false,
  }) : threads = threads ?? defaultWhisperThreads() {
    if (this.threads < 1) {
      throw ArgumentError.value(threads, 'threads', 'must be >= 1');
    }
  }

  @override
  String? get lastLanguage => _lastLanguage;

  @override
  void close() {
    final ctx = _kept;
    _kept = null;
    if (ctx != null) bindings.free(ctx);
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
    final ctx = keepContext ? (_kept ??= _init()) : _init();
    var offsetSamples = 0;
    try {
      await for (final window in src.chunks()) {
        if (window.isEmpty) continue;
        final offsetMs = offsetSamples * 1000 ~/ requiredSampleRate;
        final chunks = _decode(
          ctx,
          window,
          offsetMs,
          lang: lang,
          translate: task == WhisperTask.translate,
          wordTimings: wordTimings,
        );
        for (final chunk in chunks) {
          yield chunk;
        }
        offsetSamples += window.length;
      }
    } finally {
      if (!keepContext) bindings.free(ctx);
    }
  }

  /// Runs one window and reads everything it produced, so a per-window
  /// state is freed before the first chunk is handed out and can't
  /// outlive a cancelled stream.
  List<TranscriptChunk> _decode(
    Pointer<Void> ctx,
    List<double> window,
    int offsetMs, {
    required String? lang,
    required bool translate,
    required bool wordTimings,
  }) {
    final stateful = bindings.state;
    if (stateful == null) {
      final reader = _Reader.context(bindings, ctx);
      _runFull(reader, window,
          lang: lang, translate: translate, wordTimings: wordTimings);
      return _read(reader, offsetMs, wordTimings: wordTimings);
    }
    final state = stateful.newState(ctx);
    if (state == nullptr) {
      throw WhisperException('failed to allocate a whisper state');
    }
    try {
      final reader = _Reader.state(stateful, ctx, state);
      _runFull(reader, window,
          lang: lang, translate: translate, wordTimings: wordTimings);
      return _read(reader, offsetMs, wordTimings: wordTimings);
    } finally {
      stateful.freeState(state);
    }
  }

  List<TranscriptChunk> _read(_Reader r, int offsetMs,
      {required bool wordTimings}) {
    final code = r.fullLang?.call();
    _lastLanguage =
        code == null || code == nullptr ? null : code.toDartString();
    return [
      for (var i = 0; i < r.nSegments(); i++)
        _chunk(r, i, offsetMs, wordTimings: wordTimings),
    ];
  }

  Pointer<Void> _init() {
    final pathPtr = modelPath.toNativeUtf8();
    try {
      final ctx = (bindings.state?.initModel ?? bindings.initFromFile)(pathPtr);
      if (ctx == nullptr) {
        throw WhisperException('failed to load model: $modelPath');
      }
      return ctx;
    } finally {
      malloc.free(pathPtr);
    }
  }

  void _runFull(
    _Reader r,
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
      final status = r.full(
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
    _Reader r,
    int segment,
    int offsetMs, {
    required bool wordTimings,
  }) =>
      TranscriptChunk(
        text: r.segmentText(segment).toDartString().trim(),
        tStartMs: r.segmentT0(segment) * 10 + offsetMs,
        tEndMs: r.segmentT1(segment) * 10 + offsetMs,
        words: wordTimings ? _words(r, segment, offsetMs) : null,
      );

  /// Groups token-level timestamps into best-effort word timings: a token
  /// starting with a space opens a new word, everything else continues the
  /// current one. Control tokens and tokens whisper left unstamped (t < 0)
  /// are dropped.
  List<WordTiming> _words(_Reader r, int segment, int offsetMs) {
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

    final tokens = r.nTokens(segment);
    for (var j = 0; j < tokens; j++) {
      if (r.tokenIsSpecial(segment, j) != 0) continue;
      final rawT0 = r.tokenT0(segment, j);
      final rawT1 = r.tokenT1(segment, j);
      if (rawT0 < 0 || rawT1 < 0) continue;
      final tok = r.tokenText(segment, j).toDartString();
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

/// One window's decode and results, over either the context's own state
/// or a per-window one, so the transcriber reads both the same way.
class _Reader {
  final int Function(Pointer<Float> samples, int n, Pointer<Utf8> lang,
      int translate, int tokenTimestamps, int threads, int noContext) full;
  final int Function() nSegments;
  final Pointer<Utf8> Function(int i) segmentText;
  final int Function(int i) segmentT0;
  final int Function(int i) segmentT1;
  final int Function(int i) nTokens;
  final Pointer<Utf8> Function(int i, int j) tokenText;
  final int Function(int i, int j) tokenT0;
  final int Function(int i, int j) tokenT1;
  final int Function(int i, int j) tokenIsSpecial;
  final Pointer<Utf8> Function()? fullLang;

  _Reader._({
    required this.full,
    required this.nSegments,
    required this.segmentText,
    required this.segmentT0,
    required this.segmentT1,
    required this.nTokens,
    required this.tokenText,
    required this.tokenT0,
    required this.tokenT1,
    required this.tokenIsSpecial,
    required this.fullLang,
  });

  factory _Reader.context(WhisperBindings b, Pointer<Void> ctx) {
    final lang = b.fullLang;
    return _Reader._(
      full: (s, n, l, tr, ts, th, nc) => b.full(ctx, s, n, l, tr, ts, th, nc),
      nSegments: () => b.nSegments(ctx),
      segmentText: (i) => b.segmentText(ctx, i),
      segmentT0: (i) => b.segmentT0(ctx, i),
      segmentT1: (i) => b.segmentT1(ctx, i),
      nTokens: (i) => b.nTokens(ctx, i),
      tokenText: (i, j) => b.tokenText(ctx, i, j),
      tokenT0: (i, j) => b.tokenT0(ctx, i, j),
      tokenT1: (i, j) => b.tokenT1(ctx, i, j),
      tokenIsSpecial: (i, j) => b.tokenIsSpecial(ctx, i, j),
      fullLang: lang == null ? null : () => lang(ctx),
    );
  }

  factory _Reader.state(
          WhisperStateBindings b, Pointer<Void> ctx, Pointer<Void> st) =>
      _Reader._(
        full: (s, n, l, tr, ts, th, nc) =>
            b.full(ctx, st, s, n, l, tr, ts, th, nc),
        nSegments: () => b.nSegments(st),
        segmentText: (i) => b.segmentText(st, i),
        segmentT0: (i) => b.segmentT0(st, i),
        segmentT1: (i) => b.segmentT1(st, i),
        nTokens: (i) => b.nTokens(st, i),
        tokenText: (i, j) => b.tokenText(ctx, st, i, j),
        tokenT0: (i, j) => b.tokenT0(st, i, j),
        tokenT1: (i, j) => b.tokenT1(st, i, j),
        tokenIsSpecial: (i, j) => b.tokenIsSpecial(ctx, st, i, j),
        fullLang: () => b.fullLang(st),
      );
}

/// [whisperThreadsFor] this device, reading each core's top frequency from
/// Linux's cpufreq (Android included); where that can't be read the cores
/// count as uniform.
int defaultWhisperThreads() {
  final cores = Platform.numberOfProcessors;
  final freqs = <int>[];
  try {
    for (var i = 0; i < cores; i++) {
      final f = File(
          '/sys/devices/system/cpu/cpu$i/cpufreq/cpuinfo_max_freq');
      final khz = int.tryParse(f.readAsStringSync().trim());
      if (khz == null) break;
      freqs.add(khz);
    }
  } on FileSystemException {
    // Not Linux, or cpufreq hidden: the uniform fallback applies.
  }
  return whisperThreadsFor(cores: cores, maxFreqsKhz: freqs);
}
