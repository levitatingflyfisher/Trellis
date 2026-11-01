/// Trellis's voice for German, Spanish, French, Italian, Portuguese,
/// Dutch and English: Pocket TTS by Kyutai (CC-BY-4.0 weights, MIT
/// code), converted to ONNX by Trellis, behind [SynthesisSpeechEngine]
/// (board-0211). One engine per language: each language has its own
/// weights and its own ready voice.
///
/// The model sits behind [PocketModel], so a host test fakes it; the
/// real one ([PocketGenerator] over four ONNX sessions) is opened by
/// `pocket_model.dart`. The residency laws are the other engines': open
/// on first use, one sentence at a time, a failed open tried again.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../speech_engine.dart';
import 'pocket_loop.dart' show pocketSampleRate;
import 'pocket_text.dart';

/// Where one Pocket TTS voice's files are, resolved from the model store.
class PocketVoiceFiles {
  final String textConditioner;
  final String main;
  final String flow;
  final String mimi;
  final String tokenizer;
  final String voice;
  const PocketVoiceFiles({
    required this.textConditioner,
    required this.main,
    required this.flow,
    required this.mimi,
    required this.tokenizer,
    required this.voice,
  });

  List<String> get all => [textConditioner, main, flow, mimi, tokenizer, voice];
}

/// The opened model: says one sentence in its voice.
abstract interface class PocketModel {
  Future<Float32List> say(String text, {required int steps});
  Future<void> dispose();
}

class PocketUnsupportedLangException implements Exception {
  final String message;
  const PocketUnsupportedLangException(this.message);
  @override
  String toString() => message;
}

class PocketNativeInitException implements Exception {
  final String message;
  const PocketNativeInitException(this.message);
  @override
  String toString() => message;
}

/// The flow net's steps per frame: Kyutai's 1 at a natural pace, 4 when
/// a saved episode asks for care in each sound.
int pocketFlowSteps(SpeechPace pace) => pace.careful ? 4 : 1;

/// Pocket TTS has no speed of its own. A slower pace leaves a pause after
/// each sentence instead, in proportion (a sentence at 0.75 is followed
/// by a third of its length in silence), and never more than 2 s.
int pocketPauseSamples(int spoken, SpeechPace pace) => pace.rate >= 1
    ? 0
    : math.min((spoken * (1 / pace.rate - 1)).round(), 2 * pocketSampleRate);

class PocketSpeechEngine implements SynthesisSpeechEngine {
  final PocketLanguage language;
  final Future<PocketModel> Function() open;

  Future<PocketModel>? _model;
  Future<void> _queue = Future.value();

  PocketSpeechEngine({required this.language, required this.open});

  @override
  bool get canPause => true;

  @override
  Set<String> get speaks => {language.tag};

  @override
  Future<SynthResult> synthesize(String sentence,
      {String? lang, SpeechPace pace = SpeechPace.natural}) {
    final base = lang?.trim().toLowerCase().split(RegExp('[-_]')).first;
    if (base != null && base.isNotEmpty && base != language.tag) {
      throw PocketUnsupportedLangException(
          'This voice speaks “${language.tag}” only, not “$base”.');
    }
    final result = _queue.then((_) async {
      final model = await _opened();
      final spoken = await model.say(sentence, steps: pocketFlowSteps(pace));
      final pause = pocketPauseSamples(spoken.length, pace);
      final samples = Float32List(spoken.length + pause)..setAll(0, spoken);
      return SynthResult(samples: samples, sampleRate: pocketSampleRate);
    });
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<PocketModel> _opened() {
    final opening = _model ??= () async {
      try {
        return await open();
      } catch (e) {
        debugPrint('Pocket TTS voice failed to start: $e');
        throw const PocketNativeInitException(
            'The voice couldn’t be started. Try downloading it again in '
            'Models.');
      }
    }();
    opening.then((_) {}, onError: (_) {
      if (identical(_model, opening)) _model = null;
    });
    return opening;
  }

  @override
  Future<void> dispose() async {
    final model = _model;
    _model = null;
    if (model == null) return;
    await _queue;
    try {
      await (await model).dispose();
    } catch (_) {
      // It never opened.
    }
  }
}
