// Port tests for donor `decodeResponseBytes` (ohPrimer index.html ~3535):
// charset sniffed from <meta>, <?xml?>, or Content-Type; iso-8859-1 aliased
// to windows-1252; UTF-8 fallback that retries as windows-1252 when it
// yields many U+FFFD replacement chars.
import 'dart:convert';

import 'package:intake_core/intake_core.dart';
import 'package:test/test.dart';

void main() {
  group('decodeResponseBytes (donor decodeResponseBytes)', () {
    test('honors <meta charset=...> declaration', () {
      // 0x93/0x94 are curly quotes in windows-1252, invalid alone in UTF-8.
      final bytes = [
        ...latin1.encode('<html><meta charset="windows-1252"><body>'),
        0x93,
        ...latin1.encode('hi'),
        0x94,
      ];
      expect(decodeResponseBytes(bytes, null), contains('“hi”'));
    });

    test('honors <?xml encoding=...?> declaration', () {
      final bytes = [
        ...latin1.encode('<?xml version="1.0" encoding="iso-8859-1"?><r>'),
        0xE9, // é in latin1/cp1252
        ...latin1.encode('</r>'),
      ];
      expect(decodeResponseBytes(bytes, null), contains('é'));
    });

    test('iso-8859-1 is aliased to windows-1252 (0x93 → curly quote)', () {
      final bytes = [
        ...latin1.encode('<?xml version="1.0" encoding="ISO-8859-1"?><r>'),
        0x93,
        ...latin1.encode('</r>'),
      ];
      // Under real latin1 0x93 is a C1 control; cp1252 gives U+201C.
      expect(decodeResponseBytes(bytes, null), contains('“'));
    });

    test('falls back to Content-Type charset param', () {
      final bytes = [
        ...latin1.encode('<html><body>caf'),
        0xE9,
      ];
      expect(decodeResponseBytes(bytes, 'text/html; charset=windows-1252'),
          contains('café'));
    });

    test('in-document meta wins over Content-Type (donor sniff order)', () {
      final bytes = [
        ...latin1.encode('<meta charset="utf-8"><body>ok'),
      ];
      // Content-Type lies; meta says utf-8 and the bytes are valid UTF-8.
      expect(decodeResponseBytes(bytes, 'text/html; charset=windows-1252'),
          contains('ok'));
    });

    test('unknown charset label falls through to UTF-8', () {
      final bytes = utf8.encode('<meta charset="klingon-8"><body>héllo');
      expect(decodeResponseBytes(bytes, null), contains('héllo'));
    });

    test('undeclared valid UTF-8 decodes as UTF-8', () {
      expect(decodeResponseBytes(utf8.encode('naïve — text'), null),
          'naïve — text');
    });

    test('undeclared bytes with >3 UTF-8 errors retry as windows-1252', () {
      final bytes = [
        ...latin1.encode('<html><body>'),
        0x93, 0x93, 0x93, 0x93, // four U+FFFD under UTF-8 → retry
        ...latin1.encode('quoted'),
      ];
      expect(decodeResponseBytes(bytes, null), contains('“' * 4));
    });

    test('3 or fewer UTF-8 errors keep the UTF-8 decode (donor bad>3)', () {
      final bytes = [
        ...latin1.encode('<html><body>x'),
        0x93, 0x93, 0x93,
      ];
      final out = decodeResponseBytes(bytes, null);
      expect(out, contains('�'));
      expect(out, isNot(contains('“')));
    });

    test('leading UTF-8 BOM is stripped (TextDecoder behavior)', () {
      final bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode('hello')];
      expect(decodeResponseBytes(bytes, null), 'hello');
    });
  });
}
