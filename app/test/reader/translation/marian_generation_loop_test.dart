import 'package:flutter_test/flutter_test.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:trellis/features/reader/translation/marian_engine.dart';

/// A deterministic fake decoder session — never touches ONNX Runtime.
/// [scriptedIds] is the sequence of token ids to emit, one per call (the
/// fake ignores everything about the feeds except `use_cache_branch` and
/// the threaded past KV, which it records for assertions).
class _FakeDecoderRunner implements MarianSessionRunner {
  final List<int> scriptedIds;
  static const _vocabSize = 8;

  /// The marker value real (step-1-computed) cross-attention KV carries
  /// in this fake, vs. the DEGENERATE marker a cached-branch call
  /// returns for that same slot — mirroring the real graph's observed
  /// bug (present.*.encoder.* is garbage whenever use_cache_branch=true).
  static const realEncoderKvMarker = 2.0;
  static const degenerateEncoderKvMarker = -999.0;

  final List<Map<String, MTensor>> calls = [];
  int _step = 0;

  _FakeDecoderRunner(this.scriptedIds);

  @override
  Future<Map<String, MTensor>> run(Map<String, MTensor> feeds) async {
    calls.add(feeds);
    final useCacheBranch = feeds['use_cache_branch']!.data.first != 0;

    final id = scriptedIds[_step];
    _step++;

    final logits = List<double>.filled(_vocabSize, -10.0);
    logits[id] = 10.0; // the fake's argmax always picks the scripted id.

    final out = <String, MTensor>{
      'logits': MTensor(logits, [1, 1, _vocabSize]),
    };
    for (var l = 0; l < marianNumLayers; l++) {
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
        out['present.$l.encoder.key'] = const MTensor(
          [realEncoderKvMarker],
          [1, 1, 1, 1],
        );
        out['present.$l.encoder.value'] = const MTensor(
          [realEncoderKvMarker],
          [1, 1, 1, 1],
        );
      } else {
        // Step 2+: mirrors the real graph's observed bug — garbage.
        out['present.$l.encoder.key'] = const MTensor(
          [degenerateEncoderKvMarker],
          [0, marianNumHeads, 1, marianHeadDim],
        );
        out['present.$l.encoder.value'] = const MTensor(
          [degenerateEncoderKvMarker],
          [0, marianNumHeads, 1, marianHeadDim],
        );
      }
    }
    return out;
  }
}

class _FakeEncoderRunner implements MarianSessionRunner {
  final List<Map<String, MTensor>> calls = [];

  @override
  Future<Map<String, MTensor>> run(Map<String, MTensor> feeds) async {
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
        );

        await loop.translate('hi');

        final step1 = decoder.calls.first;
        expect(step1['use_cache_branch']!.data.first, 0);
        for (var l = 0; l < marianNumLayers; l++) {
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
      );

      await loop.translate('hi');

      expect(encoder.calls, hasLength(1));
    });
  });
}
