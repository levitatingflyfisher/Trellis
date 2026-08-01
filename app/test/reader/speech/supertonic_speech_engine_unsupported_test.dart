import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/reader/speech/speech_engine.dart';
import 'package:trellis/features/reader/speech/supertonic_voice_handle.dart';
import 'package:trellis/features/reader/speech/src/supertonic_speech_engine_unsupported.dart';

/// The non-native stand-in behind supertonic_engine.dart's conditional
/// export. On web (or any platform without the native tier) the app still
/// compiles against the SupertonicSpeechEngine name; reaching it must
/// refuse cleanly, naming the native tier, never crash into missing-symbol
/// weirdness — the same law whisper_ffi's unsupported_stub_test pins.
void main() {
  test('the constructor refuses on a platform without the native tier', () {
    expect(
      () => SupertonicSpeechEngine(
          files: const SupertonicVoiceFiles(
              durationPredictorPath: 'dp.onnx',
              textEncoderPath: 'te.onnx',
              vectorEstimatorPath: 've.onnx',
              vocoderPath: 'v.onnx',
              unicodeIndexerPath: 'u.json',
              ttsConfigPath: 't.json',
              voiceStylePath: 's.json'),
          openHandle: (_) async => throw UnimplementedError()),
      throwsA(isA<UnsupportedError>()
          .having((e) => e.message, 'message', contains('native'))),
    );
  });

  test('the stub still satisfies the SynthesisSpeechEngine boundary, and '
      'refuses', () {
    // `implements SynthesisSpeechEngine` is the compile-level pin: a
    // change to that interface breaks this stub the same build it breaks
    // the real one.
    expect(
      () {
        SynthesisSpeechEngine engine() => SupertonicSpeechEngine(
            files: const SupertonicVoiceFiles(
                durationPredictorPath: 'dp.onnx',
                textEncoderPath: 'te.onnx',
                vectorEstimatorPath: 've.onnx',
                vocoderPath: 'v.onnx',
                unicodeIndexerPath: 'u.json',
                ttsConfigPath: 't.json',
                voiceStylePath: 's.json'));
        return engine();
      },
      throwsA(isA<UnsupportedError>()),
    );
  });
}
