import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:stardict_core/stardict_core.dart';
import 'package:test/test.dart';

/// End-to-end: a tiny synthetic StarDict set (.ifo + .idx + a real
/// dictzip .dict.dz), proving binary-search exact/case-insensitive/prefix
/// lookup against the actual parsed structures — no mocks.
void main() {
  Uint8List be16(int v) =>
      Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little);

  Uint8List buildDictzip(List<String> chunks, int chunkLen) {
    final compressed =
        [for (final c in chunks) Deflate(utf8.encode(c)).getBytes()];
    final extra = BytesBuilder()
      ..add(be16(1))
      ..add(be16(chunkLen))
      ..add(be16(compressed.length));
    for (final c in compressed) {
      extra.add(be16(c.length));
    }
    final extraBytes = extra.toBytes();
    final subfield = BytesBuilder()
      ..addByte(0x52)
      ..addByte(0x41)
      ..add(be16(extraBytes.length))
      ..add(extraBytes);
    final header = BytesBuilder()
      ..addByte(0x1f)
      ..addByte(0x8b)
      ..addByte(0x08)
      ..addByte(0x04)
      ..add([0, 0, 0, 0])
      ..addByte(0x00)
      ..addByte(0x03)
      ..add(be16(subfield.length))
      ..add(subfield.toBytes());
    final out = BytesBuilder()..add(header.toBytes());
    for (final c in compressed) {
      out.add(c);
    }
    return out.toBytes();
  }

  /// A tiny dictionary: words (already in on-disk StarDict sort order —
  /// this fixture's own order, not case-normalized) each mapping to a
  /// short "definition" body, all packed into ONE dictzip chunk (small
  /// enough that chunking doesn't matter for these lookup tests — the
  /// dictzip mechanics are already proven in dictzip_test.dart).
  ({StarDictIfo ifo, List<StarDictIndexEntry> entries, DictzipBody body})
      buildFixture() {
    final defs = {
      'Apple': 'a fruit',
      'apple': 'lowercase fruit too',
      'apply': 'to put to use',
      'banana': 'a yellow fruit',
      'band': 'a musical group',
      'bandage': 'a wound covering',
    };
    final words = defs.keys.toList(); // fixture's own on-disk order
    final body = StringBuffer();
    final entries = <StarDictIndexEntry>[];
    for (final w in words) {
      final def = defs[w]!;
      final bytes = utf8.encode(def);
      entries.add(StarDictIndexEntry(
          word: w, offset: utf8.encode(body.toString()).length, length: bytes.length));
      body.write(def);
    }
    final wholeBody = body.toString();
    final dictz = buildDictzip([wholeBody], utf8.encode(wholeBody).length);
    const ifoRaw = '''
StarDict's dict ifo file
version=3.0.0
bookname=Fixture
wordcount=6
idxfilesize=1
sametypesequence=m
''';
    return (
      ifo: StarDictIfo.parse(ifoRaw),
      entries: entries,
      body: DictzipBody(dictz),
    );
  }

  group('StarDictDictionary lookup', () {
    test('exact lookup is case-sensitive and finds the right entry',
        () {
      final f = buildFixture();
      final dict = StarDictDictionary(entries: f.entries, body: f.body);
      final m = dict.lookup('Apple');
      expect(m, isNotNull);
      expect(m!.kind, StarDictMatchKind.exact);
      expect(dict.definitionOf(m.entry), 'a fruit');
    });

    test('a differently-cased exact miss falls back to case-insensitive',
        () {
      final f = buildFixture();
      final dict = StarDictDictionary(entries: f.entries, body: f.body);
      // 'BANANA' isn't in the fixture verbatim; 'banana' is.
      final m = dict.lookup('BANANA');
      expect(m, isNotNull);
      expect(m!.kind, StarDictMatchKind.caseInsensitive);
      expect(m.entry.word, 'banana');
      expect(dict.definitionOf(m.entry), 'a yellow fruit');
    });

    test('no exact/case-insensitive match falls back to the first prefix hit',
        () {
      final f = buildFixture();
      final dict = StarDictDictionary(entries: f.entries, body: f.body);
      // 'ban' is nobody's exact word, but it's a real prefix of banana/
      // band/bandage -- 'banana' sorts first among the three.
      final m = dict.lookup('ban');
      expect(m, isNotNull);
      expect(m!.kind, StarDictMatchKind.prefix);
      expect(m.entry.word, 'banana');
    });

    test('a word with no match at all (not even a prefix) returns null', () {
      final f = buildFixture();
      final dict = StarDictDictionary(entries: f.entries, body: f.body);
      expect(dict.lookup('zzzznothing'), isNull);
    });

    test('prefixMatches returns every case-insensitive prefix hit, sorted',
        () {
      final f = buildFixture();
      final dict = StarDictDictionary(entries: f.entries, body: f.body);
      final hits = dict.prefixMatches('ban').map((e) => e.word).toList();
      expect(hits, ['banana', 'band', 'bandage']);
    });

    test('prefixMatches respects its limit', () {
      final f = buildFixture();
      final dict = StarDictDictionary(entries: f.entries, body: f.body);
      expect(dict.prefixMatches('ban', limit: 2), hasLength(2));
    });

    test('definitionOf reads through the dictzip body via the entry\'s '
        'offset/length, not a whole-file decode', () {
      final f = buildFixture();
      final dict = StarDictDictionary(entries: f.entries, body: f.body);
      expect(dict.definitionOf(f.entries.firstWhere((e) => e.word == 'apply')),
          'to put to use');
    });
  });
}
