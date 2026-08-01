/// The platform half of the Decoder seam: any episode format → 16kHz mono
/// f32le raw PCM via the pinned ffmpeg_kit community fork (the fleet's
/// PunctumTemporis precedent). Android/iOS only — hosts test through
/// `WavPassthroughDecoder` and fakes; nothing here is reachable in a test.
library;

import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';

import 'decoder.dart';

class FfmpegDecoder implements Decoder {
  @override
  Future<void> decodeToPcm16kMono(String inputPath, String outputPath) async {
    final part = File('$outputPath.part');
    await part.parent.create(recursive: true);
    try {
      final session = await FFmpegKit.execute(
          '-y -i "$inputPath" -vn -ac 1 -ar $kPcmSampleRate -f f32le '
          '"${part.path}"');
      final rc = await session.getReturnCode();
      if (!ReturnCode.isSuccess(rc)) {
        final failLine = await session.getFailStackTrace();
        throw DecodeException(
            'ffmpeg could not decode $inputPath (code ${rc?.getValue()})'
            '${failLine == null ? '' : ': $failLine'}');
      }
      await part.rename(outputPath);
    } catch (_) {
      if (part.existsSync()) await part.delete();
      rethrow;
    }
  }
}
