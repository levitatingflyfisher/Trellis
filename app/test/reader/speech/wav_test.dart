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

  group('reading back', readBackTests);
}

/// The phone's own voice writes each sentence to a WAV file (Android's
/// TextToSpeech.synthesizeToFile), which is read back into samples so the
/// saved episode can be stitched from it like any other voice's.
void readBackTests() {
  Uint8List riff(List<(String, Uint8List)> chunks) {
    final body = BytesBuilder()..add('WAVE'.codeUnits);
    for (final (id, data) in chunks) {
      final head = ByteData(8)..setUint32(4, data.length, Endian.little);
      for (var i = 0; i < 4; i++) {
        head.setUint8(i, id.codeUnitAt(i));
      }
      body
        ..add(head.buffer.asUint8List())
        ..add(data);
      if (data.length.isOdd) body.addByte(0);
    }
    final out = BytesBuilder()..add('RIFF'.codeUnits);
    final size = ByteData(4)..setUint32(0, body.length, Endian.little);
    out
      ..add(size.buffer.asUint8List())
      ..add(body.takeBytes());
    return out.takeBytes();
  }

  Uint8List fmt(int format, int channels, int rate, int bits) {
    final b = ByteData(16)
      ..setUint16(0, format, Endian.little)
      ..setUint16(2, channels, Endian.little)
      ..setUint32(4, rate, Endian.little)
      ..setUint32(8, rate * channels * bits ~/ 8, Endian.little)
      ..setUint16(12, channels * bits ~/ 8, Endian.little)
      ..setUint16(14, bits, Endian.little);
    return b.buffer.asUint8List();
  }

  Uint8List pcm16(List<int> values) {
    final b = ByteData(values.length * 2);
    for (var i = 0; i < values.length; i++) {
      b.setInt16(i * 2, values[i], Endian.little);
    }
    return b.buffer.asUint8List();
  }

  test('reads back what it writes', () {
    final samples = Float32List.fromList([0.0, 0.5, -0.5, 1.0, -1.0]);
    final read = readWav(wavBytes(samples, 24000))!;
    expect(read.sampleRate, 24000);
    expect(read.samples.length, 5);
    for (var i = 0; i < 5; i++) {
      expect(read.samples[i], closeTo(samples[i], 0.001));
    }
  });

  test('skips chunks it does not need, wherever they sit', () {
    final bytes = riff([
      ('LIST', Uint8List.fromList([1, 2, 3])),
      ('fmt ', fmt(1, 1, 22050, 16)),
      ('fact', Uint8List(4)),
      ('data', pcm16([16384, -16384])),
    ]);
    final read = readWav(bytes)!;
    expect(read.sampleRate, 22050);
    expect(read.samples, [closeTo(0.5, 0.001), closeTo(-0.5, 0.001)]);
  });

  test('two channels are mixed down to one', () {
    final read = readWav(riff([
      ('fmt ', fmt(1, 2, 16000, 16)),
      ('data', pcm16([16384, 0, -16384, -16384])),
    ]))!;
    expect(read.samples, [closeTo(0.25, 0.001), closeTo(-0.5, 0.001)]);
  });

  test('a data size left unwritten (streamed to the file) is read to the '
      'end of the file', () {
    final bytes = riff([
      ('fmt ', fmt(1, 1, 16000, 16)),
      ('data', pcm16([8192, 8192, 8192])),
    ]);
    ByteData.sublistView(bytes)
        .setUint32(bytes.length - 6 - 4, 0xFFFFFFFF, Endian.little);
    expect(readWav(bytes)!.samples.length, 3);
    ByteData.sublistView(bytes)
        .setUint32(bytes.length - 6 - 4, 0, Endian.little);
    expect(readWav(bytes)!.samples.length, 3);
  });

  test('8-bit and 32-bit float audio are read too', () {
    final eight = readWav(riff([
      ('fmt ', fmt(1, 1, 8000, 8)),
      ('data', Uint8List.fromList([128, 255, 0])),
    ]))!;
    expect(eight.samples,
        [closeTo(0, 0.01), closeTo(1, 0.01), closeTo(-1, 0.01)]);
    final f = ByteData(8)
      ..setFloat32(0, 0.25, Endian.little)
      ..setFloat32(4, -0.75, Endian.little);
    final float = readWav(riff([
      ('fmt ', fmt(3, 1, 48000, 32)),
      ('data', f.buffer.asUint8List()),
    ]))!;
    expect(float.samples, [0.25, -0.75]);
  });

  test('anything else is not audio it can read', () {
    expect(readWav(Uint8List(0)), isNull);
    expect(readWav(Uint8List.fromList('ID3 not a wave at all'.codeUnits)),
        isNull);
    expect(readWav(riff([('data', pcm16([1, 2]))])), isNull,
        reason: 'no format');
    expect(
        readWav(riff([
          ('fmt ', fmt(2, 1, 16000, 4)), // ADPCM
          ('data', Uint8List(8)),
        ])),
        isNull);
  });

  test('a sentence at another rate is brought to the file’s rate, keeping '
      'its length in time', () {
    final one = Float32List.fromList(List.filled(22050, 0.5));
    final out = resample(one, from: 22050, to: 44100);
    expect(out.length, 44100);
    expect(out.every((s) => (s - 0.5).abs() < 1e-6), isTrue);
    final ramp = Float32List.fromList([0, 1, 2, 3]);
    expect(resample(ramp, from: 2, to: 4),
        [0, 0.5, 1, 1.5, 2, 2.5, 3, 3]);
    expect(identical(resample(ramp, from: 4, to: 4), ramp), isTrue);
  });
}
