/// decodeResponseBytes port (donor 00-utils.js) — charset sniffing order
/// (meta → xml decl → content-type), the ISO-8859-1→windows-1252 promotion,
/// and the mojibake heuristic (>3 U+FFFD → retry as windows-1252).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:comms_core/comms_core.dart';
import 'package:test/test.dart';

Uint8List latin1Of(String s) => Uint8List.fromList(latin1.encode(s));

void main() {
  test('plain utf-8 with no charset info', () {
    expect(decodeResponseBytes(Uint8List.fromList(utf8.encode('héllo — ok')), ''),
        'héllo — ok');
  });

  test('content-type charset drives decoding', () {
    expect(
        decodeResponseBytes(
            latin1Of('café'), 'text/html; charset=iso-8859-1'),
        'café');
  });

  test('iso-8859-1 is promoted to windows-1252 (donor law)', () {
    // 0x93/0x94 are curly quotes in cp1252 but C1 controls in real 8859-1.
    final bytes = Uint8List.fromList([0x93, 0x68, 0x69, 0x94]);
    expect(decodeResponseBytes(bytes, 'text/html; charset=ISO-8859-1'),
        '“hi”');
  });

  test('meta charset in the body wins over content-type', () {
    final body = '<html><meta charset="utf-8"><body>café</body>';
    expect(
        decodeResponseBytes(Uint8List.fromList(utf8.encode(body)),
            'text/html; charset=iso-8859-1'),
        body);
  });

  test('xml encoding declaration is honoured', () {
    final xmlLatin =
        latin1Of('<?xml version="1.0" encoding="ISO-8859-1"?><a>café</a>');
    expect(decodeResponseBytes(xmlLatin, ''),
        '<?xml version="1.0" encoding="ISO-8859-1"?><a>café</a>');
  });

  test('unknown charset label falls through to utf-8', () {
    expect(
        decodeResponseBytes(Uint8List.fromList(utf8.encode('café')),
            'text/html; charset=klingon'),
        'café');
  });

  test('>3 replacement chars retries as windows-1252', () {
    // 0xFF is never a valid utf-8 byte; in cp1252 it is ÿ.
    final bytes = Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
    expect(decodeResponseBytes(bytes, ''), 'ÿÿÿÿÿ');
  });

  test('<=3 replacement chars stays utf-8', () {
    final bytes = Uint8List.fromList([0x61, 0xFF, 0x62]); // a <bad> b
    expect(decodeResponseBytes(bytes, ''), 'a�b');
  });
}
