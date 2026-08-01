import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/reader/speech/wav.dart';

/// The minimal 16-bit mono WAV encoder the pipeline writes each synthesized
/// sentence to disk with — just_audio's file source reads this on every
/// platform with no extra codec, and it round-trips cleanly.
void main() {
  test('writes a well-formed RIFF/WAVE header', () {
    final samples = Float32List.fromList([0.0, 0.5, -0.5, 1.0, -1.0]);
    final bytes = wavBytes(samples, 22050);
    final data = ByteData.sublistView(bytes);

    String tag(int offset) =>
        String.fromCharCodes(bytes.sublist(offset, offset + 4));

    expect(tag(0), 'RIFF');
    expect(tag(8), 'WAVE');
    expect(tag(12), 'fmt ');
    expect(tag(36), 'data');
    expect(data.getUint32(4, Endian.little), bytes.length - 8);
    expect(data.getUint16(20, Endian.little), 1, reason: 'PCM format code');
    expect(data.getUint16(22, Endian.little), 1, reason: 'mono channel count');
    expect(data.getUint32(24, Endian.little), 22050);
    expect(data.getUint16(34, Endian.little), 16, reason: 'bits per sample');
    expect(data.getUint32(40, Endian.little), samples.length * 2);
    expect(bytes.length, 44 + samples.length * 2);
  });

  test('samples round-trip within 16-bit rounding error', () {
    final samples = Float32List.fromList([0.0, 0.5, -0.5, 1.0, -1.0]);
    final bytes = wavBytes(samples, 16000);
    final data = ByteData.sublistView(bytes);
    final decoded = [
      for (var i = 0; i < samples.length; i++)
        data.getInt16(44 + i * 2, Endian.little) / 32767.0,
    ];
    for (var i = 0; i < samples.length; i++) {
      expect(decoded[i], closeTo(samples[i], 0.001));
    }
  });

  test('an empty sample list still produces a valid (silent) header', () {
    final bytes = wavBytes(Float32List(0), 22050);
    expect(bytes.length, 44);
    final data = ByteData.sublistView(bytes);
    expect(data.getUint32(40, Endian.little), 0);
  });
}
