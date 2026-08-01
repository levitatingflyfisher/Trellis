/// dictzip: a gzip file (RFC 1952) carrying an extra ("RA") subfield that
/// records a chunk table, letting a reader inflate just the chunk(s) a
/// lookup needs instead of the whole file (GNU dictd's own format, and
/// what `.dict.dz` files in the wild actually are).
///
/// Header layout after the fixed 10-byte gzip header (magic, CM, FLG,
/// MTIME, XFL, OS): if FLG's FEXTRA bit is set, a 2-byte little-endian
/// XLEN then XLEN bytes of extra-field subfields, each `SI1 SI2 LEN(u16
/// LE) DATA[LEN]`. The dictzip subfield is `SI1='R' SI2='A'`; its DATA is
/// `VER(u16 LE) CHLEN(u16 LE) CHCNT(u16 LE)` then CHCNT 2-byte-LE
/// compressed chunk lengths. FNAME/FCOMMENT/FHCRC (if present) follow the
/// extra field; the deflate stream for chunk 0 starts right after them.
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'dictionary.dart' show DictBody;

class DictzipChunkTable {
  const DictzipChunkTable({
    required this.chunkLength,
    required this.chunkCompressedSizes,
    required this.dataStartOffset,
  });

  /// Uncompressed bytes per chunk (the last chunk may be shorter).
  final int chunkLength;

  /// Compressed byte length of each chunk, in file order.
  final List<int> chunkCompressedSizes;

  /// Byte offset into the file where chunk 0's deflate stream begins.
  final int dataStartOffset;
}

int _u16le(Uint8List b, int at) => b[at] | (b[at + 1] << 8);

/// Parses the gzip + RA-extra-field header. Throws [FormatException] on
/// anything that isn't a real dictzip file: bad magic, an unsupported
/// compression method, no FEXTRA field, or no RA subfield inside it — a
/// plain (non-dictzip) `.dict.gz` is a genuinely different case
/// ([DictzipBody] is only for real dictzip files; a plain gzip .dict
/// would need a whole-file inflate, which this door deliberately does
/// not do).
DictzipChunkTable parseDictzipHeader(Uint8List bytes) {
  if (bytes.length < 10 || bytes[0] != 0x1f || bytes[1] != 0x8b) {
    throw const FormatException('not a gzip file (bad magic)');
  }
  if (bytes[2] != 0x08) {
    throw const FormatException('unsupported gzip compression method');
  }
  final flg = bytes[3];
  var pos = 10;
  if (flg & 0x04 == 0) {
    throw const FormatException(
        'not a dictzip file (no FEXTRA field — a plain gzip .dict needs '
        'whole-file inflate, unsupported here)');
  }
  final xlen = _u16le(bytes, pos);
  pos += 2;
  final extraEnd = pos + xlen;
  DictzipChunkTable? table;
  var sp = pos;
  while (sp + 4 <= extraEnd) {
    final si1 = bytes[sp];
    final si2 = bytes[sp + 1];
    final len = _u16le(bytes, sp + 2);
    final dataStart = sp + 4;
    if (si1 == 0x52 && si2 == 0x41) {
      // 'R' 'A'
      final chlen = _u16le(bytes, dataStart + 2);
      final chcnt = _u16le(bytes, dataStart + 4);
      final sizes = <int>[];
      for (var i = 0; i < chcnt; i++) {
        sizes.add(_u16le(bytes, dataStart + 6 + i * 2));
      }
      table = DictzipChunkTable(
          chunkLength: chlen, chunkCompressedSizes: sizes, dataStartOffset: 0);
    }
    sp = dataStart + len;
  }
  if (table == null) {
    throw const FormatException(
        'not a dictzip file (FEXTRA present but no RA subfield)');
  }
  pos = extraEnd;
  if (flg & 0x08 != 0) {
    // FNAME: NUL-terminated.
    while (pos < bytes.length && bytes[pos] != 0) {
      pos++;
    }
    pos++;
  }
  if (flg & 0x10 != 0) {
    // FCOMMENT: NUL-terminated.
    while (pos < bytes.length && bytes[pos] != 0) {
      pos++;
    }
    pos++;
  }
  if (flg & 0x02 != 0) {
    pos += 2; // FHCRC
  }
  return DictzipChunkTable(
      chunkLength: table.chunkLength,
      chunkCompressedSizes: table.chunkCompressedSizes,
      dataStartOffset: pos);
}

/// A real random-access reader over a `.dict.dz` file: only the chunks a
/// given [read] call actually needs are inflated, never the whole file.
class DictzipBody implements DictBody {
  DictzipBody(this._bytes) : _table = parseDictzipHeader(_bytes) {
    // Precompute each chunk's starting byte offset in the compressed
    // stream once, rather than re-summing on every read.
    var offset = _table.dataStartOffset;
    for (final size in _table.chunkCompressedSizes) {
      _chunkFileOffsets.add(offset);
      offset += size;
    }
  }

  final Uint8List _bytes;
  final DictzipChunkTable _table;
  final List<int> _chunkFileOffsets = [];

  /// Inflates exactly [chunkIndex]'s own compressed bytes — a standalone
  /// deflate stream, since dictzip resets its compressor at every chunk
  /// boundary specifically so this works.
  Uint8List _inflateChunk(int chunkIndex) {
    final start = _chunkFileOffsets[chunkIndex];
    final len = _table.chunkCompressedSizes[chunkIndex];
    final compressed = _bytes.sublist(start, start + len);
    return Inflate(compressed).getBytes();
  }

  /// Reads [length] uncompressed bytes starting at uncompressed [offset],
  /// inflating only the chunk(s) that range actually falls in.
  @override
  Uint8List read(int offset, int length) {
    if (length == 0) return Uint8List(0);
    final chunkLen = _table.chunkLength;
    final firstChunk = offset ~/ chunkLen;
    final lastChunk = (offset + length - 1) ~/ chunkLen;
    final buffer = BytesBuilder();
    for (var c = firstChunk; c <= lastChunk; c++) {
      buffer.add(_inflateChunk(c));
    }
    final localStart = offset - firstChunk * chunkLen;
    final all = buffer.toBytes();
    return all.sublist(localStart, localStart + length);
  }
}
