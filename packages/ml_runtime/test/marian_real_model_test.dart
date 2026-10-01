@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ml_runtime/ml_runtime.dart';
import 'package:test/test.dart';

/// Optional check against a REAL downloaded pair, never committed (model
/// files are runtime downloads). Point MARIAN_MODEL_DIR at a directory
/// holding a pair's source.spm, vocab.json, config.json and
/// tokenizer_config.json, and MARIAN_GOLDENS at a JSON list of
/// {text, ids} made with the real `sentencepiece` library over the same
/// source.spm. Skipped otherwise. Run for 1.5.5 against Xenova's
/// opus-mt-en-ROMANCE (task-C report).
void main() {
  final dir = Platform.environment['MARIAN_MODEL_DIR'];
  final goldens = Platform.environment['MARIAN_GOLDENS'];
  final skip = dir == null || goldens == null
      ? 'set MARIAN_MODEL_DIR and MARIAN_GOLDENS to run'
      : false;

  test('the Dart tokenizer, vocab and config agree with the real model',
      () {
    final pieces = parseSpmPieceTable(
        File('$dir/source.spm').readAsBytesSync());
    final vocab =
        MarianVocabulary.fromJsonBytes(File('$dir/vocab.json').readAsBytesSync());
    final config = MarianModelConfig.fromJsonBytes(
      config: File('$dir/config.json').readAsBytesSync(),
      tokenizerConfig: File('$dir/tokenizer_config.json').readAsBytesSync(),
    );
    expect(config.decoderStartTokenId, vocab.padId);
    expect(config.suppressedTokenIds, contains(vocab.padId));
    final tokenizer = MarianUnigramTokenizer(pieces);
    final cases = jsonDecode(File(goldens!).readAsStringSync()) as List;
    for (final c in cases.cast<Map<String, dynamic>>()) {
      expect(vocab.encodeIds(tokenizer.encodeToPieces(c['text'] as String)),
          (c['ids'] as List).cast<int>(),
          reason: c['text'] as String);
    }
  }, skip: skip);
}
