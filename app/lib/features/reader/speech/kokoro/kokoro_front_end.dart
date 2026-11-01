/// The Chinese voice's text front end on the phone: the seven data files
/// (jieba, pypinyin, misaki tables) read and parsed off the main isolate,
/// about half a second on a desktop, then each sentence into Kokoro's
/// chunks by the `mandarin_g2p` port of misaki.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:mandarin_g2p/mandarin_g2p.dart';

import 'kokoro_engine.dart';

class KokoroFrontEndMissingException implements Exception {
  final String message;
  const KokoroFrontEndMissingException(this.message);
  @override
  String toString() => message;
}

/// [paths] by role: `jiebaDict`, `finalsegHmm`, `possegHmm`,
/// `pinyinSingle`, `pinyinPhrases`, `pinyinAux`, `misakiTables`.
Future<KokoroFrontEnd> loadKokoroFrontEnd(Map<String, String> paths) async {
  for (final path in paths.values) {
    if (!File(path).existsSync()) {
      throw const KokoroFrontEndMissingException(
          'The Chinese voice is missing a file it needs. Try downloading '
          'it again in Models.');
    }
  }
  final g2p = await Isolate.run(() {
    String read(String role) => File(paths[role]!).readAsStringSync();
    return MandarinG2p.fromData(
      jiebaDict: read('jiebaDict'),
      finalsegHmm: read('finalsegHmm'),
      possegHmm: read('possegHmm'),
      pinyinSingle: read('pinyinSingle'),
      pinyinPhrases: read('pinyinPhrases'),
      pinyinAux: read('pinyinAux'),
      misakiTables: read('misakiTables'),
    );
  });
  return (sentence) => kokoroChunks(g2p, sentence);
}

/// [sentence] as Kokoro's chunks. misaki itself fails on a few rare
/// characters whose reading has no final (呣, or one missing from
/// pypinyin's table), and the port fails the same way. Rather than lose
/// the sentence, those characters are left out and the rest is said.
List<KokoroChunk> kokoroChunks(MandarinG2p g2p, String sentence) {
  List<KokoroZhTokens> tokens;
  try {
    tokens = g2p.g2pChunks(sentence);
  } on RangeError {
    tokens = _withoutUnreadable(g2p, sentence);
  } on ArgumentError {
    tokens = _withoutUnreadable(g2p, sentence);
  }
  return [
    for (final t in tokens)
      if (t.inputIds.length > 2)
        KokoroChunk(inputIds: t.inputIds, lenPs: t.lenPs),
  ];
}

List<KokoroZhTokens> _withoutUnreadable(MandarinG2p g2p, String sentence) {
  final kept = StringBuffer();
  for (final r in sentence.runes) {
    final c = String.fromCharCode(r);
    try {
      g2p.g2p(c);
      kept.write(c);
    } on RangeError {
      // Unreadable: left out.
    } on ArgumentError {
      // Unreadable: left out.
    }
  }
  try {
    return g2p.g2pChunks(kept.toString());
  } on RangeError {
    return const [];
  } on ArgumentError {
    return const [];
  }
}
