import 'package:stardict_core/stardict_core.dart';
import 'package:test/test.dart';

/// StarDict's .ifo metadata file: `key=value` lines, a fixed first line
/// ("StarDict's dict ifo file"), and a handful of keys this door reads.
void main() {
  group('StarDictIfo.parse', () {
    test('reads the fields this door needs off a real-shaped .ifo', () {
      const raw = '''
StarDict's dict ifo file
version=3.0.0
bookname=English-English Wiktionary dictionary (en-en)
wordcount=462079
idxfilesize=8741097
sametypesequence=h
synwordcount=394031
author=Vuizur
description=
''';
      final ifo = StarDictIfo.parse(raw);
      expect(ifo.version, '3.0.0');
      expect(ifo.bookname, 'English-English Wiktionary dictionary (en-en)');
      expect(ifo.wordCount, 462079);
      expect(ifo.idxFileSize, 8741097);
      expect(ifo.sameTypeSequence, 'h');
    });

    test('sametypesequence and idxoffsetbits are optional', () {
      const raw = '''
StarDict's dict ifo file
version=2.4.2
bookname=Tiny
wordcount=3
idxfilesize=42
''';
      final ifo = StarDictIfo.parse(raw);
      expect(ifo.sameTypeSequence, isNull);
      expect(ifo.idxOffsetBits, 32,
          reason: 'the StarDict default when the key is absent');
    });

    test('idxoffsetbits=64 is read when present (large dictionaries)', () {
      const raw = '''
StarDict's dict ifo file
version=3.0.0
bookname=Huge
wordcount=9
idxfilesize=99
idxoffsetbits=64
''';
      expect(StarDictIfo.parse(raw).idxOffsetBits, 64);
    });

    test('rejects a file missing the StarDict signature line', () {
      expect(() => StarDictIfo.parse('version=3.0.0\nbookname=x\n'),
          throwsFormatException);
    });

    test('rejects a file missing a required key', () {
      expect(
          () => StarDictIfo.parse(
              "StarDict's dict ifo file\nversion=3.0.0\nbookname=x\n"),
          throwsFormatException);
    });
  });
}
