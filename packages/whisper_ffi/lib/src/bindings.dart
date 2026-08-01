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
      );

  /// Opens the shared library at [path] and binds its symbols.
  factory WhisperBindings.open(String path) =>
      WhisperBindings.fromLibrary(DynamicLibrary.open(path));
}
