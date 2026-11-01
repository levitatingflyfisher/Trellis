/// Web stand-in for the Kokoro model: the web build has no neural voice.
library;

import '../kokoro_engine.dart';

Future<KokoroModel> openKokoroModel(String modelPath) =>
    throw UnsupportedError('the Chinese voice needs the native tier');

Future<KokoroFrontEnd> loadKokoroFrontEnd(Map<String, String> paths) =>
    throw UnsupportedError('the Chinese voice needs the native tier');
