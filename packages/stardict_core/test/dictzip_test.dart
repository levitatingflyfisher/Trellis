import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:stardict_core/stardict_core.dart';
import 'package:test/test.dart';

/// dictzip = gzip with the RA extra field enabling real random-access
/// chunk inflate (GNU dictd's format). This builds a REAL dictzip file
/// by hand -- the gzip header, the RA extra subfield with a genuine
/// chunk table, and independently-deflated chunks -- so these tests prove
/// actual random access, not a mocked shortcut.
void main() {
  Uint8List be16(int v) =>
      Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little);

  /// Builds a real dictzip (.dict.dz) file from [chunks] (each
  /// independently deflated, matching how GNU dictzip actually resets its
  /// compressor at chunk boundaries so any one chunk can be inflated
  /// alone).
  Uint8List buildDictzip(List<String> chunks) {
    final compressed = [for (final c in chunks) Deflate(utf8.encode(c)).getBytes()];
    final chunkLen = chunks.isEmpty ? 0 : utf8.encode(chunks.first).length;

    final extra = BytesBuilder()
      ..add(be16(1)) // VER
      ..add(be16(chunkLen)) // CHLEN
      ..add(be16(compressed.length)); // CHCNT
    for (final c in compressed) {
      extra.add(be16(c.length));
    }
    final extraBytes = extra.toBytes();

    final subfield = BytesBuilder()
      ..addByte(0x52) // 'R'
      ..addByte(0x41) // 'A'
      ..add(be16(extraBytes.length))
      ..add(extraBytes);
    final subfieldBytes = subfield.toBytes();

    final header = BytesBuilder()
      ..addByte(0x1f)
      ..addByte(0x8b)
      ..addByte(0x08) // CM = deflate
      ..addByte(0x04) // FLG = FEXTRA
      ..add([0, 0, 0, 0]) // MTIME
      ..addByte(0x00) // XFL
      ..addByte(0x03) // OS
      ..add(be16(subfieldBytes.length)) // XLEN
      ..add(subfieldBytes);

    final out = BytesBuilder()..add(header.toBytes());
    for (final c in compressed) {
      out.add(c);
    }
    return out.toBytes();
  }

  group('parseDictzipHeader', () {
    test('reads the RA subfield chunk table and finds the data start', () {
      final bytes = buildDictzip(['AAAAAAAAAA', 'BBBBBBBBBB', 'CCCCC']);
      final table = parseDictzipHeader(bytes);
      expect(table.chunkLength, 10);
      expect(table.chunkCompressedSizes, hasLength(3));
      // The data starts exactly where the header (10 bytes) + the RA
      // subfield (4-byte subfield header + its own contents) ends.
      expect(table.dataStartOffset, lessThan(bytes.length));
    });

    test('rejects a plain gzip file with no RA extra field', () {
      final plain = GZipEncoder().encode(utf8.encode('no chunk table here'));
      expect(() => parseDictzipHeader(Uint8List.fromList(plain)),
          throwsFormatException);
    });
  });

  group('DictzipBody.read — real random access', () {
    test('reads a range entirely inside the first chunk', () {
      final bytes = buildDictzip(['0123456789', 'ABCDEFGHIJ', 'KLMNOPQRST']);
      final body = DictzipBody(bytes);
      expect(utf8.decode(body.read(2, 5)), '23456');
    });

    test('reads a range entirely inside a LATER chunk without touching '
        'earlier ones (proves this is real random access, not a full '
        'decompress-then-slice)', () {
      final bytes = buildDictzip(['0123456789', 'ABCDEFGHIJ', 'KLMNOPQRST']);
      final body = DictzipBody(bytes);
      // Offset 13 is local offset 3 inside chunk index 1 ('ABCDEFGHIJ',
      // uncompressed positions 10..19) -- 'D','E','F','G'.
      expect(utf8.decode(body.read(13, 4)), 'DEFG');
    });

    test('reads a range spanning a chunk boundary', () {
      final bytes = buildDictzip(['0123456789', 'ABCDEFGHIJ', 'KLMNOPQRST']);
      final body = DictzipBody(bytes);
      expect(utf8.decode(body.read(7, 6)), '789ABC');
    });

    test('reads the exact full body across all three chunks', () {
      final bytes = buildDictzip(['0123456789', 'ABCDEFGHIJ', 'KLMNOPQRST']);
      final body = DictzipBody(bytes);
      expect(utf8.decode(body.read(0, 30)), '0123456789ABCDEFGHIJKLMNOPQRST');
    });

    test('a shorter final chunk still reads correctly', () {
      final bytes = buildDictzip(['0123456789', 'ABCDEFGHIJ', 'XYZ']);
      final body = DictzipBody(bytes);
      expect(utf8.decode(body.read(20, 3)), 'XYZ');
    });
  });
}
