import 'dart:convert';
import 'dart:typed_data';

import 'package:ml_runtime/ml_runtime.dart';
import 'package:test/test.dart';

Uint8List _json(Map<String, Object?> m) =>
    Uint8List.fromList(utf8.encode(jsonEncode(m)));

/// Two fake pairs that differ in every field the loop reads, so a value
/// assumed instead of read would fail one of them.
final _smallConfig = {
  'decoder_layers': 2,
  'decoder_attention_heads': 4,
  'd_model': 32,
  'decoder_start_token_id': 9,
  'eos_token_id': 0,
  'pad_token_id': 9,
  'bad_words_ids': [
    [9],
  ],
};
final _otherConfig = {
  'decoder_layers': 6,
  'decoder_attention_heads': 8,
  'd_model': 512,
  'decoder_start_token_id': 58100,
  'eos_token_id': 3,
  'pad_token_id': 58100,
  // onnx-community's configs carry no bad_words_ids at all.
};

void main() {
  group('MarianModelConfig — every per-model number is read, never assumed',
      () {
    test('two pairs with different dims and ids parse to their own values',
        () {
      final a = MarianModelConfig.fromJsonBytes(
          config: _json(_smallConfig),
          tokenizerConfig: _json({'separate_vocabs': false}));
      expect(a.decoderLayers, 2);
      expect(a.decoderHeads, 4);
      expect(a.headDim, 8);
      expect(a.decoderStartTokenId, 9);
      expect(a.eosTokenId, 0);
      expect(a.padTokenId, 9);

      final b = MarianModelConfig.fromJsonBytes(
          config: _json(_otherConfig),
          tokenizerConfig: _json({'separate_vocabs': false}));
      expect(b.decoderLayers, 6);
      expect(b.decoderHeads, 8);
      expect(b.headDim, 64);
      expect(b.decoderStartTokenId, 58100);
      expect(b.eosTokenId, 3);
      expect(b.padTokenId, 58100);
    });

    test('pad is always suppressed, plus every single-token bad word', () {
      final withBad = MarianModelConfig.fromJsonBytes(
          config: _json({
            ..._smallConfig,
            'bad_words_ids': [
              [9],
              [4],
              [5, 6], // a multi-token ban is a sequence rule: not a mask
            ],
          }),
          tokenizerConfig: _json({'separate_vocabs': false}));
      expect(withBad.suppressedTokenIds, {9, 4});

      final none = MarianModelConfig.fromJsonBytes(
          config: _json(_otherConfig),
          tokenizerConfig: _json({'separate_vocabs': false}));
      expect(none.suppressedTokenIds, {58100});
    });

    test('separate vocabularies are refused: the decode path reverses ONE '
        'joint vocab.json', () {
      expect(
        () => MarianModelConfig.fromJsonBytes(
            config: _json(_smallConfig),
            tokenizerConfig: _json({'separate_vocabs': true})),
        throwsA(isA<FormatException>()),
      );
    });

    test('a missing load-bearing field is a FormatException, not a default',
        () {
      final broken = Map<String, Object?>.of(_smallConfig)
        ..remove('decoder_start_token_id');
      expect(
        () => MarianModelConfig.fromJsonBytes(
            config: _json(broken),
            tokenizerConfig: _json({'separate_vocabs': false})),
        throwsA(isA<FormatException>()),
      );
    });

    test('d_model that heads do not divide is refused', () {
      expect(
        () => MarianModelConfig.fromJsonBytes(
            config: _json({..._smallConfig, 'd_model': 30}),
            tokenizerConfig: _json({'separate_vocabs': false})),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('MarianVocabulary.directiveId — the >>xx<< target token', () {
    final vocab = MarianVocabulary({
      '</s>': 0,
      '<unk>': 1,
      '>>pt<<': 2,
      '▁ola': 3,
      '<pad>': 4,
    });

    test('a token the vocab carries resolves to its id', () {
      expect(vocab.directiveId('>>pt<<'), 2);
    });

    test('a token the vocab lacks is null, so the caller fails closed', () {
      expect(vocab.directiveId('>>xx<<'), isNull);
    });
  });
}
