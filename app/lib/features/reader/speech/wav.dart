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
