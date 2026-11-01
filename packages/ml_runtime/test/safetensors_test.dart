import 'dart:convert';
import 'dart:typed_data';

import 'package:ml_runtime/ml_runtime.dart';
import 'package:test/test.dart';

/// A `.safetensors` file (Kyutai's Pocket TTS voice states): an 8-byte
/// little-endian header length, a JSON header naming each tensor's dtype,
/// shape and byte range, then the raw bytes.
Uint8List build(Map<String, Object> header, List<int> data) {
  final h = utf8.encode(jsonEncode(header));
  final out = BytesBuilder();
  final len = ByteData(8)..setUint64(0, h.length, Endian.little);
  out.add(len.buffer.asUint8List());
  out.add(h);
  out.add(data);
  return out.toBytes();
}

List<int> f32(List<double> v) =>
    Float32List.fromList(v).buffer.asUint8List().toList();
List<int> i64(List<int> v) =>
    Int64List.fromList(v).buffer.asUint8List().toList();

void main() {
  test('reads each tensor by name with its dtype, shape and values', () {
    final bytes = build({
      '__metadata__': {'format': 'pt'},
      'layer.0.cache': {
        'dtype': 'F32',
        'shape': [2, 1, 2],
        'data_offsets': [0, 16],
      },
      'layer.0.offset': {
        'dtype': 'I64',
        'shape': [1],
        'data_offsets': [16, 24],
      },
    }, [...f32([1, 2, 3, 4]), ...i64([124])]);
    final st = SafeTensors.parse(bytes);
    expect(st.names, ['layer.0.cache', 'layer.0.offset']);
    expect(st.metadata, {'format': 'pt'});
    final cache = st['layer.0.cache']!;
    expect(cache.dtype, SafeTensorType.f32);
    expect(cache.shape, [2, 1, 2]);
    expect(cache.asFloat32(), [1, 2, 3, 4]);
    expect(st['layer.0.offset']!.asInt64(), [124]);
    expect(st['missing'], isNull);
  });

  test('half and bfloat16 widen to float32', () {
    // 1.0 is 0x3C00 in half and 0x3F80 in bfloat16; -2.0 is 0xC000 / 0xC000.
    final bytes = build({
      'h': {'dtype': 'F16', 'shape': [2], 'data_offsets': [0, 4]},
      'b': {'dtype': 'BF16', 'shape': [2], 'data_offsets': [4, 8]},
    }, [0x00, 0x3C, 0x00, 0xC0, 0x80, 0x3F, 0x00, 0xC0]);
    final st = SafeTensors.parse(bytes);
    expect(st['h']!.asFloat32(), [1.0, -2.0]);
    expect(st['b']!.asFloat32(), [1.0, -2.0]);
  });

  test('bool and int32 read as int64', () {
    final bytes = build({
      'm': {'dtype': 'BOOL', 'shape': [3], 'data_offsets': [0, 3]},
      'n': {'dtype': 'I32', 'shape': [1], 'data_offsets': [3, 7]},
    }, [1, 0, 1, 7, 0, 0, 0]);
    final st = SafeTensors.parse(bytes);
    expect(st['m']!.asInt64(), [1, 0, 1]);
    expect(st['n']!.asInt64(), [7]);
  });

  test('a broken file is refused in a sentence, never a crash', () {
    expect(() => SafeTensors.parse(Uint8List(4)),
        throwsA(isA<FormatException>()));
    final tooLong = ByteData(8)..setUint64(0, 1000, Endian.little);
    expect(() => SafeTensors.parse(tooLong.buffer.asUint8List()),
        throwsA(isA<FormatException>()));
    final badRange = build({
      'x': {'dtype': 'F32', 'shape': [4], 'data_offsets': [0, 16]},
    }, f32([1]));
    expect(() => SafeTensors.parse(badRange), throwsA(isA<FormatException>()));
    final badShape = build({
      'x': {'dtype': 'F32', 'shape': [3], 'data_offsets': [0, 8]},
    }, f32([1, 2]));
    expect(() => SafeTensors.parse(badShape), throwsA(isA<FormatException>()));
  });
}
