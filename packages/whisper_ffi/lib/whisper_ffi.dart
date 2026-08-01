/// whisper.cpp behind `ml_runtime`'s [Transcriber] seam.
///
/// Two layers:
///
///  * [WhisperBindings] — the raw dart:ffi symbol table of the pinned
///    native shim (`natives/shim/wfs_shim.c`, compiled into
///    `libwhisper.so` next to whisper.cpp itself). The shim exists so the
///    huge `whisper_full_params` struct is marshalled where a C compiler
///    guarantees the field offsets, not re-declared by hand in Dart where a
///    single drifted field would silently corrupt every call.
///  * [WhisperTranscriber] — the seam implementation: streams one
///    `TranscriptChunk` per whisper segment with millisecond timestamps and
///    best-effort word timings from token-level timestamps.
library;

// The web tier gets clean-refusal stubs instead, so the app's dart2js
// build never sees Pointer/Void (local transcription is native-tier,
// proposal-2 §1). The real files must stay the DEFAULT branch: the
// analyzer only resolves defaults, and this package's own tests analyze
// against the full ffi API.
export 'src/bindings.dart'
    if (dart.library.js_interop) 'src/unsupported.dart';
export 'src/transcriber.dart'
    if (dart.library.js_interop) 'src/unsupported.dart';
