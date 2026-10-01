/// The per-model numbers a Marian (opus-mt) generation loop needs, read
/// from the model's own `config.json` and `tokenizer_config.json`
/// (Trellis 1.5.5). The first pairs all happened to share 6 layers, 8
/// heads and a 512-wide model, and their pad id doubled as the decoder
/// start, so the loop hard-coded both. The wider catalog shares the
/// dims but not the ids (pad runs 58100 to 80378), and nothing stops a
/// future pair from differing in dims too. Read, never assumed.
library;

import 'dart:convert';
import 'dart:typed_data';

class MarianModelConfig {
  final int decoderLayers;
  final int decoderHeads;
  final int headDim;
  final int decoderStartTokenId;
  final int eosTokenId;
  final int padTokenId;

  /// Ids greedy decoding must never pick. Pad is always in it: upstream
  /// `MarianMTModel` masks pad during generation whether or not the
  /// config says so, and the en-jap collapse (ADR-0014) was an unmasked
  /// pad winning step 1. Single-token `bad_words_ids` join it; a
  /// multi-token entry bans a sequence, which a per-step mask can't
  /// express, so it is left out rather than over-banning its first token.
  final Set<int> suppressedTokenIds;

  const MarianModelConfig({
    required this.decoderLayers,
    required this.decoderHeads,
    required this.headDim,
    required this.decoderStartTokenId,
    required this.eosTokenId,
    required this.padTokenId,
    required this.suppressedTokenIds,
  });

  factory MarianModelConfig.fromJsonBytes({
    required Uint8List config,
    required Uint8List tokenizerConfig,
  }) {
    final c = jsonDecode(utf8.decode(config));
    final t = jsonDecode(utf8.decode(tokenizerConfig));
    if (c is! Map<String, dynamic> || t is! Map<String, dynamic>) {
      throw const FormatException('Marian config: not a JSON object');
    }
    // One joint vocab.json is reversed to decode; a separate target vocab
    // would decode through the wrong table and print fluent nonsense.
    if (t['separate_vocabs'] == true) {
      throw const FormatException(
          'Marian config: separate_vocabs is not supported');
    }
    int need(String key) {
      final v = c[key];
      if (v is! num) throw FormatException('Marian config: no "$key"');
      return v.toInt();
    }

    final layers = need('decoder_layers');
    final heads = need('decoder_attention_heads');
    final dModel = need('d_model');
    if (heads <= 0 || dModel % heads != 0) {
      throw FormatException(
          'Marian config: d_model $dModel is not divisible by $heads heads');
    }
    final pad = need('pad_token_id');
    final suppressed = <int>{pad};
    final bad = c['bad_words_ids'];
    if (bad is List) {
      for (final seq in bad) {
        if (seq is List && seq.length == 1 && seq.first is num) {
          suppressed.add((seq.first as num).toInt());
        }
      }
    }
    return MarianModelConfig(
      decoderLayers: layers,
      decoderHeads: heads,
      headDim: dModel ~/ heads,
      decoderStartTokenId: need('decoder_start_token_id'),
      eosTokenId: need('eos_token_id'),
      padTokenId: pad,
      suppressedTokenIds: Set.unmodifiable(suppressed),
    );
  }
}
