/// The raw symbol table of the whisper native shim (`wfs_*` exports of
/// `libwhisper.so` — see `natives/shim/wfs_shim.c` and `natives/README.md`
/// for the pinned whisper.cpp tag and build recipe).
///
/// Fields are plain Dart function types, so tests construct a
/// [WhisperBindings] from closures (a fake symbol table) and the
/// transcriber never knows the difference; [WhisperBindings.fromLibrary]
/// wires the same shape to the real `DynamicLibrary`.
///
/// Times are in whisper's native unit — **centiseconds** — and converted
/// to milliseconds one layer up.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

// Native (C) signatures of the shim ABI.
typedef _InitC = Pointer<Void> Function(Pointer<Utf8>);
typedef _FreeC = Void Function(Pointer<Void>);
typedef _FullC = Int32 Function(
    Pointer<Void>, Pointer<Float>, Int32, Pointer<Utf8>, Int32, Int32, Int32, Int32);
typedef _NSegmentsC = Int32 Function(Pointer<Void>);
typedef _SegTextC = Pointer<Utf8> Function(Pointer<Void>, Int32);
typedef _SegTimeC = Int64 Function(Pointer<Void>, Int32);
typedef _NTokensC = Int32 Function(Pointer<Void>, Int32);
typedef _TokTextC = Pointer<Utf8> Function(Pointer<Void>, Int32, Int32);
typedef _TokTimeC = Int64 Function(Pointer<Void>, Int32, Int32);
typedef _TokFlagC = Int32 Function(Pointer<Void>, Int32, Int32);
typedef _FullLangC = Pointer<Utf8> Function(Pointer<Void>);
typedef _StateNewC = Pointer<Void> Function(Pointer<Void>);
typedef _StateFullC = Int32 Function(Pointer<Void>, Pointer<Void>,
    Pointer<Float>, Int32, Pointer<Utf8>, Int32, Int32, Int32, Int32);
typedef _StateTokTextC = Pointer<Utf8> Function(
    Pointer<Void>, Pointer<Void>, Int32, Int32);
typedef _StateTokFlagC = Int32 Function(
    Pointer<Void>, Pointer<Void>, Int32, Int32);

/// `wfs_init_from_file(model_path)` -> `whisper_context*` (nullptr on
/// failure). Wraps `whisper_init_from_file_with_params` with CPU-only
/// context defaults.
typedef WfsInitFromFile = Pointer<Void> Function(Pointer<Utf8> modelPath);

/// `wfs_free(ctx)` — `whisper_free`.
typedef WfsFree = void Function(Pointer<Void> ctx);

/// `wfs_full(ctx, samples, n, lang, translate, token_timestamps, n_threads,
/// no_context)` — `whisper_full` over greedy default params with exactly
/// those fields set. `lang` nullptr means auto-detect. Returns whisper's
/// status (0 = ok).
typedef WfsFull = int Function(
    Pointer<Void> ctx,
    Pointer<Float> samples,
    int nSamples,
    Pointer<Utf8> lang,
    int translate,
    int tokenTimestamps,
    int nThreads,
    int noContext);

/// `wfs_n_segments(ctx)` — segment count of the last `wfs_full`.
typedef WfsNSegments = int Function(Pointer<Void> ctx);

/// `wfs_segment_text(ctx, i)` — UTF-8 text, owned by the context, valid
/// until the next `wfs_full`/`wfs_free`; callers copy immediately.
typedef WfsSegmentText = Pointer<Utf8> Function(Pointer<Void> ctx, int segment);

/// `wfs_segment_t0/t1(ctx, i)` — segment bounds in centiseconds.
typedef WfsSegmentTime = int Function(Pointer<Void> ctx, int segment);

/// `wfs_n_tokens(ctx, i)` — token count of a segment.
typedef WfsNTokens = int Function(Pointer<Void> ctx, int segment);

/// `wfs_token_text(ctx, i, j)` — same ownership rules as segment text.
typedef WfsTokenText =
    Pointer<Utf8> Function(Pointer<Void> ctx, int segment, int token);

/// `wfs_token_t0/t1(ctx, i, j)` — token bounds in centiseconds, -1 when the
/// engine produced no timestamp for the token.
typedef WfsTokenTime = int Function(Pointer<Void> ctx, int segment, int token);

/// `wfs_token_is_special(ctx, i, j)` — nonzero for control tokens
/// (`token_id >= whisper_token_eot`), which carry no speech text.
typedef WfsTokenIsSpecial = int Function(
    Pointer<Void> ctx, int segment, int token);

/// `wfs_full_lang(ctx)` — the language code whisper decoded the last
/// `wfs_full` in (the detected one after an auto run), as a static string
/// that needs no freeing; nullptr when whisper has none.
typedef WfsFullLang = Pointer<Utf8> Function(Pointer<Void> ctx);

/// `wfs_state_new(ctx)` -> a fresh `whisper_state*` for one window
/// (nullptr on failure); `wfs_state_free(state)` releases it.
typedef WfsStateNew = Pointer<Void> Function(Pointer<Void> ctx);
typedef WfsStateFree = void Function(Pointer<Void> state);

/// `wfs_state_full(ctx, state, ...)` — [WfsFull] decoded into [state]
/// instead of the context's own.
typedef WfsStateFull = int Function(
    Pointer<Void> ctx,
    Pointer<Void> state,
    Pointer<Float> samples,
    int nSamples,
    Pointer<Utf8> lang,
    int translate,
    int tokenTimestamps,
    int nThreads,
    int noContext);

/// `wfs_state_token_text(ctx, state, i, j)` — needs the context for the
/// vocabulary.
typedef WfsStateTokenText = Pointer<Utf8> Function(
    Pointer<Void> ctx, Pointer<Void> state, int segment, int token);

/// `wfs_state_token_is_special(ctx, state, i, j)`.
typedef WfsStateTokenIsSpecial = int Function(
    Pointer<Void> ctx, Pointer<Void> state, int segment, int token);

/// The `wfs_state_*` exports: the model loaded once with no decoder state,
/// and a fresh state per window. A context that owns its state carries
/// decoder 0's sampling RNG across windows (seeded once, drawn from by
/// temperature fallback), so a kept context makes a window's text depend
/// on the windows before it and a resumed job diverge from an
/// uninterrupted one. A fresh state per window decodes every window as if
/// it were the first.
///
/// The getters take the state where [WhisperBindings]' take the context;
/// they reuse the same Dart function types, since both are opaque
/// pointers.
class WhisperStateBindings {
  /// `wfs_state_init_model(path)` — `whisper_init_from_file_with_params_no_state`.
  final WfsInitFromFile initModel;
  final WfsStateNew newState;
  final WfsStateFree freeState;
  final WfsStateFull full;
  final WfsNSegments nSegments;
  final WfsSegmentText segmentText;
  final WfsSegmentTime segmentT0;
  final WfsSegmentTime segmentT1;
  final WfsNTokens nTokens;
  final WfsStateTokenText tokenText;
  final WfsTokenTime tokenT0;
  final WfsTokenTime tokenT1;
  final WfsStateTokenIsSpecial tokenIsSpecial;
  final WfsFullLang fullLang;

  WhisperStateBindings({
    required this.initModel,
    required this.newState,
    required this.freeState,
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

  /// Every export this set needs; all or nothing.
  static const symbols = [
    'wfs_state_init_model',
    'wfs_state_new',
    'wfs_state_free',
    'wfs_state_full',
    'wfs_state_n_segments',
    'wfs_state_segment_text',
    'wfs_state_segment_t0',
    'wfs_state_segment_t1',
    'wfs_state_n_tokens',
    'wfs_state_token_text',
    'wfs_state_token_t0',
    'wfs_state_token_t1',
    'wfs_state_token_is_special',
    'wfs_state_full_lang',
  ];

  /// Null when [lib] lacks any of [symbols] (a `.so` built before 1.5.3).
  static WhisperStateBindings? fromLibrary(DynamicLibrary lib) {
    if (!symbols.every(lib.providesSymbol)) return null;
    return WhisperStateBindings(
      initModel:
          lib.lookupFunction<_InitC, WfsInitFromFile>('wfs_state_init_model'),
      newState: lib.lookupFunction<_StateNewC, WfsStateNew>('wfs_state_new'),
      freeState: lib.lookupFunction<_FreeC, WfsStateFree>('wfs_state_free'),
      full: lib.lookupFunction<_StateFullC, WfsStateFull>('wfs_state_full'),
      nSegments: lib
          .lookupFunction<_NSegmentsC, WfsNSegments>('wfs_state_n_segments'),
      segmentText: lib.lookupFunction<_SegTextC, WfsSegmentText>(
          'wfs_state_segment_text'),
      segmentT0: lib
          .lookupFunction<_SegTimeC, WfsSegmentTime>('wfs_state_segment_t0'),
      segmentT1: lib
          .lookupFunction<_SegTimeC, WfsSegmentTime>('wfs_state_segment_t1'),
      nTokens:
          lib.lookupFunction<_NTokensC, WfsNTokens>('wfs_state_n_tokens'),
      tokenText: lib.lookupFunction<_StateTokTextC, WfsStateTokenText>(
          'wfs_state_token_text'),
      tokenT0:
          lib.lookupFunction<_TokTimeC, WfsTokenTime>('wfs_state_token_t0'),
      tokenT1:
          lib.lookupFunction<_TokTimeC, WfsTokenTime>('wfs_state_token_t1'),
      tokenIsSpecial:
          lib.lookupFunction<_StateTokFlagC, WfsStateTokenIsSpecial>(
              'wfs_state_token_is_special'),
      fullLang:
          lib.lookupFunction<_FullLangC, WfsFullLang>('wfs_state_full_lang'),
    );
  }
}

/// The shim's symbol table. See the library docs for why this is a set of
/// plain function fields rather than lookups baked into methods.
class WhisperBindings {
  final WfsInitFromFile initFromFile;
  final WfsFree free;
  final WfsFull full;
  final WfsNSegments nSegments;
  final WfsSegmentText segmentText;
  final WfsSegmentTime segmentT0;
  final WfsSegmentTime segmentT1;
  final WfsNTokens nTokens;
  final WfsTokenText tokenText;
  final WfsTokenTime tokenT0;
  final WfsTokenTime tokenT1;
  final WfsTokenIsSpecial tokenIsSpecial;

  /// Optional: null against a `libwhisper.so` built before the shim
  /// exported `wfs_full_lang`. Without it a job can't lock the language it
  /// detected and auto-detects on every window instead — slower, not wrong.
  final WfsFullLang? fullLang;

  /// Optional: null against a `libwhisper.so` built before the shim
  /// exported the `wfs_state_*` set. Without it a kept context carries
  /// decoder state from window to window (see [WhisperStateBindings]).
  final WhisperStateBindings? state;

  WhisperBindings({
    required this.initFromFile,
    required this.free,
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
    this.fullLang,
    this.state,
  });

  /// Looks the shim symbols up in an already-loaded [lib].
  factory WhisperBindings.fromLibrary(DynamicLibrary lib) => WhisperBindings(
        initFromFile:
            lib.lookupFunction<_InitC, WfsInitFromFile>('wfs_init_from_file'),
        free: lib.lookupFunction<_FreeC, WfsFree>('wfs_free'),
        full: lib.lookupFunction<_FullC, WfsFull>('wfs_full'),
        nSegments:
            lib.lookupFunction<_NSegmentsC, WfsNSegments>('wfs_n_segments'),
        segmentText: lib
            .lookupFunction<_SegTextC, WfsSegmentText>('wfs_segment_text'),
        segmentT0:
            lib.lookupFunction<_SegTimeC, WfsSegmentTime>('wfs_segment_t0'),
        segmentT1:
            lib.lookupFunction<_SegTimeC, WfsSegmentTime>('wfs_segment_t1'),
        nTokens: lib.lookupFunction<_NTokensC, WfsNTokens>('wfs_n_tokens'),
        tokenText:
            lib.lookupFunction<_TokTextC, WfsTokenText>('wfs_token_text'),
        tokenT0: lib.lookupFunction<_TokTimeC, WfsTokenTime>('wfs_token_t0'),
        tokenT1: lib.lookupFunction<_TokTimeC, WfsTokenTime>('wfs_token_t1'),
        tokenIsSpecial: lib.lookupFunction<_TokFlagC, WfsTokenIsSpecial>(
            'wfs_token_is_special'),
        fullLang: lib.providesSymbol('wfs_full_lang')
            ? lib.lookupFunction<_FullLangC, WfsFullLang>('wfs_full_lang')
            : null,
        state: WhisperStateBindings.fromLibrary(lib),
      );

  /// Opens the shared library at [path] and binds its symbols.
  factory WhisperBindings.open(String path) =>
      WhisperBindings.fromLibrary(DynamicLibrary.open(path));
}
