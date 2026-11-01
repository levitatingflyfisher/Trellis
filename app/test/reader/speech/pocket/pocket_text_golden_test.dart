@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:trellis/features/reader/speech/pocket/pocket_chunks.dart';
import 'package:trellis/features/reader/speech/pocket/pocket_text.dart';

/// Text preparation and chunking against Kyutai's own functions
/// (pocket-tts 4.0.1), in all seven languages. Skipped unless
/// POCKET_GOLDEN_DIR names a folder with `text_prep_<language>.json` and
/// `tokenizer_<language>.json` for each; the goldens use NTREX lines
/// (CC-BY-SA), so they are never committed.
void main() {
  final dir = Platform.environment['POCKET_GOLDEN_DIR'];
  const names = {
    PocketLanguage.english: 'english',
    PocketLanguage.german: 'german',
    PocketLanguage.spanish: 'spanish',
    PocketLanguage.french: 'french',
    PocketLanguage.italian: 'italian',
    PocketLanguage.portuguese: 'portuguese',
    PocketLanguage.dutch: 'dutch',
  };
  for (final e in names.entries) {
    test('${e.value}: prepared text and chunks equal Kyutai’s', skip:
        dir == null ? 'set POCKET_GOLDEN_DIR to run' : false, () {
      final g = jsonDecode(File('$dir/text_prep_${e.value}.json')
          .readAsStringSync()) as Map<String, dynamic>;
      for (final c in (g['cases'] as List).cast<Map<String, dynamic>>()) {
        final p = preparePocketText(c['input'] as String, e.key);
        expect(p.text, c['prepared'], reason: '${c['input']}');
        expect(p.framesAfterEos, c['frames_after_eos_guess'],
            reason: '${c['input']}');
      }
      final tok = UnigramTokenizer.fromJson(
          File('$dir/tokenizer_${e.value}.json').readAsStringSync());
      for (final c in (g['chunking'] as List).cast<Map<String, dynamic>>()) {
        expect(
            splitPocketChunks(tok, c['input'] as String, e.key,
                maxTokens: c['max_tokens'] as int),
            (c['chunks'] as List).cast<String>(),
            reason: '${c['input']}');
      }
    });
  }
}
