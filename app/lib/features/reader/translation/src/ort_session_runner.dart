/// An ONNX Runtime session behind [MarianSessionRunner]: plain tensors
/// uploaded for one call and freed after it, outputs not fetched left on
/// the runtime's side as handles. Native only: imported by files behind
/// the conditional exports, never by the web build.
library;

import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../marian_types.dart';

// ---------------------------------------------------------------------
// The MTensor <-> OrtValue adapter — shared by every engine whose loop
// runs over MarianSessionRunner (the translator, Pocket TTS).
// ---------------------------------------------------------------------

Future<OrtValue> _toOrtValue(MTensor t) {
  switch (t.type) {
    case MTensorType.int64:
      return OrtValue.fromList(
        Int64List.fromList(t.data.map((e) => e.toInt()).toList()),
        t.shape,
      );
    case MTensorType.float32:
      return OrtValue.fromList(
        Float32List.fromList(t.data.map((e) => e.toDouble()).toList()),
        t.shape,
      );
    case MTensorType.boolean:
      return OrtValue.fromList(
        t.data.map((e) => e != 0).toList(growable: false),
        t.shape,
      );
  }
}

MTensorType _fromOrtDataType(OrtDataType dt) => switch (dt) {
  OrtDataType.int64 || OrtDataType.int32 => MTensorType.int64,
  OrtDataType.bool => MTensorType.boolean,
  _ => MTensorType.float32,
};

Future<MTensor> _fromOrtValue(OrtValue v) async {
  final flat = await v.asFlattenedList();
  final data = flat
      .map((e) => e is bool ? (e ? 1 : 0) : (e as num))
      .toList(growable: false);
  return MTensor(data, v.shape, _fromOrtDataType(v.dataType));
}

class OrtSessionRunner implements MarianSessionRunner {
  final OrtSession session;
  OrtSessionRunner(this.session);

  @override
  Future<Map<String, MTensor>> run(Map<String, MTensor> feeds,
      {Set<String>? fetch}) async {
    // Handles go back in as they are; only plain data is uploaded, and
    // only what this call uploaded is freed after it.
    final uploaded = <OrtValue>[];
    final ortFeeds = <String, OrtValue>{};
    for (final e in feeds.entries) {
      final handle = e.value.handle;
      if (handle is OrtValue) {
        ortFeeds[e.key] = handle;
      } else {
        final v = await _toOrtValue(e.value);
        uploaded.add(v);
        ortFeeds[e.key] = v;
      }
    }
    final Map<String, OrtValue> ortResult;
    try {
      ortResult = await session.run(ortFeeds);
    } finally {
      for (final v in uploaded) {
        await v.dispose();
      }
    }
    final result = <String, MTensor>{};
    for (final e in ortResult.entries) {
      if (fetch == null || fetch.contains(e.key)) {
        result[e.key] = await _fromOrtValue(e.value);
        await e.value.dispose();
      } else {
        result[e.key] = MTensor.handle(
            e.value, e.value.shape, _fromOrtDataType(e.value.dataType));
      }
    }
    return result;
  }

  @override
  Future<void> release(Iterable<MTensor> tensors) async {
    for (final t in tensors.toList()) {
      final handle = t.handle;
      if (handle is OrtValue) await handle.dispose();
    }
  }
}

