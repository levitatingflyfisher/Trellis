/// The decode seam (proposal-2 §5): episode audio file → 16kHz mono float32
/// little-endian raw PCM **file** — never a giant buffer in RAM (the donor's
/// 3h-episode ≈ 700MB OOM).
///
/// Implementations:
///  * [WavPassthroughDecoder] — pure Dart, host-testable: accepts a WAV that
///    is already 16kHz mono (PCM16 or float32) and rewrites the samples as
///    f32le. Anything else gets an honest error naming what arrived.
///  * `FfmpegDecoder` (ffmpeg_decoder.dart) — the platform impl over the
///    pinned ffmpeg_kit community fork (PunctumTemporis precedent).
///  * tests script a fake.
library;

import 'dart:io';
import 'dart:typed_data';

class DecodeException implements Exception {
  final String message;
  DecodeException(this.message);

  @override
  String toString() => 'DecodeException: $message';
}

abstract class Decoder {
  /// Decodes [inputPath] into 16kHz mono float32 little-endian raw PCM at
  /// [outputPath]. The write is atomic: a `.part` grows next to the target
  /// and renames only when complete — a failure leaves NO output file (a
  /// half-decoded file must never masquerade as the episode).
  Future<void> decodeToPcm16kMono(String inputPath, String outputPath);
}

/// The pipeline's one sample rate (whisper's requirement).
const int kPcmSampleRate = 16000;

class WavPassthroughDecoder implements Decoder {
  @override
  Future<void> decodeToPcm16kMono(String inputPath, String outputPath) async {
    final bytes = await File(inputPath).readAsBytes();
    final part = File('$outputPath.part');
    try {
      final pcm = _convert(bytes);
      await part.writeAsBytes(pcm, flush: true);
      await part.rename(outputPath);
    } catch (_) {
      if (part.existsSync()) await part.delete();
      rethrow;
    }
  }

  Uint8List _convert(Uint8List bytes) {
    final wav = _parseWav(bytes);
    if (wav.sampleRate != kPcmSampleRate) {
      throw DecodeException(
          'this WAV is ${wav.sampleRate}Hz; the passthrough decoder needs '
          '$kPcmSampleRate Hz mono (use the ffmpeg decoder for anything else)');
    }
    if (wav.channels != 1) {
      throw DecodeException(
          'this WAV has ${wav.channels} channels; the passthrough decoder '
          'needs mono');
    }
    final data = ByteData.sublistView(wav.samples);
    if (wav.format == 3 && wav.bitsPerSample == 32) {
      return Uint8List.fromList(wav.samples); // already f32le
    }
    if (wav.format == 1 && wav.bitsPerSample == 16) {
      final n = wav.samples.length ~/ 2;
      final out = ByteData(n * 4);
      for (var i = 0; i < n; i++) {
        out.setFloat32(
            i * 4, data.getInt16(i * 2, Endian.little) / 32768.0, Endian.little);
      }
      return out.buffer.asUint8List();
    }
    throw DecodeException(
        'unsupported WAV encoding (format ${wav.format}, '
        '${wav.bitsPerSample}-bit) — PCM16 or float32 only');
  }

  _WavData _parseWav(Uint8List bytes) {
    if (bytes.length < 44 ||
        String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
      throw DecodeException('not a WAV file (no RIFF/WAVE header)');
    }
    final data = ByteData.sublistView(bytes);
    int? format, channels, sampleRate, bitsPerSample;
    Uint8List? samples;
    var off = 12;
    while (off + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(off, off + 4));
      final size = data.getUint32(off + 4, Endian.little);
      final body = off + 8;
      if (id == 'fmt ' && body + 16 <= bytes.length) {
        format = data.getUint16(body, Endian.little);
        channels = data.getUint16(body + 2, Endian.little);
        sampleRate = data.getUint32(body + 4, Endian.little);
        bitsPerSample = data.getUint16(body + 14, Endian.little);
      } else if (id == 'data') {
        final end = body + size;
        samples = Uint8List.sublistView(
            bytes, body, end > bytes.length ? bytes.length : end);
      }
      off = body + size + (size.isOdd ? 1 : 0); // RIFF chunks are word-aligned
    }
    if (format == null || samples == null) {
      throw DecodeException('malformed WAV: missing fmt or data chunk');
    }
    return _WavData(
        format: format,
        channels: channels!,
        sampleRate: sampleRate!,
        bitsPerSample: bitsPerSample!,
        samples: samples);
  }
}

class _WavData {
  final int format;
  final int channels;
  final int sampleRate;
  final int bitsPerSample;
  final Uint8List samples;
  _WavData(
      {required this.format,
      required this.channels,
      required this.sampleRate,
      required this.bitsPerSample,
      required this.samples});
}
