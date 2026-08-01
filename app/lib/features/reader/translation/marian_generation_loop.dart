/// The Marian (opus-mt) greedy generation loop — encoder once, then
/// decoder-with-past steps — over the [MarianSessionRunner] boundary, so
/// this file's mechanics can be proven with a deterministic fake and
/// never need a real ONNX session (ADR-0008 "Babel").
///
/// ⚠️ THE trap (onnxruntime issue #17677): a naive single-shot or
/// wrongly-threaded Marian decode produces garbage, not an error — no
/// crash, no reshape assertion, just wrong words. Verified directly
/// against the real onnx-community/opus-mt-en-es graphs (encoder_model_
/// quantized.onnx, decoder_model_merged_quantized.onnx) before writing
/// this file:
///
///  * Step 1 (no cache yet) MUST feed `use_cache_branch=false` and ALL
///    24 `past_key_values.*` inputs (6 layers x {decoder,encoder} x
///    {key,value}) as TRUE zero-length dummies. This is the ONLY call
///    that computes real cross-attention key/value from
///    `encoder_hidden_states`.
///  * Step 2+ MUST feed `use_cache_branch=true`, threading the
///    PREVIOUS step's `present.*.decoder.*` forward as
///    `past_key_values.*.decoder.*` (this part behaves as expected: the
///    self-attention cache genuinely grows by one each step).
///  * The cached branch's OWN `present.*.encoder.*` output is
///    DEGENERATE — observed shape `(0, 8, 1, 64)` (batch 0, empty)
///    against the real graph, every time `use_cache_branch=true`. Naive
///    present->past threading of the cross-attention slot silently
///    corrupts every step from 3 onward (steps 1-2 still look plausible
///    by coincidence — bigram priors carry a short sentence — which is
///    exactly how this trap hides). The fix: FREEZE step 1's real
///    `present.*.encoder.*` and feed those same tensors on every later
///    step, never the current step's own (broken) output for that slot.
///
/// Verified end-to-end in Python against the real graphs before this
/// file was written (see the campaign report for the transcript):
///   "Hello, world!" -> "¡Hola, mundo!"
///   "The quick brown fox jumps over the lazy dog." ->
///     "El zorro marrón salta sobre el perro perezoso."
///   "Good morning. How are you today?" -> "Buenos días. ¿Cómo estás hoy?"
library;

import 'package:ml_runtime/ml_runtime.dart';

import 'marian_types.dart';

const int marianNumLayers = 6;
const int marianNumHeads = 8;
const int marianHeadDim = 64;

class MarianGenerationLoop {
  final MarianSessionRunner encoderRunner;
  final MarianSessionRunner decoderRunner;
  final MarianUnigramTokenizer tokenizer;
  final MarianVocabulary vocab;

  const MarianGenerationLoop({
    required this.encoderRunner,
    required this.decoderRunner,
    required this.tokenizer,
    required this.vocab,
  });

  /// Translates one sentence. Length is capped at 3x the input token
  /// count + 16 (the spec's cap: long enough for a real translation,
  /// short enough that a stuck decode cannot run away).
  Future<String> translate(String sentence) async {
    final pieces = tokenizer.encodeToPieces(sentence);
    final inputIds = [...vocab.encodeIds(pieces), vocab.eosId];
    final encSeqLen = inputIds.length;
    final maxLen = 3 * inputIds.length + 16;

    final encOut = await encoderRunner.run({
      'input_ids': MTensor(inputIds, [1, encSeqLen], MTensorType.int64),
      'attention_mask': MTensor(List.filled(encSeqLen, 1), [
        1,
        encSeqLen,
      ], MTensorType.int64),
    });
    final encoderHiddenStates = encOut['last_hidden_state']!;
    final attentionMask = MTensor(List.filled(encSeqLen, 1), [
      1,
      encSeqLen,
    ], MTensorType.int64);

    // Step 1: fresh. See the trap note above for why every past_key_values
    // input — including the cross-attention ones — is a true zero-length
    // dummy here, never omitted and never a guessed non-zero shape.
    final step1Feeds = <String, MTensor>{
      'input_ids': MTensor([vocab.padId], [1, 1], MTensorType.int64),
      'encoder_hidden_states': encoderHiddenStates,
      'encoder_attention_mask': attentionMask,
      'use_cache_branch': const MTensor([0], [1], MTensorType.boolean),
    };
    for (var l = 0; l < marianNumLayers; l++) {
      for (final kind in const ['decoder', 'encoder']) {
        for (final kv in const ['key', 'value']) {
          step1Feeds['past_key_values.$l.$kind.$kv'] = const MTensor([], [
            1,
            marianNumHeads,
            0,
            marianHeadDim,
          ]);
        }
      }
    }
    var out = await decoderRunner.run(step1Feeds);

    // Freeze the ONLY real cross-attention KV this translation will ever
    // have — see the trap note.
    final frozenEncoderKv = <String, MTensor>{
      for (var l = 0; l < marianNumLayers; l++)
        for (final kv in const ['key', 'value'])
          'past_key_values.$l.encoder.$kv': out['present.$l.encoder.$kv']!,
    };

    final generated = <int>[];
    for (var step = 0; step < maxLen; step++) {
      final nextId = _argmaxLastRow(out['logits']!);
      generated.add(nextId);
      if (nextId == vocab.eosId) break;
      if (step == maxLen - 1) break; // length cap reached, no next call

      final nextFeeds = <String, MTensor>{
        'input_ids': MTensor([nextId], [1, 1], MTensorType.int64),
        'encoder_hidden_states': encoderHiddenStates,
        'encoder_attention_mask': attentionMask,
        'use_cache_branch': const MTensor([1], [1], MTensorType.boolean),
        ...frozenEncoderKv,
      };
      for (var l = 0; l < marianNumLayers; l++) {
        for (final kv in const ['key', 'value']) {
          nextFeeds['past_key_values.$l.decoder.$kv'] =
              out['present.$l.decoder.$kv']!;
        }
      }
      out = await decoderRunner.run(nextFeeds);
    }
    return vocab.decodeIds(generated);
  }

  int _argmaxLastRow(MTensor logits) {
    final seq = logits.shape[1];
    final vocabSize = logits.shape[2];
    final rowStart = (seq - 1) * vocabSize;
    var bestIdx = 0;
    var bestVal = logits.data[rowStart].toDouble();
    for (var i = 1; i < vocabSize; i++) {
      final v = logits.data[rowStart + i].toDouble();
      if (v > bestVal) {
        bestVal = v;
        bestIdx = i;
      }
    }
    return bestIdx;
  }
}
