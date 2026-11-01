/// The Russian voice's text front end on the phone: the voice config and
/// the stress table read and parsed off the main isolate (the table is
/// about two million lines), then each sentence marked, turned into the
/// denis voice's phonemes by `russian_g2p`, and split into symbols.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:russian_g2p/russian_g2p.dart';

import 'piper_engine.dart';
import 'piper_voice_config.dart';

/// [configPath] is the voice's `.onnx.json`; [stressPath] the stress
/// table. Without a table, a word whose stress is not marked in the text
/// is said with no stress.
Future<PiperFrontEnd> loadPiperFrontEnd({
  required String configPath,
  String? stressPath,
}) async {
  for (final path in [configPath, ?stressPath]) {
    if (!File(path).existsSync()) {
      throw const PiperMissingFilesException(
        'The Russian voice is missing a file it needs. Try downloading '
        'it again in Models.',
      );
    }
  }
  final (config, stress) = await Isolate.run(
    () => (
      PiperVoiceConfig.parse(File(configPath).readAsStringSync()),
      stressPath == null
          ? null
          : RussianStressTable.fromBytes(File(stressPath).readAsBytesSync()),
    ),
  );
  return PiperFrontEnd(
    config: config,
    phonemes: (sentence) => phonemeSymbols(
      sentencePhonemes(stress == null ? sentence : stress.mark(sentence)),
    ),
  );
}
