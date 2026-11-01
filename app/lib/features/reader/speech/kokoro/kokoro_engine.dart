/// Trellis's Chinese voice: Kokoro-82M v1.1-zh by hexgrad (Apache-2.0),
/// behind the [SynthesisSpeechEngine] contract (board-0211).
///
/// The text front end (misaki's Chinese G2P, ported to Dart in
/// `packages/mandarin_g2p`) turns a sentence into the model's token ids;
/// the model reads them with one style row from the voice file and a
/// speed, and returns 24 kHz audio. How the style row and the speed are
/// chosen follows the maker's own code:
///  * the style row is the phoneme count less one (kokoro
///    `pipeline.py`, `pack[len(ps)-1]`);
///  * the speed falls as a sentence grows ([kokoroZhSpeed], from the
///    maker's `samples/make_zh.py`: the model rushes past about 100
///    phonemes, which it saw little of in training).
///
/// The model's own graph draws random noise (its sine source), so the
/// same sentence never sounds bit-for-bit the same twice.
///
/// No ONNX Runtime here: the model sits behind [KokoroModel], so a host
/// test can fake it, and the real one lives in `kokoro_onnx.dart`. The
/// residency laws are the other engines': open on first use, one call at
/// a time, dispose waits for the call in flight.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../speech_engine.dart';

/// One piece of a sentence as the model reads it: the token ids with the
/// pad id 0 at each end, and how many phonemes it holds (misaki's
/// `len(ps)`, which counts a dropped `❓` too).
class KokoroChunk {
  final List<int> inputIds;
  final int lenPs;
  const KokoroChunk({required this.inputIds, required this.lenPs});
}

/// A sentence into the chunks the model reads, each at most 510
/// phonemes; empty when there is nothing it can say.
typedef KokoroFrontEnd = List<KokoroChunk> Function(String sentence);

/// The model: token ids, one style row, a speed; raw 24 kHz audio back.
abstract interface class KokoroModel {
  Future<Float32List> run(List<int> inputIds, Float32List style, double speed);
  Future<void> dispose();
}

/// The maker's speed for a chunk of [lenPs] phonemes (`speed_callable`
/// in Kokoro-82M-v1.1-zh's `samples/make_zh.py`): 1.1 up to 83, falling
/// in a straight line to 0.88 at 183, then 0.88.
double kokoroZhSpeed(int lenPs) {
  var speed = 0.8;
  if (lenPs <= 83) {
    speed = 1;
  } else if (lenPs < 183) {
    speed = 1 - (lenPs - 83) / 500;
  }
  return speed * 1.1;
}

const kokoroSampleRate = 24000;
const _styleDim = 256;
const _styleRows = 510;

class KokoroUnsupportedLangException implements Exception {
  final String message;
  const KokoroUnsupportedLangException(this.message);
  @override
  String toString() => message;
}

class KokoroMissingFilesException implements Exception {
  final String message;
  const KokoroMissingFilesException(this.message);
  @override
  String toString() => message;
}

class KokoroNativeInitException implements Exception {
  final String message;
  const KokoroNativeInitException(this.message);
  @override
  String toString() => message;
}

/// The model returned audio with a NaN in it: refused, never played.
class KokoroBadAudioException implements Exception {
  final String message;
  const KokoroBadAudioException(this.message);
  @override
  String toString() => message;
}

class KokoroSpeechEngine implements SynthesisSpeechEngine {
  /// The voice file: 510 rows of 256 float32 style values.
  final String voicePath;
  final Future<KokoroModel> Function() openModel;
  final Future<KokoroFrontEnd> Function() loadFrontEnd;

  Future<({KokoroModel model, KokoroFrontEnd frontEnd, Float32List voice})>?
      _ready;
  Future<void> _queue = Future.value();

  KokoroSpeechEngine({
    required this.voicePath,
    required this.openModel,
    required this.loadFrontEnd,
  });

  @override
  bool get canPause => true;

  @override
  Set<String> get speaks => const {'zh'};

  @override
  Future<SynthResult> synthesize(String sentence,
      {String? lang, SpeechPace pace = SpeechPace.natural}) {
    final base = lang?.trim().toLowerCase().split(RegExp('[-_]')).first;
    if (base != null && base.isNotEmpty && base != 'zh') {
      throw KokoroUnsupportedLangException(
          'This voice speaks Chinese only, not “$base”.');
    }
    final result = _queue.then((_) async {
      final r = await _readyOrOpen();
      final out = <Float32List>[];
      for (final chunk in r.frontEnd(sentence)) {
        final row = (chunk.lenPs - 1).clamp(0, _styleRows - 1);
        final style = Float32List.sublistView(
            r.voice, row * _styleDim, (row + 1) * _styleDim);
        final audio = await r.model.run(
            chunk.inputIds, style, kokoroZhSpeed(chunk.lenPs) * pace.rate);
        if (audio.any((s) => s.isNaN)) {
          throw const KokoroBadAudioException(
              'The Chinese voice made a broken sound for this sentence.');
        }
        out.add(audio);
      }
      final samples =
          Float32List(out.fold(0, (n, a) => n + a.length));
      var at = 0;
      for (final a in out) {
        samples.setAll(at, a);
        at += a.length;
      }
      return SynthResult(samples: samples, sampleRate: kokoroSampleRate);
    });
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// The opened voice; a failed open is forgotten, so the next sentence
  /// tries again.
  Future<({KokoroModel model, KokoroFrontEnd frontEnd, Float32List voice})>
      _readyOrOpen() {
    final opening = _ready ??= _open();
    opening.then((_) {}, onError: (_) {
      if (identical(_ready, opening)) _ready = null;
    });
    return opening;
  }

  Future<({KokoroModel model, KokoroFrontEnd frontEnd, Float32List voice})>
      _open() async {
    final file = File(voicePath);
    if (!file.existsSync() ||
        file.lengthSync() != _styleRows * _styleDim * 4) {
      throw const KokoroMissingFilesException(
          'The Chinese voice is missing a file it needs. Try downloading '
          'it again in Models.');
    }
    final bytes = await file.readAsBytes();
    final voice = Float32List.view(
        bytes.buffer, bytes.offsetInBytes, _styleRows * _styleDim);
    try {
      final frontEnd = await loadFrontEnd();
      final model = await openModel();
      return (model: model, frontEnd: frontEnd, voice: voice);
    } on KokoroMissingFilesException {
      rethrow;
    } catch (e) {
      debugPrint('Kokoro voice failed to start: $e');
      throw const KokoroNativeInitException(
          'The Chinese voice couldn’t be started. Try downloading it again '
          'in Models.');
    }
  }

  @override
  Future<void> dispose() async {
    final ready = _ready;
    _ready = null;
    if (ready == null) return;
    await _queue;
    try {
      await (await ready).model.dispose();
    } catch (_) {
      // It never opened.
    }
  }
}
