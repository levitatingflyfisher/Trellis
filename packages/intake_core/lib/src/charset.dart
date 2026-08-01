/// Response-byte decoding with charset sniffing, ported from ohPrimer
/// `index.html` (`decodeResponseBytes`). The donor JS is the spec.
///
/// The donor leaned on the browser's `TextDecoder`; here only the labels the
/// donor's article path actually met are decodable — the UTF-8 family and the
/// windows-1252 family (which, per the WHATWG encoding standard, includes
/// `ascii`, `us-ascii`, `iso-8859-1`, and `latin1`). Any other label behaves
/// like the donor's failed `TextDecoder` construction: it falls through to
/// the UTF-8-then-windows-1252 heuristic.
library;

import 'dart:convert';

final _metaCharsetRe = RegExp(
  '<meta[^>]+charset\\s*=\\s*["\']?([a-z0-9_-]+)',
  caseSensitive: false,
);
final _xmlEncodingRe = RegExp(
  '<\\?xml[^>]+encoding\\s*=\\s*["\']([a-z0-9_-]+)',
  caseSensitive: false,
);
final _contentTypeCharsetRe = RegExp(
  'charset\\s*=\\s*["\']?([a-z0-9_-]+)',
  caseSensitive: false,
);
final _iso88591Re = RegExp(r'^iso-?8859-?1$', caseSensitive: false);

// WHATWG encoding-standard labels (the subset reachable through the donor's
// `[a-z0-9_-]+` capture) for the two encodings we can decode.
const _utf8Labels = {
  'utf-8',
  'utf8',
  'unicode-1-1-utf-8',
  'unicode11utf8',
  'unicode20utf8',
  'x-unicode20utf8',
};
const _windows1252Labels = {
  'ansi_x3',
  'ascii',
  'cp1252',
  'cp819',
  'csisolatin1',
  'ibm819',
  'iso-8859-1',
  'iso8859-1',
  'iso88591',
  'iso_8859-1',
  'l1',
  'latin1',
  'us-ascii',
  'windows-1252',
  'x-cp1252',
};

// windows-1252 mappings for 0x80–0x9F (elsewhere it matches latin1). The five
// unassigned bytes map to their C1 controls, as the WHATWG standard does.
const _cp1252High = [
  0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
  0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F, //
  0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, //
  0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178, //
];

String _decodeWindows1252(List<int> bytes) {
  final units = List<int>.generate(bytes.length, (i) {
    final b = bytes[i] & 0xFF;
    return (b >= 0x80 && b <= 0x9F) ? _cp1252High[b - 0x80] : b;
  });
  return String.fromCharCodes(units);
}

// Non-fatal UTF-8 decode matching `TextDecoder("utf-8")`: malformed sequences
// become U+FFFD and a leading BOM is stripped.
String _decodeUtf8(List<int> bytes) {
  final s = utf8.decode(bytes, allowMalformed: true);
  return s.startsWith('\uFEFF') ? s.substring(1) : s;
}

/// Decodes response [bytes] using the charset declared in `<meta>`, `<?xml?>`,
/// or the HTTP Content-Type — in that order (donor `decodeResponseBytes`).
/// Falls back to UTF-8, then to windows-1252 if UTF-8 yields many U+FFFD
/// replacement chars (legacy HTML commonly served without charset).
String decodeResponseBytes(List<int> bytes, String? contentType) {
  final head = bytes.length > 4096 ? bytes.sublist(0, 4096) : bytes;
  // Donor sniffs via TextDecoder("ascii", nonfatal); the regexes only match
  // ASCII, so a latin1 view of the head is equivalent.
  final ascii = _decodeWindows1252(head);
  String? charset;
  var m = _metaCharsetRe.firstMatch(ascii);
  if (m != null) charset = m[1];
  if (charset == null) {
    m = _xmlEncodingRe.firstMatch(ascii);
    if (m != null) charset = m[1];
  }
  if (charset == null && contentType != null) {
    m = _contentTypeCharsetRe.firstMatch(contentType);
    if (m != null) charset = m[1];
  }
  if (charset != null && _iso88591Re.hasMatch(charset)) {
    charset = 'windows-1252';
  }
  if (charset != null) {
    final label = charset.toLowerCase();
    if (_utf8Labels.contains(label)) return _decodeUtf8(bytes);
    if (_windows1252Labels.contains(label)) return _decodeWindows1252(bytes);
    // Unknown label: donor's `new TextDecoder(...)` throws → fall through.
  }
  final u8 = _decodeUtf8(bytes);
  final bad = '\uFFFD'.allMatches(u8).length;
  if (bad > 3) return _decodeWindows1252(bytes);
  return u8;
}
