/// Show notes as a feed sends them are someone else's HTML: scripts,
/// trackers, forms and styles ride along with the text. Before the app
/// stores a byte of it, this keeps an allowlist (links, lists,
/// paragraphs, bold, italic, line breaks) and drops the rest. An image
/// becomes its alt text, so opening notes never fetches anything.
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// Removed with everything inside them.
const _dropped = {
  'script', 'style', 'iframe', 'form', 'object', 'embed', 'noscript',
  'template', 'svg', 'math', 'head', 'title', 'button', 'input', 'select',
  'textarea', 'video', 'audio', 'canvas', 'map', 'frame', 'frameset', //
  'link', 'meta', 'base',
};

/// Kept as themselves, with no attributes (bar `href` on a link).
const _kept = {
  'a', 'p', 'br', 'ul', 'ol', 'li', 'b', 'strong', 'i', 'em', //
  'blockquote',
};

const _headings = {'h1', 'h2', 'h3', 'h4', 'h5', 'h6'};

/// Hosts whose images exist only to count a reader. A short list of the
/// common ones; the 1x1 rule catches most of the rest.
const _beaconHosts = [
  'google-analytics.com', 'doubleclick.net', 'feeds.feedburner.com',
  'pixel.wp.com', 'stats.wp.com', 'mc.yandex.ru', 'pixel.quantserve.com',
  'sb.scorecardresearch.com', 'facebook.com', 'chartable.com', //
  'podtrac.com', 'list-manage.com',
];

bool _beacon(dom.Element img) {
  final w = img.attributes['width']?.trim();
  final h = img.attributes['height']?.trim();
  if ((w == '1' || w == '0') && (h == '1' || h == '0')) return true;
  final host = Uri.tryParse(img.attributes['src']?.trim() ?? '')?.host ?? '';
  return _beaconHosts
      .any((b) => host == b || host.endsWith('.$b'));
}

String? _safeHref(String? raw) {
  final href = raw?.trim();
  if (href == null || href.isEmpty) return null;
  final uri = Uri.tryParse(href);
  if (uri == null) return null;
  return switch (uri.scheme.toLowerCase()) {
    // `https:evil.test` parses with an empty host: the confirm sheet
    // could not name where it goes.
    'http' || 'https' => uri.host.isEmpty ? null : href,
    'mailto' => href,
    _ => null,
  };
}

String _escapeText(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String _escapeAttr(String s) => _escapeText(s).replaceAll('"', '&quot;');

void _write(dom.Node node, StringBuffer out) {
  if (node is dom.Text) {
    out.write(_escapeText(node.text));
    return;
  }
  if (node is! dom.Element) {
    // Comments, doctypes: nothing a reader should see.
    if (node is dom.DocumentFragment || node is dom.Document) {
      for (final c in node.nodes) {
        _write(c, out);
      }
    }
    return;
  }
  final tag = node.localName?.toLowerCase() ?? '';
  if (_dropped.contains(tag)) return;
  if (tag == 'img') {
    if (_beacon(node)) return;
    final alt = node.attributes['alt']?.trim() ?? '';
    if (alt.isNotEmpty) out.write(_escapeText('[Image: $alt]'));
    return;
  }
  if (_headings.contains(tag)) {
    out.write('<p><strong>');
    for (final c in node.nodes) {
      _write(c, out);
    }
    out.write('</strong></p>');
    return;
  }
  if (!_kept.contains(tag)) {
    for (final c in node.nodes) {
      _write(c, out);
    }
    return;
  }
  if (tag == 'br') {
    out.write('<br>');
    return;
  }
  final inner = StringBuffer();
  for (final c in node.nodes) {
    _write(c, inner);
  }
  final body = inner.toString();
  // A wrapper left empty (its pixel dropped) is clutter, not structure.
  if (body.replaceAll(_tagOnly, '').trim().isEmpty) return;
  if (tag == 'a') {
    final href = _safeHref(node.attributes['href']);
    if (href == null) {
      out.write(body);
      return;
    }
    out.write('<a href="${_escapeAttr(href)}">$body</a>');
  } else {
    out.write('<$tag>$body</$tag>');
  }
}

final _tagOnly = RegExp(r'<[^>]*>');

/// [html] cut down to the allowlist, escaped and ready to store. Null when
/// nothing readable is left.
String? sanitizeNotesHtml(String html) {
  if (html.trim().isEmpty) return null;
  final fragment = html_parser.parseFragment(html);
  final out = StringBuffer();
  for (final n in fragment.nodes) {
    _write(n, out);
  }
  final result = out.toString().trim();
  if (result.isEmpty) return null;
  // Markup with no text in it (an empty <p>) is still nothing to read.
  if (notesPlainText(result).isEmpty) return null;
  return result;
}

const _blocks = {'p', 'li', 'blockquote', 'ul', 'ol', 'div'};

/// The words of sanitized notes, one block per line: what search indexes,
/// so markup never matches a query.
String notesPlainText(String html) {
  final fragment = html_parser.parseFragment(html);
  final out = StringBuffer();
  void walk(dom.Node n) {
    if (n is dom.Text) {
      out.write(n.text);
      return;
    }
    if (n is! dom.Element) return;
    final tag = n.localName?.toLowerCase() ?? '';
    if (tag == 'br') {
      out.write('\n');
      return;
    }
    final block = _blocks.contains(tag);
    if (block) out.write('\n');
    for (final c in n.nodes) {
      walk(c);
    }
    if (block) out.write('\n');
  }

  for (final n in fragment.nodes) {
    walk(n);
  }
  return out
      .toString()
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((l) => l.isNotEmpty)
      .join('\n');
}
