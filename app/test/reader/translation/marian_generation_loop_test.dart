import 'package:flutter_test/flutter_test.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:trellis/features/reader/translation/marian_engine.dart';

/// A deterministic fake decoder session — never touches ONNX Runtime.
/// [scriptedIds] is the sequence of token ids to emit, one per call (the
/// fake ignores everything about the feeds except `use_cache_branch` and
/// the threaded past KV, which it records for assertions).
/// The shipped pairs' shape: 6 layers, 8 heads of 64.
const _cfg = MarianModelConfig(
  decoderLayers: 6,
  decoderHeads: 8,
  headDim: 64,
  decoderStartTokenId: 6,
  eosTokenId: 0,
  padTokenId: 6,
  suppressedTokenIds: {6},
);

class _FakeDecoderRunner implements MarianSessionRunner {
  final List<int> scriptedIds;
  final MarianModelConfig cfg;
  static const _vocabSize = 8;

  /// Logits the fake emits beyond the scripted id's 10.0 (a banned id
  /// scoring higher, to prove the mask).
  final Map<int, double> extraLogits;

  /// When true, every non-fetched output comes back as a handle, the way
  /// the real runner leaves KV on the runtime's side.
  final bool handles;
  final List<Object> issuedHandles = [];
  final List<Object> releasedHandles = [];

  /// The marker value real (step-1-computed) cross-attention KV carries
  /// in this fake, vs. the DEGENERATE marker a cached-branch call
  /// returns for that same slot — mirroring the real graph's observed
  /// bug (present.*.encoder.* is garbage whenever use_cache_branch=true).
  static const realEncoderKvMarker = 2.0;
  static const degenerateEncoderKvMarker = -999.0;

  final List<Map<String, MTensor>> calls = [];
  int _step = 0;

  _FakeDecoderRunner(this.scriptedIds,
      {this.cfg = _cfg, this.extraLogits = const {}, this.handles = false});

  @override
  Future<void> release(Iterable<MTensor> tensors) async {
    for (final t in tensors) {
      if (t.handle != null) releasedHandles.add(t.handle!);
    }
  }

  @override
  Future<Map<String, MTensor>> run(Map<String, MTensor> feeds,
      {Set<String>? fetch}) async {
    calls.add(feeds);
    final useCacheBranch = feeds['use_cache_branch']!.data.first != 0;

    final id = scriptedIds[_step];
    _step++;

    final logits = List<double>.filled(_vocabSize, -10.0);
    logits[id] = 10.0; // the fake's argmax always picks the scripted id.
    extraLogits.forEach((i, v) => logits[i] = v);

    final out = <String, MTensor>{
      'logits': MTensor(logits, [1, 1, _vocabSize]),
    };
    final marianNumHeads = cfg.decoderHeads;
    final marianHeadDim = cfg.headDim;
    for (var l = 0; l < cfg.decoderLayers; l++) {
      // Decoder self-attention KV genuinely "grows": length = call index.
      final decLen = _step;
      out['present.$l.decoder.key'] = MTensor(
        List.filled(marianNumHeads * decLen * marianHeadDim, _step.toDouble()),
        [1, marianNumHeads, decLen, marianHeadDim],
      );
      out['present.$l.decoder.value'] = MTensor(
        List.filled(marianNumHeads * decLen * marianHeadDim, _step.toDouble()),
        [1, marianNumHeads, decLen, marianHeadDim],
      );
      if (!useCacheBranch) {
        // Step 1: the only call that computes REAL cross-attention KV.
        out['present.$l.encoder.key'] = MTensor(
          [realEncoderKvMarker],
          [1, 1, 1, 1],
        );
        out['present.$l.encoder.value'] = MTensor(
          [realEncoderKvMarker],
          [1, 1, 1, 1],
        );
      } else {
        // Step 2+: mirrors the real graph's observed bug — garbage.
        out['present.$l.encoder.key'] = MTensor(
          [degenerateEncoderKvMarker],
          [0, marianNumHeads, 1, marianHeadDim],
        );
        out['present.$l.encoder.value'] = MTensor(
          [degenerateEncoderKvMarker],
          [0, marianNumHeads, 1, marianHeadDim],
        );
      }
    }
    if (!handles) return out;
    return {
      for (final e in out.entries)
        if (fetch != null && !fetch.contains(e.key))
          e.key: _asHandle(e.value)
        else
          e.key: e.value,
    };
  }

  /// A handle that still remembers its data, so the trap test can read
  /// what was fed back through it.
  MTensor _asHandle(MTensor t) {
    issuedHandles.add(t);
    return MTensor.handle(t, t.shape, t.type);
  }
}

class _FakeEncoderRunner implements MarianSessionRunner {
  final List<Map<String, MTensor>> calls = [];
  final List<MTensor> released = [];

  @override
  Future<void> release(Iterable<MTensor> tensors) async =>
      released.addAll(tensors);

  @override
  Future<Map<String, MTensor>> run(Map<String, MTensor> feeds,
      {Set<String>? fetch}) async {
    calls.add(feeds);
    final encSeqLen = feeds['input_ids']!.shape[1];
    return {
      'last_hidden_state': MTensor(List.filled(encSeqLen * 4, 0.1), [
        1,
        encSeqLen,
        4,
      ]),
    };
  }
}

MarianUnigramTokenizer _tinyTokenizer() =>
    MarianUnigramTokenizer([const SpmPiece('▁hi', -1.0, SpmPieceType.normal)]);

MarianVocabulary _tinyVocab() => MarianVocabulary({
  '</s>': 0,
  '<unk>': 1,
  '▁hi': 2,
  '▁hola': 3,
  '▁mundo': 4,
  '!': 5,
  '<pad>': 6,
});

void main() {
  group('MarianGenerationLoop — mechanics, against a faked session '
      'boundary (never touches package:flutter_onnxruntime)', () {
    test(
      'step 1 feeds use_cache_branch=false with true zero-length '
      'past_key_values for every layer, both decoder and encoder slots',
      () async {
        final decoder = _FakeDecoderRunner([0]); // EOS immediately
        final loop = MarianGenerationLoop(
          encoderRunner: _FakeEncoderRunner(),
          decoderRunner: decoder,
          tokenizer: _tinyTokenizer(),
          vocab: _tinyVocab(),
          config: _cfg,
        );

        await loop.translate('hi');

        final step1 = decoder.calls.first;
        expect(step1['use_cache_branch']!.data.first, 0);
        for (var l = 0; l < _cfg.decoderLayers; l++) {
          for (final kind in ['decoder', 'encoder']) {
            for (final kv in ['key', 'value']) {
              final t = step1['past_key_values.$l.$kind.$kv']!;
              expect(
                t.shape[2],
                0,
                reason:
                    '$kind.$kv for layer $l must be TRUE zero-length '
                    'on step 1, not a guessed non-zero placeholder',
              );
            }
          }
        }
      },
    );

    test('step 2+ threads the PREVIOUS step\'s present.*.decoder.* '
        'forward as past_key_values.*.decoder.* — the self-attention '
        'cache genuinely grows', () async {
      final decoder = _FakeDecoderRunner([2, 3, 0]); // two tokens then EOS
      final loop = MarianGenerationLoop(
        encoderRunner: _FakeEncoderRunner(),
        decoderRunner: decoder,
        tokenizer: _tinyTokenizer(),
        vocab: _tinyVocab(),
        config: _cfg,
      );

      await loop.translate('hi');

      expect(decoder.calls.length, 3);
      final step2 = decoder.calls[1];
      expect(step2['use_cache_branch']!.data.first, 1);
      // Step 1 produced present.0.decoder.key filled with 1.0 (call index
      // 1) at length 1 — step 2 must feed exactly that back.
      final fed = step2['past_key_values.0.decoder.key']!;
      expect(fed.shape[2], 1);
      expect(fed.data, everyElement(1.0));
    });

    test('THE TRAP, pinned: step 3 still feeds the FROZEN step-1 '
        'cross-attention KV, never step 2\'s own (degenerate) '
        'present.*.encoder.* output — proves naive present->past '
        'threading of that slot cannot silently creep back in', () async {
      final decoder = _FakeDecoderRunner([2, 3, 4, 0]); // three tokens, EOS
      final loop = MarianGenerationLoop(
        encoderRunner: _FakeEncoderRunner(),
        decoderRunner: decoder,
        tokenizer: _tinyTokenizer(),
        vocab: _tinyVocab(),
        config: _cfg,
      );

      await loop.translate('hi');

      expect(decoder.calls.length, 4);
      final step3 = decoder.calls[2];
      final fedEncoderKv = step3['past_key_values.0.encoder.key']!;
      expect(
        fedEncoderKv.data,
        everyElement(_FakeDecoderRunner.realEncoderKvMarker),
        reason:
            'step 3 must still see step 1\'s real cross-attention KV '
            '(marker ${_FakeDecoderRunner.realEncoderKvMarker}) — if this '
            'ever reads ${_FakeDecoderRunner.degenerateEncoderKvMarker}, '
            'someone reintroduced naive present->past threading for the '
            'cross-attention slot and the fix in ADR-0008 has regressed',
      );
    });

    test('stops at EOS (id 0) and decodes exactly the generated ids up '
        'to it', () async {
      final decoder = _FakeDecoderRunner([3, 4, 0]); // hola mundo </s>
      final loop = MarianGenerationLoop(
        encoderRunner: _FakeEncoderRunner(),
        decoderRunner: decoder,
        tokenizer: _tinyTokenizer(),
        vocab: _tinyVocab(),
        config: _cfg,
      );

      final result = await loop.translate('hi');

      expect(result, 'hola mundo');
      expect(decoder.calls.length, 3);
    });

    test('the length cap stops generation even when EOS never comes: '
        '3x input tokens + 16', () async {
      // 'hi' encodes to one piece (▁hi) + EOS = 2 input ids, so the cap
      // is 3*2+16 = 22 decoder calls, never id 0.
      final scripted = List<int>.filled(100, 3); // '▁mundo', never EOS
      final decoder = _FakeDecoderRunner(scripted);
      final loop = MarianGenerationLoop(
        encoderRunner: _FakeEncoderRunner(),
        decoderRunner: decoder,
        tokenizer: _tinyTokenizer(),
        vocab: _tinyVocab(),
        config: _cfg,
      );

      await loop.translate('hi');

      expect(decoder.calls.length, 22);
    });

    test('the encoder runs exactly once per translate() call', () async {
      final encoder = _FakeEncoderRunner();
      final loop = MarianGenerationLoop(
        encoderRunner: encoder,
        decoderRunner: _FakeDecoderRunner([2, 3, 0]),
        tokenizer: _tinyTokenizer(),
        vocab: _tinyVocab(),
        config: _cfg,
      );

      await loop.translate('hi');

      expect(encoder.calls, hasLength(1));
    });

    test('dims come from the config: a 2-layer, 4-head pair gets exactly '
        'its own past_key_values, shaped by its own head width', () async {
      const small = MarianModelConfig(
        decoderLayers: 2,
        decoderHeads: 4,
        headDim: 8,
        decoderStartTokenId: 7,
        eosTokenId: 0,
        padTokenId: 6,
        suppressedTokenIds: {6},
      );
      final decoder = _FakeDecoderRunner([3, 0], cfg: small);
      final loop = MarianGenerationLoop(
        encoderRunner: _FakeEncoderRunner(),
        decoderRunner: decoder,
        tokenizer: _tinyTokenizer(),
        vocab: _tinyVocab(),
        config: small,
      );

      expect(await loop.translate('hi'), 'hola');

      final step1 = decoder.calls.first;
      final pastKeys =
          step1.keys.where((k) => k.startsWith('past_key_values.')).toList();
      expect(pastKeys, hasLength(2 * 2 * 2));
      expect(step1.containsKey('past_key_values.2.decoder.key'), isFalse);
      expect(step1['past_key_values.1.encoder.value']!.shape, [1, 4, 0, 8]);
      expect(decoder.calls[1].keys.where((k) => k.startsWith('past_')),
          hasLength(8));
    });

    test('step 1 starts from decoder_start_token_id, not the vocab\'s pad',
        () async {
      const startsElsewhere = MarianModelConfig(
        decoderLayers: 6,
        decoderHeads: 8,
        headDim: 64,
        decoderStartTokenId: 7,
        eosTokenId: 0,
        padTokenId: 6,
        suppressedTokenIds: {6},
      );
      final decoder = _FakeDecoderRunner([0], cfg: startsElsewhere);
      final loop = MarianGenerationLoop(
        encoderRunner: _FakeEncoderRunner(),
        decoderRunner: decoder,
        tokenizer: _tinyTokenizer(),
        vocab: _tinyVocab(),
        config: startsElsewhere,
      );

      await loop.translate('hi');

      expect(decoder.calls.first['input_ids']!.data, [7]);
    });

    test('a suppressed id never wins, even when it scores highest (the '
        'pad collapse ADR-0014 saw in en-jap)', () async {
      // pad (6) scores 50 on every step; the scripted ids score 10.
      final decoder = _FakeDecoderRunner([3, 4, 0], extraLogits: {6: 50.0});
      final loop = MarianGenerationLoop(
        encoderRunner: _FakeEncoderRunner(),
        decoderRunner: decoder,
        tokenizer: _tinyTokenizer(),
        vocab: _tinyVocab(),
        config: _cfg,
      );

      expect(await loop.translate('hi'), 'hola mundo');
    });

    test('a multi-target pair\'s >>xx<< id leads the source ids, before '
        'the SentencePiece pieces and EOS', () async {
      final encoder = _FakeEncoderRunner();
      final loop = MarianGenerationLoop(
        encoderRunner: encoder,
        decoderRunner: _FakeDecoderRunner([0]),
        tokenizer: _tinyTokenizer(),
        vocab: _tinyVocab(),
        config: _cfg,
        targetTokenId: 5,
      );

      await loop.translate('hi');

      expect(encoder.calls.single['input_ids']!.data, [5, 2, 0]);
      expect(encoder.calls.single['input_ids']!.shape, [1, 3]);
    });

    test('runtime-side handles: the cache goes back in as handles, the '
        'trap fix still holds through them, and every handle is released '
        'by the end of the sentence', () async {
      final encoder = _FakeEncoderRunner();
      final decoder = _FakeDecoderRunner([2, 3, 4, 0], handles: true);
      final loop = MarianGenerationLoop(
        encoderRunner: encoder,
        decoderRunner: decoder,
        tokenizer: _tinyTokenizer(),
        vocab: _tinyVocab(),
        config: _cfg,
      );

      expect(await loop.translate('hi'), 'hi hola mundo');

      final fed = decoder.calls[2]['past_key_values.0.encoder.key']!;
      expect(fed.handle, isNotNull);
      expect((fed.handle! as MTensor).data,
          everyElement(_FakeDecoderRunner.realEncoderKvMarker));
      expect(decoder.releasedHandles.toSet(), decoder.issuedHandles.toSet(),
          reason: 'a handle never released is native memory leaked per '
              'sentence');
      expect(decoder.releasedHandles, hasLength(decoder.issuedHandles.length),
          reason: 'and none released twice');
      expect(encoder.released, hasLength(1));
    });
  });
}
