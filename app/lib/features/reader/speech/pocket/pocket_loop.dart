/// The Pocket TTS generation loop over four ONNX graphs, ported from the
/// reference loop that was checked against Kyutai's PyTorch (pocket-tts
/// 4.0.1, MIT; every rule cites tts_model.py / flow_lm.py there). The
/// graphs are Trellis's own export of Kyutai's ungated weights
/// (docs/reference/tts-voices.md has the contract):
///
///  * `text_conditioner`: token ids into text embeddings, plus the two
///    constant vectors that carry a latent into the decoder's space;
///  * `flow_lm_main`: one transformer step over a KV cache, giving the
///    conditioning for the next frame and the end-of-speech logit;
///  * `flow_lm_flow`: the flow net, run [steps] times per frame to turn
///    noise into the frame's latent (Lagrangian self-distillation);
///  * `mimi_decoder`: latents into 24 kHz audio, 1,920 samples a frame,
///    with its streaming state.
///
/// Per chunk of text: the voice's KV caches (a ready voice state from
/// Kyutai) are the starting cache; the text is prefilled; then a frame
/// at a time until the end-of-speech rule stops it. Caches and the
/// decoder state stay on the runtime's side as handles; only the small
/// vectors the loop needs (the logit, the flow's output) reach Dart.
///
/// The graphs sit behind [MarianSessionRunner], the same thin boundary
/// the translator uses, so a host test drives the loop with fakes and a
/// desktop test with real ONNX Runtime.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ml_runtime/ml_runtime.dart' show UnigramTokenizer;

import '../../translation/marian_types.dart';
import 'pocket_chunks.dart';
import 'pocket_text.dart';

const pocketSampleRate = 24000;
const pocketSamplesPerFrame = 1920;
const pocketLatentDim = 32;
const _eosThreshold = -4.0; // default_parameters.py DEFAULT_EOS_THRESHOLD
const _minFramesBeforeEos = 6; // tts_model.py _MIN_FRAMES_BEFORE_EOS
const _tokensPerSecond = 3.0; // tts_model.py
const _genSecondsPadding = 2.0; // tts_model.py
const _frameRate = 12.5;
const _mimiChunkFrames = 12;
const _fadeInSamples = pocketSampleRate ~/ 200; // 5 ms, tts_model.py

/// Kyutai's frame cap for [tokens] tokens: the text's length at three
/// tokens a second, plus two seconds.
int pocketMaxFrames(int tokens) =>
    ((tokens / _tokensPerSecond + _genSecondsPadding) * _frameRate).ceil();

/// The Mimi decoder's streaming state, all zeros at the start of each
/// chunk (shapes from the export's io.json). The last is the offset.
const pocketMimiStateShapes = <List<int>>[
  [1, 512, 16],
  [2, 1, 250, 8, 64],
  [2, 1, 250, 8, 64],
  [1, 512, 6],
  [1, 256, 6],
  [1, 256, 2],
  [1, 128, 5],
  [1, 128, 2],
  [1, 64, 4],
  [1, 64, 2],
  [1, 64, 2],
  [1],
];

/// A voice: the first cache for each transformer layer, `[2,1,L,16,64]`
/// float32, from Kyutai's voice-state file cut to its offset.
class PocketVoice {
  final List<MTensor> caches;
  const PocketVoice(this.caches);
}

/// A standard-normal vector of [pocketLatentDim] for frame [frame] of
/// chunk [chunk]; tests pass a fixed one, the app a seeded generator.
typedef PocketNoise = Float32List Function(int chunk, int frame);

PocketNoise gaussianNoise(math.Random random) => (_, _) {
      final z = Float32List(pocketLatentDim);
      for (var i = 0; i < z.length; i++) {
        final u1 = math.max(1e-12, random.nextDouble());
        final u2 = random.nextDouble();
        z[i] = math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
      }
      return z;
    };

class PocketGenerator {
  final MarianSessionRunner conditioner;
  final MarianSessionRunner main;
  final MarianSessionRunner flow;
  final MarianSessionRunner mimi;
  final UnigramTokenizer tokenizer;
  final PocketLanguage language;
  final PocketNoise noise;

  Float32List? _mean;
  Float32List? _std;

  PocketGenerator({
    required this.conditioner,
    required this.main,
    required this.flow,
    required this.mimi,
    required this.tokenizer,
    required this.language,
    required this.noise,
  });

  /// Says [text] in [voice]: 24 kHz audio. [temperature] scales the
  /// noise (Kyutai's 0.3); [steps] is the flow net's steps per frame.
  Future<Float32List> synthesize(String text, PocketVoice voice,
      {double temperature = 0.3, int steps = 1}) async {
    final out = <Float32List>[];
    final chunks = splitPocketChunks(tokenizer, text, language);
    for (var c = 0; c < chunks.length; c++) {
      final prompt = preparePocketText(chunks[c], language);
      final latents = await _latents(prompt.text, prompt.framesAfterEos + 2,
          voice, (frame) => noise(c, frame), temperature, steps);
      out.add(await _decode(latents));
    }
    final all = Float32List(out.fold(0, (n, a) => n + a.length));
    var at = 0;
    for (final a in out) {
      all.setAll(at, a);
      at += a.length;
    }
    return all;
  }

  Future<List<Float32List>> _latents(
      String text,
      int framesAfterEos,
      PocketVoice voice,
      Float32List Function(int frame) z,
      double temperature,
      int steps) async {
    final ids = tokenizer.encode(text);
    final maxFrames = pocketMaxFrames(ids.length);
    final cond = await conditioner.run({
      'token_ids': MTensor(ids, [1, ids.length], MTensorType.int64),
    }, fetch: _mean == null ? {'latent_mean', 'latent_std'} : const {});
    _mean ??= _floats(cond['latent_mean']!);
    _std ??= _floats(cond['latent_std']!);
    final embeddings = cond['embeddings']!;
    await conditioner.release(
        cond.entries.where((e) => e.key != 'embeddings').map((e) => e.value));

    // Text prefill (tts_model.py): the voice caches, then the text.
    var caches = voice.caches;
    var owned = false; // the voice's caches are not ours to release
    Future<void> step(MTensor sequence, MTensor text,
        void Function(Map<String, MTensor>) use) async {
      final r = await main.run({
        'sequence': sequence,
        'text_embeddings': text,
        for (var i = 0; i < caches.length; i++) 'cache_$i': caches[i],
      }, fetch: const {'eos_logit'});
      if (owned) await main.release(caches);
      caches = [for (var i = 0; i < caches.length; i++) r['new_cache_$i']!];
      owned = true;
      use(r);
      await main.release(
          r.entries.where((e) => e.key.startsWith('new_cache_') == false &&
              e.key != 'conditioning').map((e) => e.value));
    }

    final emptySequence =
        MTensor(const <double>[], const [1, 0, pocketLatentDim]);
    MTensor? prefillConditioning;
    await step(emptySequence, embeddings,
        (r) => prefillConditioning = r['conditioning']);
    await main.release([?prefillConditioning]);
    await conditioner.release([embeddings]);

    final emptyText = MTensor(const <double>[], const [1, 0, 1024]);
    var sequence = MTensor(
        List<double>.filled(pocketLatentDim, double.nan),
        const [1, 1, pocketLatentDim]); // BOS
    final latents = <Float32List>[];
    int? eosAt;
    final scale = math.sqrt(temperature);
    try {
      for (var frame = 0; frame < maxFrames; frame++) {
        late MTensor conditioning;
        late double eos;
        await step(sequence, emptyText, (r) {
          conditioning = r['conditioning']!;
          eos = r['eos_logit']!.data.first.toDouble();
        });
        try {
          if (eosAt == null && eos > _eosThreshold &&
              frame >= _minFramesBeforeEos) {
            eosAt = frame;
          }
          if (eosAt != null && frame >= eosAt + framesAfterEos) break;
          final noise = z(frame);
          final x = Float32List(pocketLatentDim);
          for (var i = 0; i < x.length; i++) {
            x[i] = noise[i] * scale;
          }
          for (var i = 0; i < steps; i++) {
            final d = await flow.run({
              'c': conditioning,
              's': MTensor([i / steps], const [1, 1]),
              't': MTensor([(i + 1) / steps], const [1, 1]),
              'x': MTensor(x, const [1, pocketLatentDim]),
            }, fetch: const {'flow_dir'});
            final dir = d['flow_dir']!.data;
            for (var k = 0; k < x.length; k++) {
              x[k] += dir[k].toDouble() / steps;
            }
          }
          latents.add(x);
          sequence = MTensor(x, const [1, 1, pocketLatentDim]);
        } finally {
          await main.release([conditioning]);
        }
      }
    } finally {
      if (owned) await main.release(caches);
    }
    return latents;
  }

  /// Mimi decoding: fresh state per chunk, 12 frames a call, each latent
  /// carried into the decoder's space, the first 5 ms faded in.
  Future<Float32List> _decode(List<Float32List> latents) async {
    if (latents.isEmpty) return Float32List(0);
    final mean = _mean!, std = _std!;
    var state = <MTensor>[
      for (final shape in pocketMimiStateShapes)
        shape.length == 1
            ? MTensor(const [0], shape, MTensorType.int64)
            : MTensor(
                Float32List(shape.fold(1, (a, b) => a * b)), shape),
    ];
    var owned = false;
    final audio = <double>[];
    try {
      for (var i = 0; i < latents.length; i += _mimiChunkFrames) {
        final block = latents.sublist(
            i, math.min(i + _mimiChunkFrames, latents.length));
        final data = Float32List(block.length * pocketLatentDim);
        for (var f = 0; f < block.length; f++) {
          for (var k = 0; k < pocketLatentDim; k++) {
            data[f * pocketLatentDim + k] = block[f][k] * std[k] + mean[k];
          }
        }
        final r = await mimi.run({
          'latent': MTensor(data, [1, block.length, pocketLatentDim]),
          for (var k = 0; k < state.length; k++) 'state_$k': state[k],
        }, fetch: const {'audio'});
        if (owned) await mimi.release(state);
        state = [for (var k = 0; k < state.length; k++) r['new_state_$k']!];
        owned = true;
        audio.addAll(r['audio']!.data.map((v) => v.toDouble()));
      }
    } finally {
      if (owned) await mimi.release(state);
    }
    final out = Float32List.fromList(audio);
    final n = math.min(_fadeInSamples, out.length);
    for (var i = 0; i < n; i++) {
      out[i] *= i / (_fadeInSamples - 1);
    }
    return out;
  }

  static Float32List _floats(MTensor t) =>
      Float32List.fromList([for (final v in t.data) v.toDouble()]);
}
