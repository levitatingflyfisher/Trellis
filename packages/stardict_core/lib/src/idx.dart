/// StarDict's binary `.idx` file: repeated records of `word\0` (the word
/// as raw UTF-8 bytes, NUL-terminated) + a 4-byte big-endian offset + a
/// 4-byte big-endian length, both into the `.dict`/`.dict.dz` body. This
/// is the 32-bit-offset encoding (`idxoffsetbits` absent or 32 in the
/// `.ifo`) — the only one a verified real dictionary in this campaign
/// uses; a 64-bit variant exists in the format but isn't built here.
library;

import 'dart:typed_data';

class StarDictIndexEntry {
  const StarDictIndexEntry(
      {required this.word, required this.offset, required this.length});
  final String word;
  final int offset;
  final int length;
}

/// Parses a whole `.idx` buffer. Throws [FormatException] on a truncated
/// trailing record (a NUL with fewer than 8 bytes remaining, or a NUL
/// missing before the buffer ends) rather than silently dropping the
/// partial tail — a truncated download should surface as an error, not a
/// dictionary quietly missing its last entries.
List<StarDictIndexEntry> parseIdx32(Uint8List bytes) {
  final entries = <StarDictIndexEntry>[];
  var i = 0;
  while (i < bytes.length) {
    final nul = bytes.indexOf(0, i);
    if (nul < 0) {
      throw const FormatException(
          'StarDict .idx: unterminated word at end of file');
    }
    final word = String.fromCharCodes(bytes.sublist(i, nul));
    final fieldsStart = nul + 1;
    if (fieldsStart + 8 > bytes.length) {
      throw const FormatException(
          'StarDict .idx: truncated offset/length fields at end of file');
    }
    final data = ByteData.sublistView(bytes, fieldsStart, fieldsStart + 8);
    final offset = data.getUint32(0, Endian.big);
    final length = data.getUint32(4, Endian.big);
    entries.add(StarDictIndexEntry(word: word, offset: offset, length: length));
    i = fieldsStart + 8;
  }
  return entries;
}
