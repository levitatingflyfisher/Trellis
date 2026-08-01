/// The offline DSP preprocess's platform boundary (Campaign 6, ADR-0012):
/// probing a file's duration and running the silenceremove+loudnorm
/// filter chain over it, encoding out through the SAME container/codec
/// family the input arrived in.
///
/// [FfmpegDspEncoder] (dsp_ffmpeg_encoder.dart) is the real, platform
/// implementation over the pinned ffmpeg_kit fork — Android/iOS only,
/// unreachable in any test here, mirroring `FfmpegDecoder`'s own status:
/// nothing in this checkout runs a real ffmpeg binary under `flutter
/// test`. Coordinator tests script a fake against this interface.
library;

class DspEncodeException implements Exception {
  final String message;
  DspEncodeException(this.message);

  @override
  String toString() => 'DspEncodeException: $message';
}

abstract class DspEncoder {
  /// Probes [path]'s duration in whole milliseconds. Throws
  /// [DspEncodeException] if the file can't be read as audio.
  Future<int> durationMs(String path);

  /// Runs the DSP filter chain on [inputPath], writing the result to
  /// [outputPath] — a plain write, not atomic on its own; the coordinator
  /// owns the atomic-promote step (a temp path in, a rename once the
  /// caller's own sanity check passes). [codec]/[bitrate] pick the
  /// encoder (see `dsp_params.dart`'s `dspCodecFor`/`dspBitrateFor`) —
  /// this interface stays codec-agnostic, the caller decides the format.
  Future<void> process({
    required String inputPath,
    required String outputPath,
    required String codec,
    String? bitrate,
  });
}

/// The honest refusal for a platform with no real DSP encoder wired
/// (today: every native tier but Android — the same gap `FfmpegDecoder`
/// leaves for decode, since neither ffmpeg rung is wired on desktop).
/// ADR-0003's "errors are sentences" law: a typed, named failure the
/// coordinator surfaces as a card error, never a silent no-op and never
/// a crash from a null implementation.
class UnavailableDspEncoder implements DspEncoder {
  @override
  Future<int> durationMs(String path) async => throw DspEncodeException(
    'offline DSP preprocessing needs ffmpeg, which this build only '
    'wires on Android',
  );

  @override
  Future<void> process({
    required String inputPath,
    required String outputPath,
    required String codec,
    String? bitrate,
  }) async => throw DspEncodeException(
    'offline DSP preprocessing needs ffmpeg, which this build only '
    'wires on Android',
  );
}
