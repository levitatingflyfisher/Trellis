/// Web stand-in for the Piper model: the web build has no neural voice.
library;

import '../piper_engine.dart';

Future<PiperModel> openPiperModel(String modelPath) =>
    throw UnsupportedError('the Russian voice needs the native tier');

Future<PiperFrontEnd> loadPiperFrontEnd({
  required String configPath,
  String? stressPath,
}) => throw UnsupportedError('the Russian voice needs the native tier');
