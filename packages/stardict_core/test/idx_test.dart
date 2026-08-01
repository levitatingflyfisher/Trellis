import 'dart:typed_data';

import 'package:stardict_core/stardict_core.dart';
import 'package:test/test.dart';

/// StarDict's binary `.idx`: repeated `word\0` + 4-byte big-endian offset
/// + 4-byte big-endian length (32-bit offsets — the default; 64-bit
/// offsets are a separate, larger encoding this door does not build
/// fixtures for, since the one verified real dictionary uses 32-bit).
void main() {
  Uint8List be32(int v) => (ByteData(4)..setUint32(0, v, Endian.big))
      .buffer
      .asUint8List();

  Uint8List buildIdx(List<(String, int, int)> entries) {
    final b = BytesBuilder();
    for (final (word, offset, length) in entries) {
      b.add(word.codeUnits);
      b.addByte(0);
      b.add(be32(offset));
      b.add(be32(length));
    }
    return b.toBytes();
  }

  group('parseIdx32', () {
    test('reads word/offset/length triples in file order', () {
      final bytes = buildIdx([
        ('alpha', 0, 10),
        ('bravo', 10, 20),
        ('charlie', 30, 5),
      ]);
      final entries = parseIdx32(bytes);
      expect(entries, hasLength(3));
      expect(entries[0].word, 'alpha');
      expect(entries[0].offset, 0);
      expect(entries[0].length, 10);
      expect(entries[1].word, 'bravo');
      expect(entries[1].offset, 10);
      expect(entries[1].length, 20);
      expect(entries[2].word, 'charlie');
      expect(entries[2].offset, 30);
      expect(entries[2].length, 5);
    });

    test('an empty .idx yields no entries', () {
      expect(parseIdx32(Uint8List(0)), isEmpty);
    });

    test('a truncated final entry throws rather than silently dropping data',
        () {
      final bytes = buildIdx([('ok', 0, 1)]);
      final truncated = bytes.sublist(0, bytes.length - 2);
      expect(() => parseIdx32(truncated), throwsFormatException);
    });
  });
}
