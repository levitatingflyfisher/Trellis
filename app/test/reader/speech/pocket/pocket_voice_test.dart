import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/reader/speech/pocket/pocket_voice.dart';

/// A Kyutai voice state: per layer, a KV cache [2,1,L,heads,dim] and the
/// offset up to which it is filled.
Uint8List voiceFile(
    {required int layers, required int length, required int offset}) {
  const heads = 2, dim = 2;
  final header = <String, Object>{};
  final data = BytesBuilder();
  var at = 0;
  for (var i = 0; i < layers; i++) {
    final n = 2 * length * heads * dim;
    final cache = Float32List(n);
    for (var k = 0; k < n; k++) {
      cache[k] = i * 1000 + k.toDouble();
    }
    header['transformer.layers.$i.self_attn/cache'] = {
      'dtype': 'F32',
      'shape': [2, 1, length, heads, dim],
      'data_offsets': [at, at + n * 4],
    };
    data.add(cache.buffer.asUint8List());
    at += n * 4;
    header['transformer.layers.$i.self_attn/offset'] = {
      'dtype': 'I64',
      'shape': [1],
      'data_offsets': [at, at + 8],
    };
    data.add(Int64List.fromList([offset]).buffer.asUint8List());
    at += 8;
  }
  final h = utf8.encode(jsonEncode(header));
  return (BytesBuilder()
        ..add((ByteData(8)..setUint64(0, h.length, Endian.little))
            .buffer
            .asUint8List())
        ..add(h)
        ..add(data.toBytes()))
      .toBytes();
}

void main() {
  test('each layer’s cache, cut to its offset along the positions', () {
    final v = loadPocketVoice(voiceFile(layers: 2, length: 3, offset: 2),
        layers: 2);
    expect(v.caches, hasLength(2));
    final c1 = v.caches[1];
    expect(c1.shape, [2, 1, 2, 2, 2]);
    // K keeps positions 0..1 (values 1000..1007), V likewise from 1012.
    expect(c1.data, [
      for (var k = 0; k < 8; k++) 1000.0 + k,
      for (var k = 12; k < 20; k++) 1000.0 + k,
    ]);
  });

  test('a file without enough layers is refused in a sentence', () {
    expect(
        () => loadPocketVoice(voiceFile(layers: 1, length: 3, offset: 3),
            layers: 6),
        throwsA(isA<FormatException>()));
  });
}
