/// Charset-sniffing byte decoding (donor 00-utils.js `decodeResponseBytes`).
///
/// Sniff order (donor law): `<meta charset>` in the first 4096 bytes →
/// `<?xml encoding>` → Content-Type charset. ISO-8859-1 is promoted to
/// windows-1252 (the WHATWG behaviour the donor got from TextDecoder).
/// With no usable label: decode utf-8 with replacement; more than 3
/// replacement characters means mojibake, retry as windows-1252.
///
/// Deviation from the donor: TextDecoder supports the full WHATWG encoding
/// registry; pure Dart ships utf-8 and latin-1 only, so this port decodes
/// utf-8 / us-ascii / iso-8859-1 / windows-1252 and lets every other label
/// fall through to the utf-8 default path (the donor's try/catch did the
/// same for labels TextDecoder rejected).
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

String decodeResponseBytes(Uint8List bytes, String contentType) {
  final head = latin1.decode(bytes.sublist(0, min(4096, bytes.length)));
  String? charset;
  var m = RegExp('<meta[^>]+charset\\s*=\\s*["\']?([a-z0-9_-]+)',
          caseSensitive: false)
      .firstMatch(head);
  if (m != null) charset = m.group(1);
  if (charset == null) {
    m = RegExp('<\\?xml[^>]+encoding\\s*=\\s*["\']([a-z0-9_-]+)',
            caseSensitive: false)
        .firstMatch(head);
    if (m != null) charset = m.group(1);
  }
  if (charset == null && contentType.isNotEmpty) {
    m = RegExp('charset\\s*=\\s*["\']?([a-z0-9_-]+)', caseSensitive: false)
        .firstMatch(contentType);
    if (m != null) charset = m.group(1);
  }
  if (charset != null &&
      RegExp(r'^iso-?8859-?1$', caseSensitive: false).hasMatch(charset)) {
    charset = 'windows-1252';
  }
  if (charset != null) {
    final decoded = _decodeByLabel(bytes, charset.toLowerCase());
    if (decoded != null) return decoded;
  }
  final u8 = utf8.decode(bytes, allowMalformed: true);
  final bad = '\uFFFD'.allMatches(u8).length;
  if (bad > 3) return _decodeWindows1252(bytes);
  return u8;
}

String? _decodeByLabel(Uint8List bytes, String label) {
  switch (label) {
    case 'utf-8':
    case 'utf8':
      return utf8.decode(bytes, allowMalformed: true);
    case 'windows-1252':
    case 'cp1252':
    case 'x-cp1252':
    case 'ascii':
    case 'us-ascii':
    case 'latin1':
    case 'l1':
      // WHATWG maps all of these labels to windows-1252.
      return _decodeWindows1252(bytes);
    default:
      return null; // unknown label → donor's try/catch fell through too
  }
}

/// windows-1252: latin-1 except 0x80–0x9F, which map to these code points.
const List<int> _cp1252High = [
  0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
  0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F, //
  0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, //
  0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178, //
];

String _decodeWindows1252(Uint8List bytes) {
  final codes = List<int>.generate(bytes.length, (i) {
    final b = bytes[i];
    return (b >= 0x80 && b <= 0x9F) ? _cp1252High[b - 0x80] : b;
  });
  return String.fromCharCodes(codes);
}
