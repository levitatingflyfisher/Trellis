/// Readability-style article extraction, ported from ohPrimer `index.html`
/// (`extractArticle`, `scoreNode`, and the feed sniff in `loadUrl`). The
/// donor JS is the spec, scoring heuristics and quirks included.
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'blocks.dart';

/// The extracted article: title, optional byline, prose blocks, and the
/// joined text exactly as the donor returned it (`parts.join("\n\n")`).
class ArticleResult {
  final String title;

  /// From `meta[name=author]` — an intake_core addition; the donor never
  /// extracted a byline.
  final String? byline;

  /// One [TextBlock] per extracted part, in document order.
  final List<IntakeBlock> blocks;

  /// Donor return shape: the parts joined with blank lines.
  final String text;

  /// True when the input looks like an RSS/Atom feed (donor `loadUrl`
  /// detection) — offer a subscribe flow instead of reading raw XML. When
  /// set, [blocks] and [text] are empty.
  final bool isFeedXml;

  /// The base URL the caller fetched from, echoed back for attribution.
  final String? url;

  const ArticleResult({
    required this.title,
    this.byline,
    required this.blocks,
    required this.text,
    this.isFeedXml = false,
    this.url,
  });
}

final _feedRe = RegExp(r'^<\?xml|^<rss(\s|>)|^<feed(\s|>)');
final _wsRe = RegExp(r'\s+');
const _noiseTags = {
  'script', 'style', 'nav', 'aside', 'noscript', 'iframe', 'svg', 'form', //
  'header', 'footer',
};
const _partTags = {
  'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li', 'blockquote', 'pre', //
};

/// All descendant elements of [node] in tree (document) order.
Iterable<dom.Element> _descendants(dom.Node node) sync* {
  for (final child in node.nodes) {
    if (child is dom.Element) {
      yield child;
      yield* _descendants(child);
    } else {
      yield* _descendants(child);
    }
  }
}

dom.Element? _first(dom.Node root, bool Function(dom.Element) test) {
  for (final el in _descendants(root)) {
    if (test(el)) return el;
  }
  return null;
}

/// Donor `scoreNode`: the summed length of every descendant `<p>`'s trimmed
/// text that is longer than 40 chars.
int _scoreNode(dom.Element? el) {
  if (el == null) return 0;
  var score = 0;
  for (final p in _descendants(el)) {
    if (p.localName != 'p') continue;
    final t = p.text.trim();
    if (t.length > 40) score += t.length;
  }
  return score;
}

/// Extracts the readable article from an HTML page (donor `extractArticle`).
///
/// [baseUrl] is the URL the caller fetched [html] from; the donor resolved
/// nothing against it and neither does this port — it is echoed back on
/// [ArticleResult.url] for attribution.
///
/// The donor's caller (`loadUrl`) additionally rejected results whose text
/// was shorter than 200 chars — that check stays with the integrator.
ArticleResult extractArticle(String html, {String? baseUrl}) {
  // Feed sniff (donor loadUrl): RSS/Atom means "subscribe", not "read".
  if (_feedRe.hasMatch(html.trimLeft())) {
    return ArticleResult(
        title: '', blocks: const [], text: '', isFeedXml: true, url: baseUrl);
  }

  final d = html_parser.parse(html);
  final dom.Node root0 = d.documentElement ?? d;

  // Title: og:title || <title> || "Article" — JS `||` skips only *empty*
  // candidates, so a whitespace-only og:title wins and then trims to ''.
  final og = _first(
      root0,
      (el) =>
          el.localName == 'meta' && el.attributes['property'] == 'og:title');
  final titleEl = _first(root0, (el) => el.localName == 'title');
  var title = og?.attributes['content'] ?? '';
  if (title.isEmpty) title = titleEl?.text ?? '';
  if (title.isEmpty) title = 'Article';
  title = title.trim();

  // Byline — intake_core addition (the donor had none).
  final authorMeta = _first(root0,
      (el) => el.localName == 'meta' && el.attributes['name'] == 'author');
  final byline0 = authorMeta?.attributes['content']?.trim();
  final byline = (byline0 == null || byline0.isEmpty) ? null : byline0;

  // Strip noise (donor selector list, incl. [role=navigation] and
  // [aria-hidden=true]).
  final noise = _descendants(root0)
      .where((el) =>
          _noiseTags.contains(el.localName) ||
          el.attributes['role'] == 'navigation' ||
          el.attributes['aria-hidden'] == 'true')
      .toList();
  for (final el in noise) {
    if (el.parentNode != null) el.remove();
  }

  // Prefer <article>, <main>, [role=main], else body; then let any
  // article/main/section/div with a higher paragraph score take over.
  final body = d.body ?? d.documentElement ?? dom.Element.tag('body');
  var root = _first(root0, (el) => el.localName == 'article') ??
      _first(root0, (el) => el.localName == 'main') ??
      _first(root0, (el) => el.attributes['role'] == 'main') ??
      body;
  var best = root;
  var bestLen = _scoreNode(root);
  for (final c in _descendants(root0).where((el) =>
      el.localName == 'article' ||
      el.localName == 'main' ||
      el.localName == 'section' ||
      el.localName == 'div')) {
    final s = _scoreNode(c);
    if (s > bestLen) {
      best = c;
      bestLen = s;
    }
  }
  root = best;

  // Extract text preserving paragraph breaks. Nested matches duplicate their
  // text (a li and its child p both emit) — donor behavior, kept.
  final parts = <String>[];
  for (final el in _descendants(root)) {
    if (!_partTags.contains(el.localName)) continue;
    final t = el.text.replaceAll(_wsRe, ' ').trim();
    if (t.length > 20) parts.add(t);
  }
  if (parts.isEmpty) {
    final t = root.text.replaceAll(_wsRe, ' ').trim();
    if (t.isNotEmpty) parts.add(t);
  }

  return ArticleResult(
    title: title,
    byline: byline,
    blocks: [for (final p in parts) TextBlock(p)],
    text: parts.join('\n\n'),
    url: baseUrl,
  );
}
