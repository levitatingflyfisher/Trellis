/// The real Marian implementation (ADR-0008 "Babel"): opus-mt-en-es over
/// `flutter_onnxruntime`, behind [MarianTranslator]. Must stay the
/// DEFAULT branch of `marian_engine.dart`'s conditional export — never
/// imported directly by app code; always through the barrel. Mirrors
/// `supertonic_speech_engine.dart`'s shape (residency, serialized-call,
/// dispose-waits laws) — same file, read first if this one is unclear.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:ml_runtime/ml_runtime.dart';

import '../marian_generation_loop.dart';
import '../marian_types.dart';

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
  Future<Map<String, MTensor>> run(Map<String, MTensor> feeds) async {
    final ortFeeds = <String, OrtValue>{
      for (final e in feeds.entries) e.key: await _toOrtValue(e.value),
    };
    final ortResult = await session.run(ortFeeds);
    final result = <String, MTensor>{
      for (final e in ortResult.entries) e.key: await _fromOrtValue(e.value),
    };
    for (final v in ortFeeds.values) {
      await v.dispose();
    }
    for (final v in ortResult.values) {
      await v.dispose();
    }
    return result;
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
  try {
    pieces = parseSpmPieceTable(
      Uint8List.fromList(await File(files.sourceSpmPath).readAsBytes()),
    );
    vocab = MarianVocabulary.fromJsonBytes(
      Uint8List.fromList(await File(files.vocabPath).readAsBytes()),
    );
  } catch (e) {
    await encoderSession.close();
    await decoderSession.close();
    throw MarianModelInitException(
      'The downloaded translator\'s tokenizer files could not be read '
      '($e). Try re-downloading it in Models.',
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

class MarianTranslator {
  final MarianTranslatorFiles files;
  final MarianModelHandleFactory _openHandle;

  Future<MarianModelHandle>? _handleFuture;
  Future<void> _translationQueue = Future.value();

  MarianTranslator({required this.files, MarianModelHandleFactory? openHandle})
    : _openHandle = openHandle ?? _openRealMarianHandle;

  /// Translates one English sentence into Spanish. Concurrent calls are
  /// serialized one at a time — the same law [SupertonicSpeechEngine]
  /// follows, for the same reason: concurrent `session.run` calls against
  /// the same sessions are unproven, and Phase 3's translate-ahead
  /// lookahead can have more than one call in flight.
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
      throw MarianModelInitException(
        'The downloaded translator could not be started ($e). Try '
        're-downloading it in Models.',
      );
    }
  }

  void _checkFilesPresent() {
    for (final path in [
      files.encoderPath,
      files.decoderMergedPath,
      files.sourceSpmPath,
      files.vocabPath,
    ]) {
      if (!File(path).existsSync()) {
        throw MarianModelMissingFilesException(
          'The Spanish translator is missing a file it needs — try '
          're-downloading it in Models.',
        );
      }
    }
  }

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
