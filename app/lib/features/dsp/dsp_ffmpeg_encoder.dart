/// The real DSP encoder (Campaign 6, ADR-0012): FFprobeKit for duration,
/// FFmpegKit for the filtered re-encode — both on the same audio-variant
/// ffmpeg_kit fork the decoder already pins. Android/iOS only; nothing
/// here is reachable in a test (mirrors `FfmpegDecoder`'s own status —
/// see `dsp_encoder.dart`'s doc comment for why that's an honest gap,
/// not an oversight).
library;

import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';

import 'dsp_encoder.dart';
import 'dsp_params.dart';

class FfmpegDspEncoder implements DspEncoder {
  @override
  Future<int> durationMs(String path) async {
    final session = await FFprobeKit.getMediaInformation(path);
    final info = session.getMediaInformation();
    final seconds = info?.getDuration();
    final parsed = seconds == null ? null : double.tryParse(seconds);
    if (parsed == null) {
      throw DspEncodeException('ffprobe could not read a duration for $path');
    }
    return (parsed * 1000).round();
  }

  @override
  Future<void> process({
    required String inputPath,
    required String outputPath,
    required String codec,
    String? bitrate,
  }) async {
    final out = File(outputPath);
    await out.parent.create(recursive: true);
    if (out.existsSync()) await out.delete();
    final bitrateArg = bitrate == null ? '' : ' -b:a $bitrate';
    final session = await FFmpegKit.execute(
      '-y -i "$inputPath" -af "${dspFilterGraph()}" -c:a $codec'
      '$bitrateArg "$outputPath"',
    );
    final rc = await session.getReturnCode();
    if (!ReturnCode.isSuccess(rc)) {
      final failLine = await session.getFailStackTrace();
      if (out.existsSync()) await out.delete();
      throw DspEncodeException(
        'ffmpeg DSP pass failed on $inputPath (code ${rc?.getValue()})'
        '${failLine == null ? '' : ': $failLine'}',
      );
    }
  }
}
