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
/// Re-verified for Xenova's smaller export of the same graphs (1.5.5,
/// en-ROMANCE): identical input/output names, the same degenerate
/// `(0, 8, 1, 64)` cached-branch output, and naive threading there
/// crashes ORT outright instead of drifting.
///
/// Every per-model number (layer count, heads, head width, the decoder
/// start id, EOS, the ids greedy decoding must never pick) comes from
/// the model's own config ([MarianModelConfig]); a multi-target export
/// is steered by prepending its `>>xx<<` token id to the source ids.
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

class MarianGenerationLoop {
  final MarianSessionRunner encoderRunner;
  final MarianSessionRunner decoderRunner;
  final MarianUnigramTokenizer tokenizer;
  final MarianVocabulary vocab;
  final MarianModelConfig config;

  /// The `>>xx<<` token's id for a multi-target export, prepended to
  /// every source sentence; null for a bilingual pair.
  final int? targetTokenId;

  const MarianGenerationLoop({
    required this.encoderRunner,
    required this.decoderRunner,
    required this.tokenizer,
    required this.vocab,
    required this.config,
    this.targetTokenId,
  });

  /// Translates one sentence. Length is capped at 3x the input token
  /// count + 16 (the spec's cap: long enough for a real translation,
  /// short enough that a stuck decode cannot run away).
  Future<String> translate(String sentence) async {
    final pieces = tokenizer.encodeToPieces(sentence);
    final inputIds = [
      ?targetTokenId,
      ...vocab.encodeIds(pieces),
      config.eosTokenId,
    ];
    final encSeqLen = inputIds.length;
    final maxLen = 3 * inputIds.length + 16;
    final layers = config.decoderLayers;

    final encOut = await encoderRunner.run({
      'input_ids': MTensor(inputIds, [1, encSeqLen], MTensorType.int64),
      'attention_mask': MTensor(List.filled(encSeqLen, 1), [
        1,
        encSeqLen,
      ], MTensorType.int64),
    }, fetch: const {});
    final encoderHiddenStates = encOut['last_hidden_state']!;
    final attentionMask = MTensor(List.filled(encSeqLen, 1), [
      1,
      encSeqLen,
    ], MTensorType.int64);

    // Whatever is still held on the runtime's side is freed in
    // `finally`: a decode that throws mid-sentence must not leak.
    var frozenEncoderKv = const <String, MTensor>{};
    var out = const <String, MTensor>{};
    try {
      // Step 1: fresh. See the trap note above for why every
      // past_key_values input — including the cross-attention ones — is
      // a true zero-length dummy here, never omitted and never a guessed
      // non-zero shape.
      final step1Feeds = <String, MTensor>{
        'input_ids': MTensor(
            [config.decoderStartTokenId], [1, 1], MTensorType.int64),
        'encoder_hidden_states': encoderHiddenStates,
        'encoder_attention_mask': attentionMask,
        'use_cache_branch': const MTensor([0], [1], MTensorType.boolean),
      };
      for (var l = 0; l < layers; l++) {
        for (final kind in const ['decoder', 'encoder']) {
          for (final kv in const ['key', 'value']) {
            step1Feeds['past_key_values.$l.$kind.$kv'] = MTensor(const [], [
              1,
              config.decoderHeads,
              0,
              config.headDim,
            ]);
          }
        }
      }
      out = await decoderRunner.run(step1Feeds, fetch: const {'logits'});

      // Freeze the ONLY real cross-attention KV this translation will
      // ever have — see the trap note.
      frozenEncoderKv = <String, MTensor>{
        for (var l = 0; l < layers; l++)
          for (final kv in const ['key', 'value'])
            'past_key_values.$l.encoder.$kv': out['present.$l.encoder.$kv']!,
      };

      final generated = <int>[];
      for (var step = 0; step < maxLen; step++) {
        final nextId = _argmaxLastRow(out['logits']!);
        generated.add(nextId);
        if (nextId == config.eosTokenId || step == maxLen - 1) break;

        final nextFeeds = <String, MTensor>{
          'input_ids': MTensor([nextId], [1, 1], MTensorType.int64),
          'encoder_hidden_states': encoderHiddenStates,
          'encoder_attention_mask': attentionMask,
          'use_cache_branch': const MTensor([1], [1], MTensorType.boolean),
          ...frozenEncoderKv,
        };
        for (var l = 0; l < layers; l++) {
          for (final kv in const ['key', 'value']) {
            nextFeeds['past_key_values.$l.decoder.$kv'] =
                out['present.$l.decoder.$kv']!;
          }
        }
        final next =
            await decoderRunner.run(nextFeeds, fetch: const {'logits'});
        // The previous step's cache was just consumed; the frozen
        // cross-attention values live on until the sentence ends.
        await decoderRunner.release(_unfrozen(out, frozenEncoderKv));
        out = next;
      }
      return vocab.decodeIds(generated);
    } finally {
      await decoderRunner.release(_unfrozen(out, frozenEncoderKv));
      await decoderRunner.release(frozenEncoderKv.values);
      await encoderRunner.release([encoderHiddenStates]);
    }
  }

  /// [out]'s tensors other than the frozen cross-attention values.
  Iterable<MTensor> _unfrozen(
          Map<String, MTensor> out, Map<String, MTensor> frozen) =>
      out.values.where((t) => !frozen.values.any((f) => identical(f, t)));

  int _argmaxLastRow(MTensor logits) {
    final seq = logits.shape[1];
    final vocabSize = logits.shape[2];
    final rowStart = (seq - 1) * vocabSize;
    final banned = config.suppressedTokenIds;
    var bestIdx = -1;
    var bestVal = double.negativeInfinity;
    for (var i = 0; i < vocabSize; i++) {
      if (banned.contains(i)) continue;
      final v = logits.data[rowStart + i].toDouble();
      if (bestIdx < 0 || v > bestVal) {
        bestVal = v;
        bestIdx = i;
      }
    }
    return bestIdx;
  }
}
