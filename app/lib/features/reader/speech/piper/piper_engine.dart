/// Trellis's Russian voice: Piper's ru_RU denis (medium), weights MIT and
/// recordings CC0, behind the [SynthesisSpeechEngine] contract.
///
/// A sentence becomes sound in four steps: the stress table marks each
/// word's stressed vowel (`RussianStressTable` in `packages/russian_g2p`),
/// the rules of Russian pronunciation turn the marked text into the
/// voice's IPA (`sentencePhonemes`), the voice config turns those
/// phonemes into ids ([PiperVoiceConfig.ids]), and the model reads the ids
/// and returns 22,050 Hz audio. Like Piper itself, each sentence is then
/// brought to full scale and clipped to [-1, 1] (Piper's
/// `normalize_audio`, on by default).
///
/// No ONNX Runtime here: the model sits behind [PiperModel], so a host
/// test can fake it, and the real one lives in `piper_onnx.dart`. The
/// residency laws are the other engines': open on first use, one call at
/// a time, dispose waits for the call in flight.
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../speech_engine.dart';
import 'piper_voice_config.dart';

/// The voice's text side, read once: the config, and a sentence into the
/// voice's phonemes, one symbol each (empty when there is nothing to say).
class PiperFrontEnd {
  final PiperVoiceConfig config;
  final List<String> Function(String sentence) phonemes;
  const PiperFrontEnd({required this.config, required this.phonemes});
}

/// The model: Piper ids and the three scales; raw audio back.
abstract interface class PiperModel {
  Future<Float32List> run(List<int> ids, Float32List scales);
  Future<void> dispose();
}

class PiperUnsupportedLangException implements Exception {
  final String message;
  const PiperUnsupportedLangException(this.message);
  @override
  String toString() => message;
}

class PiperMissingFilesException implements Exception {
  final String message;
  const PiperMissingFilesException(this.message);
  @override
  String toString() => message;
}

class PiperNativeInitException implements Exception {
  final String message;
  const PiperNativeInitException(this.message);
  @override
  String toString() => message;
}

/// The model returned audio with a NaN in it: refused, never played.
class PiperBadAudioException implements Exception {
  final String message;
  const PiperBadAudioException(this.message);
  @override
  String toString() => message;
}

class PiperSpeechEngine implements SynthesisSpeechEngine {
  final Future<PiperModel> Function() openModel;
  final Future<PiperFrontEnd> Function() loadFrontEnd;

  Future<({PiperModel model, PiperFrontEnd frontEnd})>? _ready;
  Future<void> _queue = Future.value();

  PiperSpeechEngine({required this.openModel, required this.loadFrontEnd});

  @override
  bool get canPause => true;

  @override
  Set<String> get speaks => const {'ru'};

  @override
  Future<SynthResult> synthesize(
    String sentence, {
    String? lang,
    SpeechPace pace = SpeechPace.natural,
  }) {
    final base = lang?.trim().toLowerCase().split(RegExp('[-_]')).first;
    if (base != null && base.isNotEmpty && base != 'ru') {
      throw PiperUnsupportedLangException(
        'This voice speaks Russian only, not “$base”.',
      );
    }
    final result = _queue.then((_) async {
      final r = await _readyOrOpen();
      final config = r.frontEnd.config;
      final phonemes = r.frontEnd.phonemes(sentence);
      if (phonemes.isEmpty) {
        return SynthResult(
          samples: Float32List(0),
          sampleRate: config.sampleRate,
        );
      }
      final audio = await r.model.run(
        config.ids(phonemes),
        config.scales(rate: pace.rate),
      );
      if (audio.any((s) => s.isNaN)) {
        throw const PiperBadAudioException(
          'The Russian voice made a broken sound for this sentence.',
        );
      }
      return SynthResult(
        samples: _fullScale(audio),
        sampleRate: config.sampleRate,
      );
    });
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// [audio] scaled so its loudest sample is 1, then clipped; silence
  /// stays silence (Piper's `normalize_audio`).
  static Float32List _fullScale(Float32List audio) {
    var peak = 0.0;
    for (final s in audio) {
      final a = s.abs();
      if (a > peak) peak = a;
    }
    if (peak < 1e-8) return Float32List(audio.length);
    final out = Float32List(audio.length);
    for (var i = 0; i < audio.length; i++) {
      out[i] = (audio[i] / peak).clamp(-1.0, 1.0);
    }
    return out;
  }

  /// The opened voice; a failed open is forgotten, so the next sentence
  /// tries again.
  Future<({PiperModel model, PiperFrontEnd frontEnd})> _readyOrOpen() {
    final opening = _ready ??= _open();
    opening.then(
      (_) {},
      onError: (_) {
        if (identical(_ready, opening)) _ready = null;
      },
    );
    return opening;
  }

  Future<({PiperModel model, PiperFrontEnd frontEnd})> _open() async {
    try {
      final frontEnd = await loadFrontEnd();
      final model = await openModel();
      return (model: model, frontEnd: frontEnd);
    } on PiperMissingFilesException {
      rethrow;
    } catch (e) {
      debugPrint('Piper voice failed to start: $e');
      throw const PiperNativeInitException(
        'The Russian voice couldn’t be started. Try downloading it again '
        'in Models.',
      );
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
