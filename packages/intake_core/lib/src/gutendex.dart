/// Gutendex — the Project Gutenberg catalogue API (gutendex.com).
///
/// Pure logic only: build the search URL, map the JSON page, and turn a
/// fetched book (plain text or html edition) into clean paragraphs. No HTTP
/// happens here — the caller fetches through its own guarded seam and every
/// URL this file *returns* (search, next page, book file) must be re-checked
/// with comms_core's `assertSafeFetchUrl` before it is fetched: they come
/// off the wire, not from this package.
library;

import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'gutenberg_cleaner.dart';

/// One catalogue entry, mapped down to exactly what the search UI shows and
/// the importer needs.
class GutendexBook {
  final int id;
  final String title;

  /// Author names as Gutendex gives them ("Austen, Jane").
  final List<String> authors;
  final List<String> languages;
  final int downloadCount;

  /// Best plain-text edition URL (via [pickGutenbergTextUrl]), if any.
  final String? textUrl;

  /// Best html edition URL, if any — the fallback when no plain text exists.
  final String? htmlUrl;

  const GutendexBook({
    required this.id,
    required this.title,
    required this.authors,
    required this.languages,
    required this.downloadCount,
    this.textUrl,
    this.htmlUrl,
  });

  /// The URL an import should fetch: plain text wins, html is the fallback,
  /// null means this book has no readable edition.
  String? get importUrl => textUrl ?? htmlUrl;

  /// True when [importUrl] is the html edition (run it through the html →
  /// text path before the boilerplate strip).
  bool get importIsHtml => textUrl == null && htmlUrl != null;
}

/// One page of search results: Gutendex paginates at 32 books per page and
/// hands back an absolute `next` URL (null on the last page).
class GutendexPage {
  final int count;
  final String? nextUrl;
  final List<GutendexBook> books;
  const GutendexPage(
      {required this.count, required this.nextUrl, required this.books});
}

/// `https://gutendex.com/books?search=<query>` — Gutendex matches the words
/// against titles and author names, which covers the by-title and by-author
/// cases with one box.
Uri buildGutendexSearchUrl(String query) =>
    Uri.https('gutendex.com', '/books', {'search': query});

/// Maps one Gutendex response page. Throws [FormatException] when the body
/// is not JSON or not shaped like a Gutendex page — the caller turns that
/// into a calm sentence.
GutendexPage parseGutendexPage(String body) {
  final Object? decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic> || decoded['results'] is! List) {
    throw const FormatException('Not a Gutendex results page.');
  }
  final results = decoded['results'] as List;
  return GutendexPage(
    count: (decoded['count'] as num?)?.toInt() ?? results.length,
    nextUrl: decoded['next'] as String?,
    books: [
      for (final r in results)
        if (r is Map<String, dynamic>) _mapBook(r),
    ],
  );
}

GutendexBook _mapBook(Map<String, dynamic> r) {
  final formats = <String, String>{
    if (r['formats'] is Map)
      for (final e in (r['formats'] as Map).entries)
        if (e.key is String && e.value is String)
          e.key as String: e.value as String,
  };
  return GutendexBook(
    id: (r['id'] as num?)?.toInt() ?? 0,
    title: (r['title'] as String?) ?? 'Untitled',
    authors: [
      if (r['authors'] is List)
        for (final a in r['authors'] as List)
          if (a is Map && a['name'] is String) a['name'] as String,
    ],
    languages: [
      if (r['languages'] is List)
        for (final l in r['languages'] as List)
          if (l is String) l,
    ],
    downloadCount: (r['download_count'] as num?)?.toInt() ?? 0,
    textUrl: pickGutenbergTextUrl(formats),
    htmlUrl: _pickHtmlUrl(formats),
  );
}

/// Best `text/html` format URL: the bare key first, then any html-prefixed
/// key. Zip archives sometimes hide under html keys on older books — a zip
/// cannot go through the text pipeline, so those are skipped.
String? _pickHtmlUrl(Map<String, String> formats) {
  final candidates = [
    if (formats['text/html'] case final String u) u,
    for (final e in formats.entries)
      if (e.key.startsWith('text/html')) e.value,
  ];
  for (final u in candidates) {
    if (u.isEmpty) continue;
    if (u.toLowerCase().endsWith('.zip')) continue;
    return u;
  }
  return null;
}

/// A fetched Gutenberg book → clean paragraphs, ready to become one prose
/// segment each: html editions are flattened to text first, then the
/// boilerplate strip + hard-wrap unwrap runs ([stripGutenbergBoilerplate]),
/// then the blank-line paragraph law splits. Runs of spaces collapse — this
/// is a prose pipeline; page-layout whitespace does not survive it.
List<String> gutenbergParagraphs(String raw, {bool isHtml = false}) {
  final text = stripGutenbergBoilerplate(isHtml ? _htmlToText(raw) : raw);
  return [
    for (final p in text.split(_paragraphBreakRe))
      if (p.trim().isNotEmpty) p.trim().replaceAll(_spaceRunRe, ' '),
  ];
}

final _paragraphBreakRe = RegExp(r'\n\s*\n');
final _spaceRunRe = RegExp(r'[ \t]+');

const _skipTags = {'script', 'style', 'head', 'noscript', 'template'};
const _blockTags = {
  'p', 'div', 'section', 'article', 'blockquote', 'pre', //
  'h1', 'h2', 'h3', 'h4', 'h5', 'h6', //
  'li', 'ul', 'ol', 'tr', 'table', 'br', 'hr', 'figcaption',
};

/// Gutenberg html edition → text with blank-line paragraph boundaries.
/// Entities are decoded by the parser; block tags become paragraph breaks.
String _htmlToText(String html) {
  final doc = html_parser.parse(html);
  final root = doc.body ?? doc.documentElement;
  if (root == null) return '';
  final buf = StringBuffer();
  void walk(dom.Node node) {
    if (node is dom.Text) {
      buf.write(node.text);
      return;
    }
    if (node is! dom.Element) return;
    final tag = node.localName ?? '';
    if (_skipTags.contains(tag)) return;
    final block = _blockTags.contains(tag);
    if (block) buf.write('\n\n');
    node.nodes.forEach(walk);
    if (block) buf.write('\n\n');
  }

  walk(root);
  return buf.toString();
}
