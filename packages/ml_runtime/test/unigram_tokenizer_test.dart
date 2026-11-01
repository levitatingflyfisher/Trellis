import 'dart:convert';
import 'dart:io';

import 'package:ml_runtime/ml_runtime.dart';
import 'package:test/test.dart';

/// A Hugging Face `tokenizer.json` Unigram model with Metaspace words and
/// byte fallback, as Pocket TTS ships (Kyutai's runtime reads it with the
/// `tokenizers` library).
String tokenizerJson(List<List<Object>> vocab) => jsonEncode({
      'normalizer': {
        'type': 'Sequence',
        'normalizers': [
          {'type': 'Prepend', 'prepend': '▁'}
        ]
      },
      'pre_tokenizer': {
        'type': 'Metaspace',
        'replacement': '▁',
        'prepend_scheme': 'always',
        'split': true
      },
      'model': {
        'type': 'Unigram',
        'unk_id': 0,
        'byte_fallback': true,
        'vocab': vocab,
      },
    });

void main() {
  final vocab = <List<Object>>[
    ['<unk>', 0.0],
    ['<s>', 0.0],
    ['</s>', 0.0],
    ['<pad>', 0.0],
    for (var b = 0; b < 256; b++)
      ['<0x${b.toRadixString(16).toUpperCase().padLeft(2, '0')}>', 0.0],
    ['▁', -2.0], // 260
    ['▁ha', -3.0], // 261
    ['llo', -3.0], // 262
    ['▁hallo', -4.0], // 263
    ['h', -5.0], // 264
    ['a', -5.0], // 265
    ['l', -5.0], // 266
    ['o', -5.0], // 267
    ['.', -2.0], // 268
    ['▁w', -4.0], // 269
    ['elt', -4.0], // 270
  ];
  final tok = UnigramTokenizer.fromJson(tokenizerJson(vocab));

  test('the best-scoring split wins: one whole piece over two', () {
    expect(tok.encode('hallo'), [263]);
  });

  test('each word starts with ▁ and is split on its own', () {
    expect(tok.encode('hallo welt.'), [263, 269, 270, 268]);
  });

  test('a character no piece covers is spelled as its UTF-8 bytes', () {
    // ß is C3 9F: <0xC3> is id 4 + 0xC3, <0x9F> is 4 + 0x9F.
    expect(tok.encode('haß'), [261, 4 + 0xC3, 4 + 0x9F]);
  });

  test('a run of unknown characters falls back byte by byte, in order', () {
    expect(tok.encode('ßü'), [260, 4 + 0xC3, 4 + 0x9F, 4 + 0xC3, 4 + 0xBC]);
  });

  test('two spaces make a word of a bare ▁', () {
    expect(tok.encode('hallo  hallo'), [263, 260, 263]);
  });

  test('decode joins pieces, turns ▁ into a space and drops the first '
      'one, and joins byte pieces into UTF-8', () {
    expect(tok.decode([263, 269, 270, 268]), 'hallo welt.');
    expect(tok.decode([261, 4 + 0xC3, 4 + 0x9F]), 'haß');
    expect(tok.decode([260, 263]), ' hallo');
    expect(tok.decode([4 + 0xC3]), '\uFFFD', reason: 'half a character');
    expect(tok.decode([]), '');
  });

  test('empty text has no tokens', () {
    expect(tok.encode(''), isEmpty);
  });

  test('a file that is not a Unigram tokenizer is refused', () {
    expect(
        () => UnigramTokenizer.fromJson(jsonEncode({
              'model': {'type': 'BPE', 'vocab': {}}
            })),
        throwsA(isA<FormatException>()));
  });

  // Pocket TTS's real German tokenizer against ids from Hugging Face's
  // own `tokenizers`, when the goldens are on this machine.
  final real = Platform.environment['POCKET_TOKENIZER_GOLDEN_DIR'];
  test('the real tokenizers match Hugging Face on every golden line',
      skip: real == null ? 'set POCKET_TOKENIZER_GOLDEN_DIR to run' : null,
      () {
    final dir = Directory(real!);
    var lines = 0;
    for (final golden in dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains('tokens_'))) {
      final lang = golden.uri.pathSegments.last
          .replaceFirst('tokens_', '')
          .replaceFirst('.json', '');
      final t = UnigramTokenizer.fromJson(
          File('${dir.path}/tokenizer_$lang.json').readAsStringSync());
      final cases = jsonDecode(golden.readAsStringSync()) as List;
      for (final c in cases.cast<Map<String, dynamic>>()) {
        final ids = (c['ids'] as List).cast<int>();
        expect(t.encode(c['text'] as String), ids,
            reason: '$lang: ${c['text']}');
        if (c.containsKey('decoded')) {
          expect(t.decode(ids), c['decoded'], reason: '$lang decode');
          expect(t.decode(ids.skip(1).toList()), c['decoded_tail'],
              reason: '$lang decode tail: ${c['text']}');
          expect(t.decode(ids.take(2).toList()), c['decoded_pair'],
              reason: '$lang decode pair: ${c['text']}');
        }
        lines++;
      }
    }
    expect(lines, greaterThan(0));
  });
}
