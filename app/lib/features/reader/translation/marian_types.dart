/// Shared types for the Marian rung (ADR-0008 "Babel") — deliberately
/// free of both `package:flutter_onnxruntime` and any real ONNX session,
/// mirroring the Supertonic rung's `supertonic_voice_handle.dart` split,
/// so they compile identically on every platform and can sit in
/// [MarianTranslator]'s constructor signature on BOTH sides of the
/// conditional export (`marian_engine.dart`).
library;

/// Which files make up one downloaded opus-mt-en-es model — resolved
/// from the model store (Phase 2's registry wiring), never guessed. All
/// four files ship loose under the model's own directory: no archive to
/// extract, same as the Supertonic rung's files.
class MarianTranslatorFiles {
  final String encoderPath;
  final String decoderMergedPath;
  final String sourceSpmPath;
  final String vocabPath;

  const MarianTranslatorFiles({
    required this.encoderPath,
    required this.decoderMergedPath,
    required this.sourceSpmPath,
    required this.vocabPath,
  });
}

/// A dtype tag for [MTensor] — the real adapter needs this to build the
/// correctly-typed `OrtValue` (never a plain `List<int>`, which
/// `OrtValue.fromList` silently treats as int32; every int64 graph input
/// here needs an explicit tag through to `Int64List`).
enum MTensorType { int64, float32, boolean }

/// The thinnest boundary over an ONNX session's `run` call — narrow
/// enough that a host test can fake it entirely and drive the generation
/// loop's mechanics (past-KV threading, the frozen-cross-attention-KV
/// workaround, EOS stop, the length cap) with deterministic canned
/// outputs, never touching `package:flutter_onnxruntime` or a platform
/// channel. Plain data (`List<num>` + shape + dtype), not `OrtValue` —
/// the loop's own logic never imports the plugin package at all.
class MTensor {
  final List<num> data;
  final List<int> shape;
  final MTensorType type;

  const MTensor(this.data, this.shape, [this.type = MTensorType.float32]);
}

/// What the generation loop needs from an ONNX session — real code wraps
/// `OrtSession.run`; tests inject a deterministic fake script.
abstract interface class MarianSessionRunner {
  Future<Map<String, MTensor>> run(Map<String, MTensor> feeds);
}

/// The open handle: tokenizer + vocabulary + the two sessions, ready to
/// translate. Mirrors [SupertonicVoiceHandle]'s split — real session
/// construction lives ONLY behind the real implementation's handle
/// factory, never in [MarianTranslator]'s constructor, so a test can
/// build the engine with a fake factory and never touch a platform
/// channel.
abstract interface class MarianModelHandle {
  /// Translates ONE English sentence (already split — Phase 3 calls this
  /// per-sentence via loom_core's splitter, the same lookahead law the
  /// speech pipeline follows) into Spanish.
  Future<String> translate(String sentence);

  /// Releases both native ONNX sessions this handle opened.
  Future<void> dispose();
}

typedef MarianModelHandleFactory =
    Future<MarianModelHandle> Function(MarianTranslatorFiles files);

/// This model's files are missing or incomplete on disk (a partial/failed
/// download, or a cache wipe) — never a bare platform I/O exception
/// (ADR-0003: errors are sentences).
class MarianModelMissingFilesException implements Exception {
  final String message;
  const MarianModelMissingFilesException(this.message);
  @override
  String toString() => message;
}

/// The files are present but the ONNX Runtime sessions refused to start,
/// or the tokenizer/vocabulary files failed to parse (a corrupt
/// download, an unsupported ORT build, a genuine engine bug) — never a
/// bare platform exception.
class MarianModelInitException implements Exception {
  final String message;
  const MarianModelInitException(this.message);
  @override
  String toString() => message;
}
