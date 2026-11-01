/// Kokoro-82M v1.1-zh over `flutter_onnxruntime`: one session, three
/// inputs (`input_ids` int64 [1,T], `style` float32 [1,256], `speed`
/// float32 [1]) and the `waveform` output at 24 kHz. Never imported
/// directly; always through `kokoro_model.dart`.
library;

import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../kokoro_engine.dart';

export '../kokoro_front_end.dart' show loadKokoroFrontEnd;

Future<KokoroModel> openKokoroModel(String modelPath) async =>
    _OrtKokoroModel(await OnnxRuntime().createSession(modelPath));

class _OrtKokoroModel implements KokoroModel {
  final OrtSession session;
  _OrtKokoroModel(this.session);

  @override
  Future<Float32List> run(
      List<int> inputIds, Float32List style, double speed) async {
    // An explicit Int64List: a plain List<int> goes over as int32.
    final ids =
        await OrtValue.fromList(Int64List.fromList(inputIds), [1, inputIds.length]);
    final styleValue = await OrtValue.fromList(style, [1, style.length]);
    final speedValue =
        await OrtValue.fromList(Float32List.fromList([speed]), [1]);
    try {
      final out = await session.run(
          {'input_ids': ids, 'style': styleValue, 'speed': speedValue});
      try {
        final wave = out['waveform'] ?? out.values.first;
        final flat = await wave.asFlattenedList();
        return Float32List.fromList(
            [for (final v in flat) (v as num).toDouble()]);
      } finally {
        for (final v in out.values) {
          await v.dispose();
        }
      }
    } finally {
      await ids.dispose();
      await styleValue.dispose();
      await speedValue.dispose();
    }
  }

  @override
  Future<void> dispose() => session.close();
}
