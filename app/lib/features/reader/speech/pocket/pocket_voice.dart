/// A Pocket TTS voice as Kyutai ships it: the flow model's KV cache after
/// hearing the voice's prompt, one per transformer layer, in a
/// safetensors file (`transformer.layers.<i>.self_attn/cache`, shape
/// [2,1,L,heads,dim], filled up to `.../offset`). It starts every chunk's
/// cache, so the model speaks in that voice. Nothing here clones a voice:
/// Trellis only reads the ready states Kyutai published.
library;

import 'dart:typed_data';

import 'package:ml_runtime/ml_runtime.dart' show SafeTensors;

import '../../translation/marian_types.dart';
import 'pocket_loop.dart';

PocketVoice loadPocketVoice(Uint8List bytes, {int layers = 6}) {
  final st = SafeTensors.parse(bytes);
  final caches = <MTensor>[];
  for (var i = 0; i < layers; i++) {
    final prefix = 'transformer.layers.$i.self_attn/';
    final cache = st['${prefix}cache'];
    if (cache == null || cache.shape.length != 5) {
      throw FormatException('The voice file has no cache for layer $i.');
    }
    final length = cache.shape[2];
    final offset = st['${prefix}offset']?.asInt64().first ?? length;
    if (offset < 0 || offset > length) {
      throw FormatException('The voice file’s layer $i is malformed.');
    }
    final per = cache.shape[3] * cache.shape[4];
    final all = cache.asFloat32();
    final cut = Float32List(2 * offset * per);
    for (var kv = 0; kv < 2; kv++) {
      cut.setRange(kv * offset * per, (kv + 1) * offset * per,
          all, kv * length * per);
    }
    caches.add(MTensor(
        cut, [2, 1, offset, cache.shape[3], cache.shape[4]]));
  }
  return PocketVoice(caches);
}
