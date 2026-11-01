/// Web stand-in: the web build has no neural voice.
library;

import '../pocket_engine.dart';
import '../pocket_text.dart';

Future<PocketModel> openPocketModel(
        PocketVoiceFiles files, PocketLanguage language) =>
    throw UnsupportedError('Trellis’s voices need the native tier');
