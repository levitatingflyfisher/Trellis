// Tiny hand-built MP4/M4B box trees for [parseM4bChapters] — real files run
// to hundreds of megabytes; these fixtures are the whole point of the pure,
// bytes-in-structure-out design: no real audio file is needed to prove the
// box walk.
import 'dart:convert';
import 'dart:typed_data';

Uint8List _box(String fourcc, List<int> body) {
  final bytes = BytesBuilder();
  final size = 8 + body.length;
  bytes.add(_u32be(size));
  bytes.add(ascii.encode(fourcc));
  bytes.add(body);
  return bytes.toBytes();
}

List<int> _u32be(int v) => [
      (v >> 24) & 0xff,
      (v >> 16) & 0xff,
      (v >> 8) & 0xff,
      v & 0xff,
    ];

List<int> _u64be(int v) {
  final out = List<int>.filled(8, 0);
  var rest = v;
  for (var i = 7; i >= 0; i--) {
    out[i] = rest & 0xff;
    rest >>= 8;
  }
  return out;
}

Uint8List _concat(List<List<int>> parts) {
  final b = BytesBuilder();
  for (final p in parts) {
    b.add(p);
  }
  return b.toBytes();
}

/// One chpl chapter entry: 8-byte start (100ns ticks) + 1-byte title
/// length + title bytes.
List<int> _chplEntry(int startTicks, String title) {
  final titleBytes = utf8.encode(title);
  return [
    ..._u64be(startTicks),
    titleBytes.length,
    ...titleBytes,
  ];
}

/// A version-0 `chpl` atom body: version(1) + flags(3, always 0 here) +
/// chapter_count(1) + entries. This is ffmpeg's own `mov_read_chpl` shape
/// (`libavformat/mov.c`), verified against the real source, not guessed.
Uint8List chplAtom(List<(int startTicks, String title)> chapters) {
  final body = <int>[0, 0, 0, 0, chapters.length];
  for (final (start, title) in chapters) {
    body.addAll(_chplEntry(start, title));
  }
  return _box('chpl', body);
}

/// A moov/udta/chpl tree — the common m4b-tool ("Nero chapters") shape.
Uint8List m4bWithChapters(List<(int startTicks, String title)> chapters) {
  final chpl = chplAtom(chapters);
  final udta = _box('udta', chpl);
  final moov = _box('moov', udta);
  final ftyp = _box('ftyp', ascii.encode('M4B ') + [0, 0, 0, 0]);
  return _concat([ftyp, moov]);
}

/// A well-formed M4B-shaped file with NO chpl anywhere — the honest "no
/// chapters found" case, not a malformed one.
Uint8List m4bWithoutChapters() {
  final udta = _box('udta', const []);
  final moov = _box('moov', udta);
  final ftyp = _box('ftyp', ascii.encode('M4B ') + [0, 0, 0, 0]);
  final mdat = _box('mdat', List.filled(16, 0));
  return _concat([ftyp, moov, mdat]);
}

/// A moov with no udta at all.
Uint8List m4bWithoutUdta() {
  final moov = _box('moov', const []);
  final ftyp = _box('ftyp', ascii.encode('M4B ') + [0, 0, 0, 0]);
  return _concat([ftyp, moov]);
}

/// No moov box anywhere in the buffer — e.g. a bounded read that only ever
/// captured a leading mdat-first file. Must degrade calmly, not throw.
Uint8List noMoovAtAll() => _box('mdat', List.filled(32, 0));

/// A version-1 chpl atom (the extra 4-byte "???" reserved field
/// `mov_read_chpl` reads only when `version != 0`) — proves the parser
/// follows the real reader's branch, not just the common version-0 path.
Uint8List m4bWithVersion1Chpl(List<(int startTicks, String title)> chapters) {
  final body = <int>[1, 0, 0, 0, 0, 0, 0, 0, chapters.length];
  for (final (start, title) in chapters) {
    body.addAll(_chplEntry(start, title));
  }
  final chpl = _box('chpl', body);
  final udta = _box('udta', chpl);
  final moov = _box('moov', udta);
  return moov;
}

/// A chpl atom truncated mid-entry — a corrupt or partially-downloaded
/// file. Must return whatever chapters parsed cleanly before the cut,
/// never throw.
Uint8List m4bWithTruncatedChpl() {
  final goodEntry = _chplEntry(0, 'Chapter One');
  // A second entry's start time only, with the title length/bytes cut off.
  final body = <int>[0, 0, 0, 0, 2, ...goodEntry, ..._u64be(50000000)];
  final chpl = _box('chpl', body);
  final udta = _box('udta', chpl);
  final moov = _box('moov', udta);
  return moov;
}
