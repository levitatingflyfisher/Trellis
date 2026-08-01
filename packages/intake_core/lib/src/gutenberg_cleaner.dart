/// Project Gutenberg plain-text cleanup, ported from ohPrimer `index.html`
/// (`stripGutenbergBoilerplate`, `gutPickTextUrl`). The donor JS is the spec.
library;

final _startMarkerRe = RegExp(
  r'\*\*\*\s*START OF[^\n]*\*\*\*[^\n]*\n',
  caseSensitive: false,
);
final _endMarkerRe = RegExp(
  r'\n\*\*\*\s*END OF[^\n]*\*\*\*',
  caseSensitive: false,
);
// Liberal fallbacks (older PG files vary the shape): a line that begins with
// two-or-more asterisks and START/END OF, closing *** not required, leading
// indentation tolerated. Tried only when the canonical markers above miss —
// the donor-verbatim behaviour stays authoritative when both would match.
final _startLineRe = RegExp(
  r'^[ \t]*\*{2,}\s*START OF[^\n]*$',
  caseSensitive: false,
  multiLine: true,
);
final _endLineRe = RegExp(
  r'^[ \t]*\*{2,}\s*END OF[^\n]*$',
  caseSensitive: false,
  multiLine: true,
);
// Single newline between two non-newline chars → the wrap point of
// Gutenberg's ~72-column prose. Blank lines (paragraph breaks) don't match.
final _wrapRe = RegExp(r'([^\n])\n(?!\n)(?=[^\n])');

/// Strips the Project Gutenberg license boilerplate and unwraps the
/// ~72-column prose wrap (donor `stripGutenbergBoilerplate`).
///
/// Everything through the `*** START OF ... ***` line goes; everything from
/// the `*** END OF ... ***` marker on goes; then single newlines between
/// prose lines become spaces while blank lines stay.
String stripGutenbergBoilerplate(String text) {
  var out = text;
  final startMatch =
      _startMarkerRe.firstMatch(out) ?? _startLineRe.firstMatch(out);
  if (startMatch != null) out = out.substring(startMatch.end);
  final endMatch = _endMarkerRe.firstMatch(out) ?? _endLineRe.firstMatch(out);
  if (endMatch != null) out = out.substring(0, endMatch.start);
  out = out.replaceAllMapped(_wrapRe, (m) => '${m[1]} ');
  return out.trim();
}

/// Picks the best plain-text URL from a Gutendex `formats` map
/// (donor `gutPickTextUrl`): utf-8, then us-ascii, then bare `text/plain`,
/// then any `text/plain`-prefixed key. Null when none exists.
String? pickGutenbergTextUrl(Map<String, String> formats) {
  const pref = [
    'text/plain; charset=utf-8',
    'text/plain; charset=us-ascii',
    'text/plain',
  ];
  for (final p in pref) {
    final u = formats[p];
    if (u != null) return u;
  }
  for (final k in formats.keys) {
    if (k.startsWith('text/plain')) {
      final u = formats[k];
      // Donor `...[0]||null`: an empty string is falsy → null.
      return (u == null || u.isEmpty) ? null : u;
    }
  }
  return null;
}
