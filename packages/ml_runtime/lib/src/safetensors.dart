/// A reader for `.safetensors` files: an 8-byte little-endian header
/// length, a JSON header naming each tensor's dtype, shape and byte
/// range, then the raw bytes (huggingface/safetensors, Apache-2.0
/// format). Trellis reads Kyutai's Pocket TTS voice states with it.
/// Pure Dart: no dependency, no file access; the caller hands it bytes.
library;

import 'dart:convert';
import 'dart:typed_data';

enum SafeTensorType {
  f32(4),
  f16(2),
  bf16(2),
  i64(8),
  i32(4),
  boolean(1);

  const SafeTensorType(this.width);
  final int width;

  static SafeTensorType? parse(String s) => switch (s) {
        'F32' => f32,
        'F16' => f16,
        'BF16' => bf16,
        'I64' => i64,
        'I32' => i32,
        'BOOL' => boolean,
        _ => null,
      };
}

class SafeTensor {
  final SafeTensorType dtype;
  final List<int> shape;
  final Uint8List _bytes;

  SafeTensor._(this.dtype, this.shape, this._bytes);

  int get length => shape.fold(1, (a, b) => a * b);

  ByteData get _data =>
      ByteData.view(_bytes.buffer, _bytes.offsetInBytes, _bytes.length);

  /// The values as float32; half and bfloat16 widen exactly.
  Float32List asFloat32() {
    final d = _data;
    final out = Float32List(length);
    for (var i = 0; i < length; i++) {
      out[i] = switch (dtype) {
        SafeTensorType.f32 => d.getFloat32(i * 4, Endian.little),
        SafeTensorType.f16 => _half(d.getUint16(i * 2, Endian.little)),
        SafeTensorType.bf16 => _bf16(d.getUint16(i * 2, Endian.little)),
        SafeTensorType.i64 => d.getInt64(i * 8, Endian.little).toDouble(),
        SafeTensorType.i32 => d.getInt32(i * 4, Endian.little).toDouble(),
        SafeTensorType.boolean => d.getUint8(i).toDouble(),
      };
    }
    return out;
  }

  /// The values as int64. Only integer and bool tensors.
  Int64List asInt64() {
    final d = _data;
    final out = Int64List(length);
    for (var i = 0; i < length; i++) {
      out[i] = switch (dtype) {
        SafeTensorType.i64 => d.getInt64(i * 8, Endian.little),
        SafeTensorType.i32 => d.getInt32(i * 4, Endian.little),
        SafeTensorType.boolean => d.getUint8(i),
        _ => throw StateError('a $dtype tensor is not an integer tensor'),
      };
    }
    return out;
  }

  static double _bf16(int bits) =>
      (ByteData(4)..setUint32(0, bits << 16)).getFloat32(0);

  static double _half(int h) {
    final sign = (h >> 15) & 1;
    final exp = (h >> 10) & 0x1f;
    final frac = h & 0x3ff;
    int bits;
    if (exp == 0) {
      if (frac == 0) {
        bits = sign << 31;
      } else {
        // Subnormal: normalise into float32's range.
        var e = -1;
        var f = frac;
        do {
          e++;
          f <<= 1;
        } while (f & 0x400 == 0);
        bits = (sign << 31) | ((127 - 15 - e) << 23) | ((f & 0x3ff) << 13);
      }
    } else if (exp == 0x1f) {
      bits = (sign << 31) | 0x7f800000 | (frac << 13);
    } else {
      bits = (sign << 31) | ((exp - 15 + 127) << 23) | (frac << 13);
    }
    return (ByteData(4)..setUint32(0, bits)).getFloat32(0);
  }
}

class SafeTensors {
  final Map<String, SafeTensor> _tensors;
  final Map<String, String> metadata;

  SafeTensors._(this._tensors, this.metadata);

  /// Tensor names in the header's order.
  List<String> get names => _tensors.keys.toList();

  SafeTensor? operator [](String name) => _tensors[name];

  /// Parses a whole file's bytes. Throws [FormatException] for anything
  /// that is not a well-formed file.
  static SafeTensors parse(Uint8List bytes) {
    if (bytes.length < 8) {
      throw const FormatException('Not a safetensors file: too short.');
    }
    final view = ByteData.view(bytes.buffer, bytes.offsetInBytes, 8);
    final headerLen = view.getUint64(0, Endian.little);
    if (headerLen > bytes.length - 8) {
      throw const FormatException('Not a safetensors file: bad header.');
    }
    final Object? header;
    try {
      header = jsonDecode(utf8.decode(
          Uint8List.sublistView(bytes, 8, 8 + headerLen)));
    } on FormatException {
      throw const FormatException('Not a safetensors file: bad header.');
    }
    if (header is! Map<String, dynamic>) {
      throw const FormatException('Not a safetensors file: bad header.');
    }
    final dataStart = 8 + headerLen;
    final tensors = <String, SafeTensor>{};
    var metadata = const <String, String>{};
    for (final e in header.entries) {
      if (e.key == '__metadata__') {
        final m = e.value;
        if (m is Map) {
          metadata = {for (final k in m.keys) '$k': '${m[k]}'};
        }
        continue;
      }
      final v = e.value;
      if (v is! Map) throw FormatException('Tensor “${e.key}” is malformed.');
      final dtype = SafeTensorType.parse('${v['dtype']}');
      final shape = (v['shape'] as List?)?.cast<int>();
      final offsets = (v['data_offsets'] as List?)?.cast<int>();
      if (dtype == null || shape == null || offsets?.length != 2) {
        throw FormatException('Tensor “${e.key}” is malformed.');
      }
      final begin = dataStart + offsets![0];
      final end = dataStart + offsets[1];
      final count = shape.fold(1, (a, b) => a * b);
      if (begin > end ||
          end > bytes.length ||
          end - begin != count * dtype.width) {
        throw FormatException('Tensor “${e.key}” is outside the file.');
      }
      tensors[e.key] =
          SafeTensor._(dtype, shape, Uint8List.sublistView(bytes, begin, end));
    }
    return SafeTensors._(tensors, metadata);
  }
}
