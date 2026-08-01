/// Native integration test: loads the real `libwhisper.so` built by
/// `../../natives/build-linux.sh` and the pinned ggml-tiny model, and runs
/// the full lifecycle twice over generated, speech-free audio.
///
/// Downloads NOTHING. The audio is synthesized in the test (silence + a
/// 440Hz sine + silence); the transcript is expected to be empty or
/// near-empty — the assertions are about lifecycle: init, run, stream
/// closes, chunks well-formed, a second run works (no leak, no
/// double-free, no crash).
///
/// Never executes in a plain `dart test` (see dart_test.yaml). Run with:
///
///   dart test --tags native --run-skipped
///
/// Paths (overridable by env):
///   WHISPER_FFI_LIB        default ../../natives/out/linux/libwhisper.so
///   WHISPER_FFI_TEST_MODEL default ../../natives/models/ggml-tiny-q8_0.bin
///     (the registry-pinned whisper-tiny-ggml file — 43537433 bytes, sha256
///      c2085835d3f50733e2ff6e4b41ae8a2b8d8110461e18821b09a15c40c42d1cca;
///      see ../../natives/README.md for the verified download recipe.)
@Tags(['native'])
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ml_runtime/ml_runtime.dart';
import 'package:test/test.dart';
import 'package:whisper_ffi/whisper_ffi.dart';

String _fromEnvOrDefault(String key, String fallback) {
  final v = Platform.environment[key];
  return (v == null || v.isEmpty) ? fallback : v;
}

/// 3 seconds of 16kHz speech-free audio: 1s silence, 1s 440Hz sine at low
/// amplitude, 1s silence.
Float32List _sineWithSilence() {
  const rate = 16000;
  final samples = Float32List(3 * rate);
  for (var i = rate; i < 2 * rate; i++) {
    samples[i] = 0.1 * math.sin(2 * math.pi * 440 * (i - rate) / rate);
  }
  return samples;
}

void main() {
  final libPath = _fromEnvOrDefault(
      'WHISPER_FFI_LIB', '../../natives/out/linux/libwhisper.so');
  final modelPath = _fromEnvOrDefault(
      'WHISPER_FFI_TEST_MODEL', '../../natives/models/ggml-tiny-q8_0.bin');

  test('init, transcribe speech-free audio, stream closes, no leak/crash',
      () async {
    expect(File(libPath).existsSync(), isTrue,
        reason: 'native library missing at $libPath — '
            'build it with natives/build-linux.sh (see natives/README.md)');
    expect(File(modelPath).existsSync(), isTrue,
        reason: 'model missing at $modelPath — download the pinned '
            'ggml-tiny-q8_0.bin per natives/README.md (verify sha256 first)');

    final bindings = WhisperBindings.open(libPath);
    final transcriber =
        WhisperTranscriber(bindings: bindings, modelPath: modelPath);

    Future<List<TranscriptChunk>> run() =>
        transcriber.transcribe(ListPcmSource([_sineWithSilence()])).toList();

    // First full lifecycle: init -> full -> read segments -> free.
    final chunks = await run();
    for (final c in chunks) {
      expect(c.tStartMs, greaterThanOrEqualTo(0));
      expect(c.tEndMs, greaterThanOrEqualTo(c.tStartMs));
      final words = c.words;
      if (words != null) {
        for (final w in words) {
          expect(w.tEndMs, greaterThanOrEqualTo(w.tStartMs));
        }
      }
    }
    // Speech-free input: empty or near-empty output (whisper may hallucinate
    // a token or two on tones/silence; that is documented, not a failure).
    final text = chunks.map((c) => c.text).join(' ');
    expect(text.length, lessThan(1000),
        reason: 'speech-free audio should not produce a real transcript');

    // Second lifecycle on the same transcriber: proves free/re-init works —
    // no leaked context, no double-free, no crash.
    final again = await run();
    for (final c in again) {
      expect(c.tEndMs, greaterThanOrEqualTo(c.tStartMs));
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
