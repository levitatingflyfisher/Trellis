/// transcribe_core's seekable `PcmSource` over the decoded f32le PCM file.
///
/// Deterministic by construction: every read opens the file, reads exactly
/// the requested byte span, and closes it — no shared cursor, no cache. The
/// resume law leans on that: a window whose commit was lost is read a second
/// time and MUST yield identical samples.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:transcribe_core/transcribe_core.dart';

import 'decoder.dart' show kPcmSampleRate;

class FilePcmSource implements PcmSource {
  final File file;

  @override
  final int sampleRate;

  final int _totalSamples;

  FilePcmSource(this.file, {this.sampleRate = kPcmSampleRate})
      : _totalSamples = file.lengthSync() ~/ 4;

  @override
  int get totalMs => _totalSamples * 1000 ~/ sampleRate;

  @override
  Future<Float32List> readWindow(int startMs, int lenMs) async {
    final startSample = startMs * sampleRate ~/ 1000;
    final wanted = lenMs * sampleRate ~/ 1000;
    final available =
        (_totalSamples - startSample).clamp(0, wanted).toInt();

    final out = Float32List(wanted);
    if (available <= 0) return out;

    // Sync I/O on purpose: in production this runs on the dedicated
    // transcription isolate where blocking is free, and under
    // widget-test fake-async zones (where real io futures never fire) it
    // keeps the whole pipeline drivable by pumpAndSettle.
    final raf = file.openSync();
    try {
      raf.setPositionSync(startSample * 4);
      final bytes = raf.readSync(available * 4);
      final data = ByteData.sublistView(bytes);
      for (var i = 0; i < bytes.length ~/ 4; i++) {
        out[i] = data.getFloat32(i * 4, Endian.little);
      }
    } finally {
      raf.closeSync();
    }
    return out;
  }
}
