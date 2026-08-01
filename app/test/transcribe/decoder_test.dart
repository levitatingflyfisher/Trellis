import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/transcribe/decoder.dart';

/// The decode step (proposal-2 §5): episode audio file → 16kHz mono float32
/// little-endian raw PCM *file*. The WAV passthrough impl is the
/// host-testable half of the Decoder seam — ffmpeg is a platform concern.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('trellis-decode');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  /// A minimal RIFF/WAVE file around [dataBytes].
  Uint8List wav({
    required int format, // 1 = PCM, 3 = IEEE float
    required int channels,
    required int sampleRate,
    required int bitsPerSample,
    required Uint8List dataBytes,
  }) {
    final blockAlign = channels * bitsPerSample ~/ 8;
    final b = BytesBuilder();
    void str(String s) => b.add(s.codeUnits);
    void u32(int v) =>
        b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
    void u16(int v) =>
        b.add((ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List());
    str('RIFF');
    u32(36 + dataBytes.length);
    str('WAVE');
    str('fmt ');
    u32(16);
    u16(format);
    u16(channels);
    u32(sampleRate);
    u32(sampleRate * blockAlign);
    u16(blockAlign);
    u16(bitsPerSample);
    str('data');
    u32(dataBytes.length);
    b.add(dataBytes);
    return b.toBytes();
  }

  Uint8List s16Bytes(List<int> samples) {
    final data = ByteData(samples.length * 2);
    for (var i = 0; i < samples.length; i++) {
      data.setInt16(i * 2, samples[i], Endian.little);
    }
    return data.buffer.asUint8List();
  }

  Uint8List f32Bytes(List<double> samples) {
    final data = ByteData(samples.length * 4);
    for (var i = 0; i < samples.length; i++) {
      data.setFloat32(i * 4, samples[i], Endian.little);
    }
    return data.buffer.asUint8List();
  }

  List<double> readF32(File f) {
    final bytes = f.readAsBytesSync();
    final data = ByteData.sublistView(bytes);
    return [
      for (var i = 0; i < bytes.length ~/ 4; i++)
        data.getFloat32(i * 4, Endian.little)
    ];
  }

  group('WavPassthroughDecoder', () {
    test('decodes 16kHz mono PCM16 to f32le raw PCM', () async {
      final input = File('${tmp.path}/in.wav')
        ..writeAsBytesSync(wav(
            format: 1,
            channels: 1,
            sampleRate: 16000,
            bitsPerSample: 16,
            dataBytes: s16Bytes([0, 16384, -16384, 32767, -32768])));
      final out = File('${tmp.path}/out.f32');

      await WavPassthroughDecoder().decodeToPcm16kMono(input.path, out.path);

      final samples = readF32(out);
      expect(samples, hasLength(5));
      expect(samples[0], closeTo(0.0, 1e-6));
      expect(samples[1], closeTo(0.5, 1e-4));
      expect(samples[2], closeTo(-0.5, 1e-4));
      expect(samples[3], closeTo(1.0, 1e-4));
      expect(samples[4], closeTo(-1.0, 1e-4));
    });

    test('passes 16kHz mono float32 WAV through with identical values',
        () async {
      final values = [0.25, -0.75, 0.0, 1.0];
      final input = File('${tmp.path}/in.wav')
        ..writeAsBytesSync(wav(
            format: 3,
            channels: 1,
            sampleRate: 16000,
            bitsPerSample: 32,
            dataBytes: f32Bytes(values)));
      final out = File('${tmp.path}/out.f32');

      await WavPassthroughDecoder().decodeToPcm16kMono(input.path, out.path);

      final samples = readF32(out);
      for (var i = 0; i < values.length; i++) {
        expect(samples[i], closeTo(values[i], 1e-6));
      }
    });

    test('refuses a 44.1kHz file with an honest error', () async {
      final input = File('${tmp.path}/in.wav')
        ..writeAsBytesSync(wav(
            format: 1,
            channels: 1,
            sampleRate: 44100,
            bitsPerSample: 16,
            dataBytes: s16Bytes([0])));
      final out = File('${tmp.path}/out.f32');

      await expectLater(
          WavPassthroughDecoder().decodeToPcm16kMono(input.path, out.path),
          throwsA(isA<DecodeException>()
              .having((e) => e.message, 'message', contains('16000'))));
      expect(out.existsSync(), isFalse,
          reason: 'a failed decode must leave no output masquerading as PCM');
    });

    test('refuses stereo', () async {
      final input = File('${tmp.path}/in.wav')
        ..writeAsBytesSync(wav(
            format: 1,
            channels: 2,
            sampleRate: 16000,
            bitsPerSample: 16,
            dataBytes: s16Bytes([0, 0])));

      await expectLater(
          WavPassthroughDecoder()
              .decodeToPcm16kMono(input.path, '${tmp.path}/out.f32'),
          throwsA(isA<DecodeException>()));
    });

    test('refuses non-WAV bytes', () async {
      final input = File('${tmp.path}/in.mp3')
        ..writeAsBytesSync([0xFF, 0xFB, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);

      await expectLater(
          WavPassthroughDecoder()
              .decodeToPcm16kMono(input.path, '${tmp.path}/out.f32'),
          throwsA(isA<DecodeException>()));
    });

    test('no .part residue survives a failure', () async {
      final input = File('${tmp.path}/in.bin')..writeAsBytesSync([1, 2, 3]);
      try {
        await WavPassthroughDecoder()
            .decodeToPcm16kMono(input.path, '${tmp.path}/out.f32');
      } on DecodeException {
        // expected
      }
      expect(
          tmp
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.part')),
          isEmpty);
    });
  });
}
