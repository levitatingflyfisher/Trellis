@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:loom_core/loom_core.dart' show containsCjk;
import 'package:ml_runtime/ml_runtime.dart';
import 'package:trellis/features/reader/translation/marian_generation_loop.dart';
import 'package:trellis/features/reader/translation/marian_types.dart';

/// The converted English to Japanese pair (ElanMT-BT, ADR-0014's
/// amendment of 2026-11-11) through the app's own generation loop,
/// tokenizer, vocabulary and config reader. Skipped unless two variables
/// are set, because model files are never committed:
///
///  * MARIAN_EN_JA_DIR: a folder with the pair's six files, named as the
///    catalog names them (docs/how-to/convert-a-translation-model.md).
///  * ORT_PYTHON: a Python with onnxruntime 1.20.1 and numpy.
///
/// The graphs run in ONNX Runtime through test/support/
/// ort_session_server.py, because flutter_onnxruntime reaches the
/// runtime over a platform channel that `flutter test` lacks. Everything
/// else is the code the phone runs, including leaving the caches on the
/// runtime's side as handles and releasing them.
///
/// Two references, both made on 2026-11-11, with the ids Hugging Face's
/// MarianTokenizer gave for the same English:
///
///  * `python`: the same greedy steps as this loop, written in Python
///    straight over ONNX Runtime sessions on the same two int8 files. The
///    app's loop must give exactly this.
///  * `study`: the conversion study's own runner (optimum's pipeline).
///    It turned out to load the 32-bit merged decoder beside the int8
///    encoder, so it is a close neighbour, not the same model; the loop
///    must stay close to it.
void main() {
  final dir = Platform.environment['MARIAN_EN_JA_DIR'];
  final python = Platform.environment['ORT_PYTHON'];
  final skip = dir == null || python == null
      ? 'set MARIAN_EN_JA_DIR and ORT_PYTHON to run'
      : false;

  test('the converted en-ja pair translates to Japanese in the app’s own '
      'generation loop', () async {
    final server = await _OrtServer.start(python!, {
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
      encoderRunner: _Runner(server, 'encoder'),
      decoderRunner: _Runner(server, 'decoder'),
      tokenizer: tokenizer,
      vocab: vocab,
      config: config,
    );

    expect(config.decoderStartTokenId, 32000);
    expect(config.eosTokenId, 0);
    final spacedJapanese = RegExp(
        r'[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]\s+'
        r'[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]',
        unicode: true);

    // ignore: avoid_print
    print('ONNX Runtime ${server.version}');
    var exact = 0;
    for (final c in _cases) {
      expect(
          [...vocab.encodeIds(tokenizer.encodeToPieces(c.en)), config.eosTokenId],
          c.ids,
          reason: 'token ids for "${c.en}"');
      final watch = Stopwatch()..start();
      final ja = await loop.translate(c.en);
      watch.stop();
      final similarity = _similarity(ja, c.study);
      if (ja == c.study) exact++;
      // ignore: avoid_print
      print('${c.en}\n  app loop: $ja\n  python:   ${c.python}\n'
          '  study:    ${c.study}\n'
          '  similarity to study ${similarity.toStringAsFixed(2)}, '
          '${watch.elapsedMilliseconds} ms');
      expect(ja, c.python, reason: 'the same steps over the same graphs');
      expect(containsCjk(ja), isTrue, reason: ja);
      expect(spacedJapanese.hasMatch(ja), isFalse,
          reason: 'a space between Japanese words: $ja');
      expect(similarity, greaterThanOrEqualTo(0.8), reason: ja);
    }
    // ignore: avoid_print
    print('$exact of ${_cases.length} identical to the study runner, '
        'all ${_cases.length} identical to the Python steps');
    expect(await server.live(), 0,
        reason: 'every handle the loop was given is released');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 5)));
}

typedef _Case = ({String en, List<int> ids, String python, String study});

const List<_Case> _cases = [
  (
    en: 'Good morning. How are you today?',
    ids: [7718, 3556, 7, 4583, 55, 206, 1554, 142, 0],
    python: 'おはようございます。今日はいかがですか。',
    study: 'おはようございます。今日はいかがですか。',
  ),
  (
    en: 'The quick brown fox jumps over the lazy dog.',
    ids: [30, 14898, 16369, 27223, 12112, 9, 167, 2, 3131, 8641, 7521, 7, 0],
    python: '早茶色の狐は怠け者の犬に飛びかかる。',
    study: '早茶色の狐は怠け者の犬を飛び越える。',
  ),
  (
    en: 'I would like to learn Japanese this year.',
    ids: [77, 157, 391, 14, 5977, 314, 80, 250, 7, 0],
    python: '今年は日本語を習いたいです。',
    study: '今年は日本語を習いたい。',
  ),
  (
    en: "The train leaves the station at seven o'clock.",
    ids: [30, 1732, 7020, 2, 719, 44, 1969, 2867, 27, 21836, 7, 0],
    python: '列車は7時に駅を出る。',
    study: '列車は7時に駅を出ます。',
  ),
  (
    en: 'My grandmother grows tomatoes in her garden.',
    ids: [1989, 23916, 7293, 9, 14, 16469, 135, 13, 140, 4775, 7, 0],
    python: '祖母は庭でトマトを育てています。',
    study: '祖母は庭でトマトを育てている。',
  ),
  (
    en: 'Thank you for listening to this episode.',
    ids: [17331, 243, 206, 32, 12453, 37, 14, 80, 6499, 7, 0],
    python: 'このエピソードを聞いてくれてありがとう。',
    study: 'このエピソードを聞いてくれてありがとう。',
  ),
];

/// 1 minus the character edit distance over the longer length.
double _similarity(String a, String b) {
  final x = a.runes.toList(), y = b.runes.toList();
  if (x.isEmpty && y.isEmpty) return 1;
  var prev = List<int>.generate(y.length + 1, (j) => j);
  for (var i = 1; i <= x.length; i++) {
    final row = List<int>.filled(y.length + 1, 0)..[0] = i;
    for (var j = 1; j <= y.length; j++) {
      final cost = x[i - 1] == y[j - 1] ? 0 : 1;
      row[j] = [prev[j] + 1, row[j - 1] + 1, prev[j - 1] + cost]
          .reduce((p, q) => p < q ? p : q);
    }
    prev = row;
  }
  final longer = x.length > y.length ? x.length : y.length;
  return 1 - prev[y.length] / longer;
}

class _OrtServer {
  final Process _process;
  final StreamIterator<String> _lines;
  final String version;

  _OrtServer(this._process, this._lines, this.version);

  static Future<_OrtServer> start(
      String python, Map<String, String> sessions) async {
    final script = '${Directory.current.path}/test/support/ort_session_server.py';
    final process = await Process.start(python, [
      '-I',
      script,
      for (final e in sessions.entries) '${e.key}=${e.value}',
    ]);
    process.stderr.transform(utf8.decoder).listen(stderr.write);
    final lines = StreamIterator(process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter()));
    if (!await lines.moveNext()) {
      throw StateError('the ONNX Runtime helper did not start');
    }
    final hello = jsonDecode(lines.current) as Map<String, dynamic>;
    return _OrtServer(process, lines, hello['ort'] as String);
  }

  Future<Map<String, dynamic>> ask(Map<String, Object?> request) async {
    _process.stdin.writeln(jsonEncode(request));
    await _process.stdin.flush();
    if (!await _lines.moveNext()) {
      throw StateError('the ONNX Runtime helper stopped');
    }
    return jsonDecode(_lines.current) as Map<String, dynamic>;
  }

  Future<int> live() async => (await ask({'op': 'live'}))['live'] as int;

  Future<void> close() async {
    await _process.stdin.close();
    await _process.exitCode;
  }
}

class _Runner implements MarianSessionRunner {
  final _OrtServer server;
  final String session;
  _Runner(this.server, this.session);

  @override
  Future<Map<String, MTensor>> run(Map<String, MTensor> feeds,
      {Set<String>? fetch}) async {
    final reply = await server.ask({
      'op': 'run',
      'session': session,
      'feeds': {for (final e in feeds.entries) e.key: _encode(e.value)},
      'fetch': fetch?.toList(),
    });
    final outputs = reply['outputs'] as Map<String, dynamic>;
    return {
      for (final e in outputs.entries)
        e.key: _decode(e.value as Map<String, dynamic>),
    };
  }

  @override
  Future<void> release(Iterable<MTensor> tensors) async {
    final ids = [
      for (final t in tensors)
        if (t.handle case final int id) id,
    ];
    if (ids.isEmpty) return;
    await server.ask({'op': 'release', 'handles': ids});
  }
}

Map<String, Object?> _encode(MTensor t) {
  if (t.handle case final int id) return {'handle': id};
  final Uint8List bytes = switch (t.type) {
    MTensorType.int64 => Int64List.fromList([for (final v in t.data) v.toInt()])
        .buffer
        .asUint8List(),
    MTensorType.float32 =>
      Float32List.fromList([for (final v in t.data) v.toDouble()])
          .buffer
          .asUint8List(),
    MTensorType.boolean =>
      Uint8List.fromList([for (final v in t.data) v == 0 ? 0 : 1]),
  };
  return {
    'dtype': t.type.name,
    'shape': t.shape,
    'b64': base64Encode(bytes),
  };
}

MTensor _decode(Map<String, dynamic> m) {
  final type = MTensorType.values.byName(m['dtype'] as String);
  final shape = (m['shape'] as List).cast<int>();
  if (m['handle'] case final int id) return MTensor.handle(id, shape, type);
  final bytes = base64Decode(m['b64'] as String);
  final List<num> data = switch (type) {
    MTensorType.int64 => bytes.buffer.asInt64List(),
    MTensorType.float32 => bytes.buffer.asFloat32List(),
    MTensorType.boolean => bytes,
  };
  return MTensor(data, shape, type);
}
