/// The real Marian implementation (ADR-0008 "Babel"): any registered
/// opus-mt pair over `flutter_onnxruntime`, behind [MarianTranslator]. Must stay the
/// DEFAULT branch of `marian_engine.dart`'s conditional export — never
/// imported directly by app code; always through the barrel. Mirrors
/// `supertonic_speech_engine.dart`'s shape (residency, serialized-call,
/// dispose-waits laws) — same file, read first if this one is unclear.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:ml_runtime/ml_runtime.dart';

import '../marian_generation_loop.dart';
import '../marian_types.dart';
import '../translator.dart';

// ---------------------------------------------------------------------
// The MTensor <-> OrtValue adapter — the ONLY place this file's own
// generation-loop mechanics touch flutter_onnxruntime.
// ---------------------------------------------------------------------

Future<OrtValue> _toOrtValue(MTensor t) {
  switch (t.type) {
    case MTensorType.int64:
      return OrtValue.fromList(
        Int64List.fromList(t.data.map((e) => e.toInt()).toList()),
        t.shape,
      );
    case MTensorType.float32:
      return OrtValue.fromList(
        Float32List.fromList(t.data.map((e) => e.toDouble()).toList()),
        t.shape,
      );
    case MTensorType.boolean:
      return OrtValue.fromList(
        t.data.map((e) => e != 0).toList(growable: false),
        t.shape,
      );
  }
}

MTensorType _fromOrtDataType(OrtDataType dt) => switch (dt) {
  OrtDataType.int64 || OrtDataType.int32 => MTensorType.int64,
  OrtDataType.bool => MTensorType.boolean,
  _ => MTensorType.float32,
};

Future<MTensor> _fromOrtValue(OrtValue v) async {
  final flat = await v.asFlattenedList();
  final data = flat
      .map((e) => e is bool ? (e ? 1 : 0) : (e as num))
      .toList(growable: false);
  return MTensor(data, v.shape, _fromOrtDataType(v.dataType));
}

class _OrtSessionRunner implements MarianSessionRunner {
  final OrtSession session;
  _OrtSessionRunner(this.session);

  @override
  Future<Map<String, MTensor>> run(Map<String, MTensor> feeds,
      {Set<String>? fetch}) async {
    // Handles go back in as they are; only plain data is uploaded, and
    // only what this call uploaded is freed after it.
    final uploaded = <OrtValue>[];
    final ortFeeds = <String, OrtValue>{};
    for (final e in feeds.entries) {
      final handle = e.value.handle;
      if (handle is OrtValue) {
        ortFeeds[e.key] = handle;
      } else {
        final v = await _toOrtValue(e.value);
        uploaded.add(v);
        ortFeeds[e.key] = v;
      }
    }
    final Map<String, OrtValue> ortResult;
    try {
      ortResult = await session.run(ortFeeds);
    } finally {
      for (final v in uploaded) {
        await v.dispose();
      }
    }
    final result = <String, MTensor>{};
    for (final e in ortResult.entries) {
      if (fetch == null || fetch.contains(e.key)) {
        result[e.key] = await _fromOrtValue(e.value);
        await e.value.dispose();
      } else {
        result[e.key] = MTensor.handle(
            e.value, e.value.shape, _fromOrtDataType(e.value.dataType));
      }
    }
    return result;
  }

  @override
  Future<void> release(Iterable<MTensor> tensors) async {
    for (final t in tensors.toList()) {
      final handle = t.handle;
      if (handle is OrtValue) await handle.dispose();
    }
  }
}

// ---------------------------------------------------------------------
// The real handle.
// ---------------------------------------------------------------------

Future<MarianModelHandle> _openRealMarianHandle(
  MarianTranslatorFiles files,
) async {
  final ort = OnnxRuntime();
  final encoderSession = await ort.createSession(files.encoderPath);
  final decoderSession = await ort.createSession(files.decoderMergedPath);

  final List<SpmPiece> pieces;
  final MarianVocabulary vocab;
  final MarianModelConfig config;
  int? targetTokenId;
  try {
    pieces = parseSpmPieceTable(
      Uint8List.fromList(await File(files.sourceSpmPath).readAsBytes()),
    );
    vocab = MarianVocabulary.fromJsonBytes(
      Uint8List.fromList(await File(files.vocabPath).readAsBytes()),
    );
    config = MarianModelConfig.fromJsonBytes(
      config: Uint8List.fromList(await File(files.configPath).readAsBytes()),
      tokenizerConfig: Uint8List.fromList(
          await File(files.tokenizerConfigPath).readAsBytes()),
    );
    final token = files.targetToken;
    if (token != null) {
      // Without its token a multi-target model picks a language itself.
      targetTokenId = vocab.directiveId(token) ??
          (throw FormatException('vocab.json has no $token'));
    }
  } catch (e) {
    await encoderSession.close();
    await decoderSession.close();
    debugPrint('Marian tokenizer files unreadable: $e');
    throw const MarianModelInitException(
      "The downloaded translator’s files couldn’t be read. Try "
      'downloading it again in Models.',
    );
  }

  return _RealMarianModelHandle(
    encoderSession: encoderSession,
    decoderSession: decoderSession,
    loop: MarianGenerationLoop(
      encoderRunner: _OrtSessionRunner(encoderSession),
      decoderRunner: _OrtSessionRunner(decoderSession),
      tokenizer: MarianUnigramTokenizer(pieces),
      vocab: vocab,
      config: config,
      targetTokenId: targetTokenId,
    ),
  );
}

class _RealMarianModelHandle implements MarianModelHandle {
  final OrtSession encoderSession;
  final OrtSession decoderSession;
  final MarianGenerationLoop loop;

  _RealMarianModelHandle({
    required this.encoderSession,
    required this.decoderSession,
    required this.loop,
  });

  @override
  Future<String> translate(String sentence) => loop.translate(sentence);

  @override
  Future<void> dispose() async {
    await encoderSession.close();
    await decoderSession.close();
  }
}

// ---------------------------------------------------------------------
// The engine (mirrors SupertonicSpeechEngine's shape exactly: lazy
// residency via a cached Future, serialized calls through a queue,
// dispose waits for the in-flight call before releasing sessions).
// ---------------------------------------------------------------------

class MarianTranslator implements SentenceTranslator {
  final MarianTranslatorFiles files;
  final MarianModelHandleFactory _openHandle;

  Future<MarianModelHandle>? _handleFuture;
  Future<void> _translationQueue = Future.value();

  MarianTranslator({required this.files, MarianModelHandleFactory? openHandle})
    : _openHandle = openHandle ?? _openRealMarianHandle;

  /// Translates one sentence from the pair's source into its target.
  /// Concurrent calls are serialized one at a time — the same law
  /// [SupertonicSpeechEngine]
  /// follows, for the same reason: concurrent `session.run` calls against
  /// the same sessions are unproven, and Phase 3's translate-ahead
  /// lookahead can have more than one call in flight.
  @override
  Future<String> translate(String sentence) {
    final result = _translationQueue.then((_) async {
      final handle = await (_handleFuture ??= _open());
      return handle.translate(sentence);
    });
    _translationQueue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<MarianModelHandle> _open() async {
    _checkFilesPresent();
    try {
      return await _openHandle(files);
    } on MarianModelMissingFilesException {
      rethrow;
    } on MarianModelInitException {
      rethrow;
    } catch (e) {
      debugPrint('Marian translator failed to start: $e');
      throw const MarianModelInitException(
        "The downloaded translator couldn’t be started. Try downloading "
        'it again in Models.',
      );
    }
  }

  void _checkFilesPresent() {
    for (final path in files.allPaths) {
      if (!File(path).existsSync()) {
        throw const MarianModelMissingFilesException(
          'The translator is missing a file it needs. Try downloading '
          'its language again.',
        );
      }
    }
  }

  @override
  Future<void> dispose() async {
    final f = _handleFuture;
    _handleFuture = null;
    if (f == null) return;
    await _translationQueue;
    final MarianModelHandle handle;
    try {
      handle = await f;
    } catch (_) {
      return;
    }
    await handle.dispose();
  }
}
