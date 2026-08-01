/// Non-native stand-in for [MarianTranslator]. On a platform without the
/// native tier (the web build) the conditional export in
/// `marian_engine.dart` resolves here so the app still compiles — Babel's
/// on-device MT engine is a native-tier capability (ADR-0008: no web ONNX
/// tier for translation either, same posture as the Supertonic rung), so
/// reaching this class refuses cleanly instead of pulling
/// flutter_onnxruntime's native/plugin payload into a build that would
/// never use it.
library;

import '../marian_types.dart';

class MarianTranslator {
  MarianTranslator({
    required MarianTranslatorFiles files,
    MarianModelHandleFactory? openHandle,
  }) {
    throw UnsupportedError(
      'the Spanish translator needs the native tier; it is not '
      'available on this platform yet',
    );
  }

  Future<String> translate(String sentence) =>
      throw UnsupportedError('unreachable: the constructor refuses');

  Future<void> dispose() async {}
}
