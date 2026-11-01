/// The minimal 16-bit mono WAV encoder the speech pipeline writes each
/// synthesized sentence to disk with (ADR-0006). just_audio's file source
/// reads this on every platform with no extra codec — no reason to add a
/// second audio format when the fleet's one player already speaks WAV.
library;

import 'dart:typed_data';

/// Encodes [samples] — linear PCM in `[-1.0, 1.0]`, the synthesis engines'
/// convention — as a 16-bit mono WAV file. Out-of-range samples clamp
/// rather than wrap, so a stray engine overshoot is a quiet click, never a
/// pop.
Uint8List wavBytes(Float32List samples, int sampleRate) {
  final dataLength = samples.length * 2; // 16-bit samples
  final bytes = ByteData(44 + dataLength);

  void writeAscii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      bytes.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  const bitsPerSample = 16;
  const channels = 1;
  final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
  final blockAlign = channels * bitsPerSample ~/ 8;

  writeAscii(0, 'RIFF');
  bytes.setUint32(4, 36 + dataLength, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little); // fmt chunk size
  bytes.setUint16(20, 1, Endian.little); // PCM
  bytes.setUint16(22, channels, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, byteRate, Endian.little);
  bytes.setUint16(32, blockAlign, Endian.little);
  bytes.setUint16(34, bitsPerSample, Endian.little);
  writeAscii(36, 'data');
  bytes.setUint32(40, dataLength, Endian.little);

  for (var i = 0; i < samples.length; i++) {
    final clamped = samples[i].clamp(-1.0, 1.0);
    bytes.setInt16(44 + i * 2, (clamped * 32767).round(), Endian.little);
  }

  return bytes.buffer.asUint8List();
}

/// Reads a WAV file's audio back as mono samples in `[-1.0, 1.0]`, or
/// null when it is not one this can read. The phone's own voice writes
/// each sentence to such a file (Android's `synthesizeToFile`), and the
/// engine decides its rate and layout, so this takes what engines write:
/// 8, 16, 24 or 32-bit integer PCM or 32-bit float, any number of
/// channels (mixed down), extra chunks anywhere. A data size the engine
/// left unwritten (0, or all ones while it streamed) means "to the end".
({Float32List samples, int sampleRate})? readWav(Uint8List bytes) {
  if (bytes.length < 12) return null;
  String id(int at) => String.fromCharCodes(bytes, at, at + 4);
  if (id(0) != 'RIFF' || id(8) != 'WAVE') return null;
  final view = ByteData.sublistView(bytes);
  int? format, channels, rate, bits;
  var at = 12;
  while (at + 8 <= bytes.length) {
    final chunk = id(at);
    var size = view.getUint32(at + 4, Endian.little);
    final body = at + 8;
    if (chunk == 'fmt ' && size >= 16 && body + 16 <= bytes.length) {
      format = view.getUint16(body, Endian.little);
      channels = view.getUint16(body + 2, Endian.little);
      rate = view.getUint32(body + 4, Endian.little);
      bits = view.getUint16(body + 14, Endian.little);
      // WAVE_FORMAT_EXTENSIBLE: the real format is the sub-format's
      // first two bytes.
      if (format == 0xFFFE && size >= 26 && body + 26 <= bytes.length) {
        format = view.getUint16(body + 24, Endian.little);
      }
    } else if (chunk == 'data') {
      if (format == null || channels == null || rate == null || bits == null) {
        return null;
      }
      if (size == 0 || size == 0xFFFFFFFF || body + size > bytes.length) {
        size = bytes.length - body;
      }
      return _samples(view, body, size, format, channels, rate, bits);
    }
    at = body + size + (size.isOdd ? 1 : 0);
  }
  return null;
}

({Float32List samples, int sampleRate})? _samples(ByteData view, int start,
    int size, int format, int channels, int rate, int bits) {
  if (channels < 1 || rate < 1) return null;
  final double Function(int at)? sample = switch ((format, bits)) {
    (1, 8) => (at) => (view.getUint8(at) - 128) / 127.0,
    (1, 16) => (at) => view.getInt16(at, Endian.little) / 32767.0,
    (1, 24) => (at) {
        final v = view.getUint8(at) |
            view.getUint8(at + 1) << 8 |
            view.getInt8(at + 2) << 16;
        return v / 8388607.0;
      },
    (1, 32) => (at) => view.getInt32(at, Endian.little) / 2147483647.0,
    (3, 32) => (at) => view.getFloat32(at, Endian.little),
    _ => null,
  };
  if (sample == null) return null;
  final width = bits ~/ 8;
  final frames = size ~/ (width * channels);
  final out = Float32List(frames);
  for (var f = 0; f < frames; f++) {
    var sum = 0.0;
    for (var c = 0; c < channels; c++) {
      sum += sample(start + (f * channels + c) * width);
    }
    out[f] = (sum / channels).clamp(-1.0, 1.0);
  }
  return (samples: out, sampleRate: rate);
}

/// [samples] at the rate [to], by straight lines between neighbours: a
/// saved episode is one file at one rate, and a voice may hand one
/// sentence at another. Speech is not music, and nothing finer is
/// needed for it. The same list when the rates match.
Float32List resample(Float32List samples,
    {required int from, required int to}) {
  if (from == to || samples.isEmpty || from <= 0 || to <= 0) return samples;
  final n = (samples.length * to / from).round();
  final out = Float32List(n);
  final last = samples.length - 1;
  for (var i = 0; i < n; i++) {
    final x = i * from / to;
    final k = x.floor();
    if (k >= last) {
      out[i] = samples[last];
    } else {
      final t = x - k;
      out[i] = samples[k] * (1 - t) + samples[k + 1] * t;
    }
  }
  return out;
}
