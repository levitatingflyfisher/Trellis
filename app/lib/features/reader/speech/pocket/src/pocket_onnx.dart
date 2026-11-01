/// Pocket TTS over `flutter_onnxruntime`: the four graphs of Trellis's
/// export, the language's tokenizer and Kyutai's ready voice, driven by
/// [PocketGenerator]. Never imported directly; always through
/// `pocket_model.dart`.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:ml_runtime/ml_runtime.dart' show UnigramTokenizer;

import '../../../translation/src/ort_session_runner.dart';
import '../pocket_engine.dart';
import '../pocket_loop.dart';
import '../pocket_text.dart';
import '../pocket_voice.dart';

Future<PocketModel> openPocketModel(
    PocketVoiceFiles files, PocketLanguage language) async {
  for (final path in files.all) {
    if (!File(path).existsSync()) {
      throw FileSystemException('a voice file is missing', path);
    }
  }
  final tokenizer =
      UnigramTokenizer.fromJson(await File(files.tokenizer).readAsString());
  final voice = loadPocketVoice(await File(files.voice).readAsBytes());
  final ort = OnnxRuntime();
  final sessions = <OrtSession>[];
  try {
    for (final path in [files.textConditioner, files.main, files.flow, files.mimi]) {
      sessions.add(await ort.createSession(path));
    }
  } catch (_) {
    for (final s in sessions) {
      await s.close();
    }
    rethrow;
  }
  final generator = PocketGenerator(
    conditioner: OrtSessionRunner(sessions[0]),
    main: OrtSessionRunner(sessions[1]),
    flow: OrtSessionRunner(sessions[2]),
    mimi: OrtSessionRunner(sessions[3]),
    tokenizer: tokenizer,
    language: language,
    noise: gaussianNoise(math.Random()),
  );
  return _OrtPocketModel(generator, voice, sessions);
}

class _OrtPocketModel implements PocketModel {
  final PocketGenerator generator;
  final PocketVoice voice;
  final List<OrtSession> sessions;
  _OrtPocketModel(this.generator, this.voice, this.sessions);

  @override
  Future<Float32List> say(String text, {required int steps}) =>
      generator.synthesize(text, voice, steps: steps);

  @override
  Future<void> dispose() async {
    for (final s in sessions) {
      await s.close();
    }
  }
}
