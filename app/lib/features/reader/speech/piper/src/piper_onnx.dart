/// Piper's ru_RU denis (medium) over `flutter_onnxruntime`: one session,
/// three inputs (`input` int64 [1,N], `input_lengths` int64 [1], `scales`
/// float32 [3]) and the `output` float32 [1,1,1,samples] at 22,050 Hz,
/// as read from the .onnx file itself. Never imported directly; always
/// through `piper_model.dart`.
library;

import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../piper_engine.dart';

export '../piper_front_end.dart' show loadPiperFrontEnd;

Future<PiperModel> openPiperModel(String modelPath) async =>
    _OrtPiperModel(await OnnxRuntime().createSession(modelPath));

class _OrtPiperModel implements PiperModel {
  final OrtSession session;
  _OrtPiperModel(this.session);

  @override
  Future<Float32List> run(List<int> ids, Float32List scales) async {
    // Explicit Int64Lists: a plain List<int> goes over as int32.
    final input = await OrtValue.fromList(Int64List.fromList(ids), [
      1,
      ids.length,
    ]);
    final lengths = await OrtValue.fromList(Int64List.fromList([ids.length]), [
      1,
    ]);
    final scalesValue = await OrtValue.fromList(scales, [3]);
    try {
      final out = await session.run({
        'input': input,
        'input_lengths': lengths,
        'scales': scalesValue,
      });
      try {
        final wave = out['output'] ?? out.values.first;
        final flat = await wave.asFlattenedList();
        return Float32List.fromList([
          for (final v in flat) (v as num).toDouble(),
        ]);
      } finally {
        for (final v in out.values) {
          await v.dispose();
        }
      }
    } finally {
      await input.dispose();
      await lengths.dispose();
      await scalesValue.dispose();
    }
  }

  @override
  Future<void> dispose() => session.close();
}
