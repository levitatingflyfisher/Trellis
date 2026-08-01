import 'package:ml_runtime/ml_runtime.dart';
import 'package:test/test.dart';
import 'package:whisper_ffi/src/unsupported.dart';

/// The non-ffi stand-ins behind the package's conditional export. On web
/// (any platform without dart:ffi) the app still compiles against the
/// whisper names; reaching them must refuse cleanly, naming the native
/// tier, never crash into missing-symbol weirdness.
void main() {
  test('open() refuses on a platform without dart:ffi', () {
    expect(
      () => WhisperBindings.open('libwhisper.so'),
      throwsA(isA<UnsupportedError>()
          .having((e) => e.message, 'message', contains('native'))),
    );
  });

  test('the stub transcriber still satisfies the seam, and refuses', () {
    // `implements Transcriber` is the compile-level pin: an ml_runtime
    // seam change breaks this stub the same build it breaks the real one.
    expect(
      () {
        final Transcriber t = WhisperTranscriber(
            bindings: const WhisperBindings.any(), modelPath: 'model.bin');
        return t;
      },
      throwsA(isA<UnsupportedError>()),
    );
  });
}
