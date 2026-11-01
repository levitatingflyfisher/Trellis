import 'package:ml_runtime/ml_runtime.dart';

/// Non-ffi stand-ins for `bindings.dart` and `transcriber.dart`. On
/// platforms without dart:ffi — the web tier — the conditional export in
/// `whisper_ffi.dart` resolves here so the app still compiles; local
/// transcription is a native-tier capability (proposal-2 §1), so reaching
/// these refuses cleanly instead of dragging dart:ffi into a dart2js build.
///
/// The surface matches the native files name for name (only what needs
/// dart:ffi to even declare is left out), so app code written against the
/// native class compiles here too. `test/stub_parity_test.dart` holds it
/// there: add a public member natively and that test names it.
const _refusal = 'whisper.cpp transcription needs the native tier (dart:ffi); '
    'it is not available on this platform';

class WhisperBindings {
  /// Only the stub test may construct one — needed to prove the
  /// transcriber stub below refuses. Never reachable through [open].
  const WhisperBindings.any();

  factory WhisperBindings.open(String path) =>
      throw UnsupportedError(_refusal);
}

class WhisperException implements Exception {
  final String message;

  WhisperException(this.message);

  @override
  String toString() => 'WhisperException: $message';
}

class WhisperTranscriber
    implements Transcriber, ReportsLanguage, ClosableTranscriber {
  static const int requiredSampleRate = 16000;

  final WhisperBindings bindings;
  final String modelPath;
  final int threads;
  final bool noContext;
  final bool keepContext;

  WhisperTranscriber({
    required this.bindings,
    required this.modelPath,
    int? threads,
    this.noContext = true,
    this.keepContext = false,
  }) : threads = threads ?? 1 {
    throw UnsupportedError(_refusal);
  }

  @override
  String? get lastLanguage => null;

  @override
  void close() {}

  @override
  Stream<TranscriptChunk> transcribe(
    PcmChunkSource src, {
    String? lang,
    WhisperTask task = WhisperTask.transcribe,
    bool wordTimings = true,
  }) =>
      throw UnsupportedError('unreachable: the constructor refuses');
}

int defaultWhisperThreads() => throw UnsupportedError(_refusal);
