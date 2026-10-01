/// Shared types for the Marian rung (ADR-0008 "Babel") — deliberately
/// free of both `package:flutter_onnxruntime` and any real ONNX session,
/// mirroring the Supertonic rung's `supertonic_voice_handle.dart` split,
/// so they compile identically on every platform and can sit in
/// [MarianTranslator]'s constructor signature on BOTH sides of the
/// conditional export (`marian_engine.dart`).
library;

/// Which files make up one downloaded opus-mt model — resolved from the
/// model store through the registry's [MarianModelLayout], never guessed.
/// Every file ships loose under the model's own directory: no archive to
/// extract, same as the Supertonic rung's files.
class MarianTranslatorFiles {
  final String encoderPath;
  final String decoderMergedPath;
  final String sourceSpmPath;
  final String vocabPath;
  final String configPath;
  final String tokenizerConfigPath;

  /// A multi-target export's `>>xx<<` token, from the layout; null for a
  /// bilingual pair.
  final String? targetToken;

  const MarianTranslatorFiles({
    required this.encoderPath,
    required this.decoderMergedPath,
    required this.sourceSpmPath,
    required this.vocabPath,
    required this.configPath,
    required this.tokenizerConfigPath,
    this.targetToken,
  });

  List<String> get allPaths => [
        encoderPath,
        decoderMergedPath,
        sourceSpmPath,
        vocabPath,
        configPath,
        tokenizerConfigPath,
      ];
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

  /// A value still living on the runtime's side (an `OrtValue`), when the
  /// runner left it there: the decoder's growing self-attention cache and
  /// the frozen cross-attention cache go straight back into the next step
  /// as handles. Copying them through the platform channel each step was
  /// most of the per-token cost; only `logits` needs to reach Dart.
  /// [data] is empty for a handle.
  final Object? handle;

  const MTensor(this.data, this.shape, [this.type = MTensorType.float32])
      : handle = null;

  const MTensor.handle(Object this.handle, this.shape,
      [this.type = MTensorType.float32])
      : data = const [];
}

/// What the generation loop needs from an ONNX session — real code wraps
/// `OrtSession.run`; tests inject a deterministic fake script.
abstract interface class MarianSessionRunner {
  /// Runs the session. Outputs named in [fetch] come back as plain data;
  /// the rest may come back as [MTensor.handle]s (a fake may return data
  /// for everything). A null [fetch] fetches every output.
  Future<Map<String, MTensor>> run(Map<String, MTensor> feeds,
      {Set<String>? fetch});

  /// Frees handles this runner returned. Plain-data tensors are ignored.
  Future<void> release(Iterable<MTensor> tensors);
}

/// The open handle: tokenizer + vocabulary + the two sessions, ready to
/// translate. Mirrors [SupertonicVoiceHandle]'s split — real session
/// construction lives ONLY behind the real implementation's handle
/// factory, never in [MarianTranslator]'s constructor, so a test can
/// build the engine with a fake factory and never touch a platform
/// channel.
abstract interface class MarianModelHandle {
  /// Translates ONE sentence (already split — the batch calls this
  /// per-sentence via loom_core's splitter, the same lookahead law the
  /// speech pipeline follows) from the pair's source into its target.
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
