@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loom_core/loom_core.dart' show containsCjk;
import 'package:ml_runtime/ml_runtime.dart';
import 'package:trellis/features/reader/translation/marian_generation_loop.dart';

import '../../support/ort_marian.dart';

/// The converted Japanese to English pair (ElanMT-BT, which replaced
/// opus-mt-ja-en on 2026-11-11) through the app's own generation loop,
/// tokenizer, vocabulary and config reader: the twin of
/// marian_real_pair_test.dart. Skipped unless two variables are set,
/// because model files are never committed:
///
///  * MARIAN_JA_EN_DIR: a folder with the pair's six files, named as the
///    catalog names them.
///  * ORT_PYTHON: a Python with onnxruntime 1.20.1 and numpy.
///
/// The reference (`python`) is the same greedy steps written in Python
/// straight over ONNX Runtime sessions on the same two int8 files, made
/// on 2026-11-11, with the ids Hugging Face's MarianTokenizer gave for the
/// same Japanese. The app's loop must give exactly this.
void main() {
  final dir = Platform.environment['MARIAN_JA_EN_DIR'];
  final python = Platform.environment['ORT_PYTHON'];
  final skip = dir == null || python == null
      ? 'set MARIAN_JA_EN_DIR and ORT_PYTHON to run'
      : false;

  test('the converted ja-en pair translates to English in the app’s own '
      'generation loop', () async {
    final server = await OrtServer.start(python!, {
      'encoder': '$dir/encoder_model_quantized.onnx',
      'decoder': '$dir/decoder_model_merged_quantized.onnx',
    });
    addTearDown(server.close);
    final vocab = MarianVocabulary.fromJsonBytes(
        File('$dir/vocab.json').readAsBytesSync());
    final config = MarianModelConfig.fromJsonBytes(
      config: File('$dir/config.json').readAsBytesSync(),
      tokenizerConfig: File('$dir/tokenizer_config.json').readAsBytesSync(),
    );
    final tokenizer = MarianUnigramTokenizer(
        parseSpmPieceTable(File('$dir/source.spm').readAsBytesSync()));
    final loop = MarianGenerationLoop(
      encoderRunner: OrtRunner(server, 'encoder'),
      decoderRunner: OrtRunner(server, 'decoder'),
      tokenizer: tokenizer,
      vocab: vocab,
      config: config,
    );

    expect(config.decoderStartTokenId, 32000);
    expect(config.eosTokenId, 0);

    // ignore: avoid_print
    print('ONNX Runtime ${server.version}');
    for (final c in _cases) {
      expect(
          [...vocab.encodeIds(tokenizer.encodeToPieces(c.ja)), config.eosTokenId],
          c.ids,
          reason: 'token ids for "${c.ja}"');
      final watch = Stopwatch()..start();
      final en = await loop.translate(c.ja);
      watch.stop();
      // ignore: avoid_print
      print('${c.ja}\n  app loop: $en\n  python:   ${c.python}\n'
          '  ${watch.elapsedMilliseconds} ms');
      expect(en, c.python, reason: 'the same steps over the same graphs');
      expect(containsCjk(en), isFalse, reason: en);
    }
    expect(await server.live(), 0,
        reason: 'every handle the loop was given is released');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 5)));
}

typedef _Case = ({String ja, List<int> ids, String python});

const List<_Case> _cases = [
  (
    ja: 'おはようございます。今日はお元気ですか。',
    ids: [6370, 12, 1352, 2195, 2948, 5886, 6, 8632, 12, 598, 511, 858, 3824, 6, 0],
    python: 'Good morning. How are you today?',
  ),
  (
    ja: '今年は日本語を勉強したいと思っています。',
    ids: [6065, 29, 12, 9598, 19, 10979, 9278, 22780, 5886, 6, 0],
    python: 'I\'d like to study Japanese this year.',
  ),
  (
    ja: '電車は七時に駅を出ます。',
    ids: [3, 8134, 12, 2200, 1482, 464, 9657, 855, 6, 0],
    python: 'The train leaves the station at seven.',
  ),
  (
    ja: '祖母は庭でトマトを育てています。',
    ids: [3, 23061, 12, 5192, 28, 29869, 19, 10941, 2682, 6, 0],
    python: 'My grandmother grows tomatoes in the garden.',
  ),
  (
    ja: 'このエピソードを聞いてくれてありがとう。',
    ids: [114, 8177, 24075, 19624, 123, 27177, 6, 0],
    python: 'Thank you for listening to this episode.',
  ),
  (
    ja: '東京の天気は明日から雨になるでしょう、たぶん。',
    ids: [3, 2380, 10, 25514, 12, 714, 3288, 3643, 893, 11754, 4, 63, 19068, 6, 0],
    python: 'The weather in Tokyo will rain tomorrow, probably.',
  ),
];
