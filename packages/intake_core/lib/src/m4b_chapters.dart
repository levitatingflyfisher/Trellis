/// M4B/M4A chapter atoms (ADR-0013, Campaign 7): a minimal pure-Dart reader
/// over the file's own ISO-BMFF boxes — only ever descends into `moov` and
/// `udta` looking for a `chpl` atom (the "Nero chapters" shape most
/// audiobook tooling, m4b-tool included, writes). This is deliberately NOT
/// a general MP4 parser: every other box (`mdat`, `free`, `trak`, …) is
/// skipped by its declared size, never inspected — the multi-gigabyte
/// audio payload in `mdat` is never touched.
///
/// The `chpl` body layout is verified against ffmpeg's own
/// `mov_read_chpl` (`libavformat/mov.c`), not guessed: version(1) +
/// flags(3) [+ a 4-byte reserved field iff version != 0] + chapter
/// count(1), then per chapter: start time (8 bytes, big-endian, in units
/// of 1/10,000,000 second) + title length(1) + title bytes (UTF-8).
///
/// Every failure mode here is a calm empty (or partial) list, never a
/// throw: a moved/truncated/foreign file degrades to "no chapters found",
/// which the caller treats identically to an MP3 that never had any — one
/// file, one chapter, never a crash.
library;

import 'dart:convert';
import 'dart:typed_data';

/// One parsed chapter: a title and its start offset, in milliseconds,
/// relative to the start of the FILE this was parsed from (never relative
/// to a multi-file audiobook as a whole — that's the caller's fileIdx to
/// add, not this parser's).
class M4bChapter {
  final String title;
  final int startMs;
  const M4bChapter({required this.title, required this.startMs});
}

/// Container box types this reader ever descends into. Everything else is
/// skipped by size, unopened — the whole point of not being a general
/// parser.
const _containerTypes = {'moov', 'udta'};

/// Parses [bytes] (the file's own bytes, or any leading prefix of them —
/// see the app-level caller for why only a bounded prefix is ever read)
/// for a `moov/udta/chpl` chapter list. Returns an empty list for anything
/// that isn't found, is malformed, or was truncated by a bounded read —
/// never throws.
List<M4bChapter> parseM4bChapters(List<int> bytes) {
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  final chpl = _findChpl(data, 0, data.lengthInBytes);
  if (chpl == null) return const [];
  return _readChpl(data, chpl.$1, chpl.$2);
}

/// Walks top-level boxes in `[start, end)` for `moov`, then within it for
/// `udta`, then within that for `chpl` — returns that atom's own
/// `(bodyStart, bodyEnd)` byte range, or null if the chain isn't complete.
(int, int)? _findChpl(ByteData data, int start, int end) {
  for (final box in _walkBoxes(data, start, end)) {
    if (box.fourcc == 'chpl') return (box.bodyStart, box.bodyEnd);
    if (_containerTypes.contains(box.fourcc)) {
      final found = _findChpl(data, box.bodyStart, box.bodyEnd);
      if (found != null) return found;
    }
  }
  return null;
}

class _Box {
  final String fourcc;
  final int bodyStart;
  final int bodyEnd;
  const _Box(this.fourcc, this.bodyStart, this.bodyEnd);
}

/// Yields each box header found in `[start, end)`, computing each body's
/// byte range but never reading it — the caller decides whether to
/// recurse. A box whose declared size runs past [end] (a truncated read,
/// or a genuinely corrupt file) ends the walk quietly rather than
/// throwing or reading out of bounds.
Iterable<_Box> _walkBoxes(ByteData data, int start, int end) sync* {
  var pos = start;
  while (pos + 8 <= end) {
    final declaredSize = data.getUint32(pos, Endian.big);
    final fourcc = _fourccAt(data, pos + 4);
    int headerLen = 8;
    int size = declaredSize;
    if (declaredSize == 1) {
      // A 64-bit extended size follows the fourcc — rare for the small
      // metadata boxes this reader cares about, supported anyway rather
      // than silently mis-walking a file that uses it.
      if (pos + 16 > end) return;
      final hi = data.getUint32(pos + 8, Endian.big);
      final lo = data.getUint32(pos + 12, Endian.big);
      size = (hi << 32) + lo;
      headerLen = 16;
    } else if (declaredSize == 0) {
      // "Extends to the end of the file/buffer" — only ever legal for the
      // LAST box; treat that as this walk's end.
      size = end - pos;
    }
    if (size < headerLen || pos + size > end) return; // truncated: stop
    yield _Box(fourcc, pos + headerLen, pos + size);
    pos += size;
  }
}

String _fourccAt(ByteData data, int offset) {
  final bytes = [
    data.getUint8(offset),
    data.getUint8(offset + 1),
    data.getUint8(offset + 2),
    data.getUint8(offset + 3),
  ];
  return String.fromCharCodes(bytes);
}

/// Reads chapter entries from a `chpl` atom's body `[start, end)`. Stops
/// and returns whatever parsed cleanly the moment a read would run past
/// [end] — a truncated file yields a partial, honest list, never a throw.
List<M4bChapter> _readChpl(ByteData data, int start, int end) {
  var pos = start;
  if (pos + 5 > end) return const [];
  final version = data.getUint8(pos);
  pos += 4; // version(1) + flags(3)
  if (version != 0) {
    if (pos + 4 > end) return const [];
    pos += 4; // the reserved field mov_read_chpl calls "???"
  }
  if (pos + 1 > end) return const [];
  final count = data.getUint8(pos);
  pos += 1;
  final chapters = <M4bChapter>[];
  for (var i = 0; i < count; i++) {
    if (pos + 9 > end) break; // 8-byte start + 1-byte title length
    final startTicks = data.getUint64(pos, Endian.big);
    final titleLen = data.getUint8(pos + 8);
    pos += 9;
    if (pos + titleLen > end) break;
    final titleBytes = Uint8List.sublistView(data, pos, pos + titleLen);
    final title = utf8.decode(titleBytes, allowMalformed: true);
    pos += titleLen;
    // 1/10,000,000s ticks (QuickTime's absolute time base) -> ms.
    chapters.add(M4bChapter(title: title, startMs: startTicks ~/ 10000));
  }
  return chapters;
}
