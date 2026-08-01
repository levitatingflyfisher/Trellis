import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/transcribe/file_pcm_source.dart';

/// The seekable PCM adapter: transcribe_core's `PcmSource` over the decoded
/// f32le file. Re-reading a window MUST return identical samples — the
/// resume law re-transcribes a window whose commit was lost.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('trellis-pcm');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  /// [n] float32 samples where sample i has value i / 100000.
  File pcmFile(int n) {
    final data = ByteData(n * 4);
    for (var i = 0; i < n; i++) {
      data.setFloat32(i * 4, i / 100000, Endian.little);
    }
    return File('${tmp.path}/audio.f32')
      ..writeAsBytesSync(data.buffer.asUint8List());
  }

  test('totalMs derives from the file length at 16kHz', () async {
    // 32000 samples at 16kHz = 2000ms.
    final src = FilePcmSource(pcmFile(32000));
    expect(src.sampleRate, 16000);
    expect(src.totalMs, 2000);
  });

  test('readWindow returns exactly the requested span', () async {
    final src = FilePcmSource(pcmFile(32000));
    // [500ms, 750ms) = samples 8000..12000.
    final window = await src.readWindow(500, 250);
    expect(window, hasLength(4000));
    expect(window[0], closeTo(8000 / 100000, 1e-6));
    expect(window[3999], closeTo(11999 / 100000, 1e-6));
  });

  test('re-reading the same window is byte-identical', () async {
    final src = FilePcmSource(pcmFile(16000));
    final a = await src.readWindow(200, 300);
    final b = await src.readWindow(200, 300);
    expect(a, equals(b));
  });

  test('a window clipped at the end of audio returns the remaining samples',
      () async {
    final src = FilePcmSource(pcmFile(16000)); // 1000ms
    final window = await src.readWindow(900, 100);
    expect(window, hasLength(1600));
    expect(window.last, closeTo(15999 / 100000, 1e-6));
  });
}
