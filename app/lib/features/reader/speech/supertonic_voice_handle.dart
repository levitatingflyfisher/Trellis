/// Shared types for the Supertonic rung (ADR-0007) — deliberately free of
/// both `package:flutter_onnxruntime` and any real ONNX session so they
/// compile identically on every platform and can sit in
/// [SupertonicSpeechEngine]'s constructor signature on BOTH sides of the
/// conditional export (`supertonic_engine.dart`), keeping the real and
/// web-stub implementations call-compatible.
library;

import 'speech_engine.dart';

/// Which files make up one downloaded voice — resolved from the model
/// store (Phase 2's registry wiring), never guessed. All seven files live
/// loose under the voice's own model directory: there is no archive to
/// extract, so unlike the sherpa rung's [SherpaVoiceFiles] there is no
/// data directory either.
class SupertonicVoiceFiles {
  final String durationPredictorPath;
  final String textEncoderPath;
  final String vectorEstimatorPath;
  final String vocoderPath;
  final String unicodeIndexerPath;
  final String ttsConfigPath;
  final String voiceStylePath;

  const SupertonicVoiceFiles({
    required this.durationPredictorPath,
    required this.textEncoderPath,
    required this.vectorEstimatorPath,
    required this.vocoderPath,
    required this.unicodeIndexerPath,
    required this.ttsConfigPath,
    required this.voiceStylePath,
  });
}

/// The languages this campaign's ONE voice embedding (M1) claims to speak.
/// The model architecture (Supertonic v2) covers five (en/ko/es/pt/fr —
/// ADR-0007), and `lang` is a genuinely independent runtime parameter
/// from voice-style selection (confirmed against upstream's own usage
/// pattern and `voice_styles/` listing, ADR-0008 "Babel" Phase 4:
/// F1-F5/M1-M5 are speaker timbres, not language pairs — there is no
/// separate "Spanish voice" to download). Widened from `{'en'}` to
/// `{'en', 'es'}` per ADR-0007's own recorded escape hatch ("the same M1
/// embedding, if it turns out to generalize") — this M1 embedding has
/// been reviewed for English; Spanish output through it has NOT been
/// verified by ear on real hardware. See ADR-0008's amendment for the
/// full honesty accounting. Widening further (ko/pt/fr) is the same
/// move, still unverified, not done here.
const supertonicSupportedLangs = {'en', 'es'};

/// The thinnest boundary over flutter_onnxruntime's four ONNX sessions —
/// narrow enough that a host test can fake it entirely, mirroring
/// whisper_ffi's bindings-vs-transcriber split and the sherpa rung's own
/// [SherpaVoiceHandle] precedent. Real session construction lives ONLY
/// behind the real implementation's handle factory — never in
/// [SupertonicSpeechEngine]'s constructor — so a test can build the
/// engine with a fake factory and never touch a platform channel.
///
/// Async (unlike [SherpaVoiceHandle.generate]'s synchronous FFI call):
/// ONNX Runtime inference here crosses a platform channel, so every call
/// is genuinely asynchronous — a deliberate divergence from the sherpa
/// rung's shape, recorded because a reader who knows that precedent would
/// otherwise expect the same.
abstract interface class SupertonicVoiceHandle {
  /// Renders [text] — already ONE sentence (ADR-0006's `splitSentences`)
  /// — in [lang] and returns raw PCM. [lang] MUST already be one of
  /// [supertonicSupportedLangs]: [SupertonicSpeechEngine] checks that
  /// before a handle is ever opened, so a handle is never asked to
  /// refuse.
  Future<SynthResult> generate(String text, {required String lang});

  /// Releases every native ONNX session this handle opened.
  Future<void> dispose();
}

typedef SupertonicVoiceHandleFactory = Future<SupertonicVoiceHandle> Function(
    SupertonicVoiceFiles files);

/// This voice's files are missing or incomplete on disk (a partial/failed
/// download, or a cache wipe) — never a bare platform I/O exception.
class SupertonicVoiceMissingFilesException implements Exception {
  final String message;
  const SupertonicVoiceMissingFilesException(this.message);
  @override
  String toString() => message;
}

/// The files are present but the ONNX Runtime sessions refused to start
/// (a corrupt file, an unsupported ORT build, a genuine engine bug) —
/// never a bare platform exception.
class SupertonicNativeInitException implements Exception {
  final String message;
  const SupertonicNativeInitException(this.message);
  @override
  String toString() => message;
}

/// The requested language is not one of [supertonicSupportedLangs] — a
/// typed, calm refusal (ADR-0003: errors are sentences) rather than the
/// upstream reference implementation's raw `ArgumentError`.
class SupertonicUnsupportedLangException implements Exception {
  final String message;
  const SupertonicUnsupportedLangException(this.message);
  @override
  String toString() => message;
}
