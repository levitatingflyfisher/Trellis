/// OPML import/export (donor index.html ~7903). Pure functions — the
/// donor's per-outline fetch-and-validate loop and its toasts stay in the
/// app layer; this file owns the interchange format.
library;

import 'package:xml/xml.dart';

import 'exceptions.dart';
import 'http_date.dart';
import 'limits.dart';

/// One feed subscription in an OPML document.
class OpmlOutline {
  const OpmlOutline({required this.url, required this.title});

  /// The outline's xmlUrl.
  final String url;
  final String title;

  @override
  bool operator ==(Object other) =>
      other is OpmlOutline && other.url == url && other.title == title;

  @override
  int get hashCode => Object.hash(url, title);

  @override
  String toString() => 'OpmlOutline($url, $title)';
}

/// Donor `esc`: the five XML special characters.
String escapeXml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

/// Donor exportOpml, minus the DOM download plumbing. Emits the exact
/// document shape, title falling back to the URL.
String exportOpml(
  List<OpmlOutline> feeds, {
  String profileName = '',
  DateTime? now,
}) {
  final items = feeds.map((f) {
    final t = escapeXml(f.title.isNotEmpty ? f.title : f.url);
    return '    <outline type="rss" text="$t" title="$t" '
        'xmlUrl="${escapeXml(f.url)}" />';
  }).join('\n');
  return '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<opml version="2.0">\n'
      '  <head>\n'
      '    <title>Trellis subscriptions — ${escapeXml(profileName)}</title>\n'
      '    <dateCreated>${formatHttpDate(now ?? DateTime.now())}</dateCreated>\n'
      '  </head>\n'
      '  <body>\n'
      '$items\n'
      '  </body>\n'
      '</opml>\n';
}

/// Donor importOpml's parse phase: outlines carrying an `xmlUrl` attribute,
/// title precedence title → text → url with JS || semantics (empty strings
/// skipped). Returns an empty list when no feed outlines exist — the
/// donor's "No feed URLs found" toast is the caller's.
///
/// Deliberate donor deviation: `xmlUrl` matches case-insensitively on read
/// (real exporters disagree on the casing; the donor's case-sensitive
/// `querySelectorAll("outline[xmlUrl]")` silently dropped their feeds).
/// [exportOpml] still emits the canonical `xmlUrl`.
///
/// Throws [OpmlParseException] on oversized or invalid input.
List<OpmlOutline> parseOpml(String text) {
  if (text.length > maxXmlBytes) {
    throw const OpmlParseException('OPML file is too large');
  }
  XmlDocument doc;
  try {
    doc = XmlDocument.parse(text);
  } catch (_) {
    throw const OpmlParseException('Invalid OPML file');
  }
  final out = <OpmlOutline>[];
  for (final o
      in doc.descendantElements.where((e) => e.name.local == 'outline')) {
    final url = o.attributes
        .where((a) => a.name.local.toLowerCase() == 'xmlurl')
        .map((a) => a.value)
        .firstOrNull;
    // Donor: outlines with an empty/missing url are skipped in the loop.
    if (url == null || url.isEmpty) continue;
    var title = o.getAttribute('title') ?? '';
    if (title.isEmpty) title = o.getAttribute('text') ?? '';
    if (title.isEmpty) title = url;
    out.add(OpmlOutline(url: url, title: title));
  }
  return out;
}
