/// Non-native stand-in for [SupertonicSpeechEngine]. On a platform without
/// the native tier (the web build) the conditional export in
/// `supertonic_engine.dart` resolves here so the app still compiles — this
/// campaign's neural voice is a native-tier capability (ADR-0007: no web
/// neural tier yet), so reaching this class refuses cleanly instead of
/// pulling flutter_onnxruntime's native/plugin payload into a build that
/// would never use it.
library;

import '../supertonic_voice_handle.dart';
import '../speech_engine.dart';

class SupertonicSpeechEngine implements SynthesisSpeechEngine {
  SupertonicSpeechEngine({
    required SupertonicVoiceFiles files,
    SupertonicVoiceHandleFactory? openHandle,
  }) {
    throw UnsupportedError(
        'the neural voice needs the native tier; it is not available on '
        'this platform yet');
  }

  @override
  bool get canPause => true;

  @override
  Future<SynthResult> synthesize(String sentence, {String? lang}) =>
      throw UnsupportedError('unreachable: the constructor refuses');

  @override
  Future<void> dispose() async {}
}
