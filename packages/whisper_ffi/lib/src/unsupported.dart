import 'package:ml_runtime/ml_runtime.dart';

/// Non-ffi stand-ins for the two names the app uses
/// (`WhisperBindings.open` and `WhisperTranscriber`). On platforms without
/// dart:ffi — the web tier — the conditional export in `whisper_ffi.dart`
/// resolves here so the app still compiles; local transcription is a
/// native-tier capability (proposal-2 §1), so reaching these refuses
/// cleanly instead of dragging dart:ffi into a dart2js build.
class WhisperBindings {
  /// Only the stub test may construct one — needed to prove the
  /// transcriber stub below refuses. Never reachable through [open].
  const WhisperBindings.any();

  static WhisperBindings open(String libraryPath) => throw UnsupportedError(
      'whisper.cpp transcription needs the native tier (dart:ffi); '
      'it is not available on this platform');
}

class WhisperTranscriber implements Transcriber {
  WhisperTranscriber(
      {required WhisperBindings bindings, required String modelPath}) {
    throw UnsupportedError(
        'whisper.cpp transcription needs the native tier (dart:ffi); '
        'it is not available on this platform');
  }

  @override
  Stream<TranscriptChunk> transcribe(
    PcmChunkSource src, {
    String? lang,
    WhisperTask task = WhisperTask.transcribe,
    bool wordTimings = true,
  }) =>
      throw UnsupportedError('unreachable: the constructor refuses');
}
