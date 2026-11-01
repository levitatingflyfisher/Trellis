/// A web book's contents page (owner, 17 Nov 2026): a page that is mostly
/// a list of links to the book's chapters, one file or page each. Found
/// here, the app offers to bring in the whole book, chapter by chapter,
/// as one work.
///
/// A page counts when, after the rules below, at least
/// [minBookChapters] chapter links are left and their words make up at
/// least [minLinkShare] of the page's text. An ordinary article with a
/// few links in it, or a site's menu beside a post, falls well short.
///
/// A chapter link:
///  * is a web address on the same site, in the page's own folder or
///    below it;
///  * names a page or a file Trellis reads from the web (a page, a Word
///    document, Markdown or text), not a picture, an archive or a PDF;
///  * is not the page itself, and not a link to "the whole book as one
///    file", which would bring the book in twice.
/// A chapter linked twice (a number and a title, say) counts once, in its
/// first place, named by the first link that has words.
library;

import 'package:html/parser.dart' as html_parser;

const minBookChapters = 3;
const minLinkShare = 0.4;

/// One chapter of a web book: its title on the contents page, and where
/// it is.
final class BookChapterLink {
  final String title;
  final Uri url;
  const BookChapterLink({required this.title, required this.url});

  @override
  bool operator ==(Object other) =>
      other is BookChapterLink && other.title == title && other.url == url;

  @override
  int get hashCode => Object.hash(title, url);

  @override
  String toString() => 'BookChapterLink($title, $url)';
}

/// A web book: its title, from the contents page, and its chapters in
/// order.
final class BookContents {
  final String title;
  final Uri contentsUrl;
  final List<BookChapterLink> chapters;
  const BookContents(
      {required this.title, required this.contentsUrl, required this.chapters});
}

const _readable = {'', 'htm', 'html', 'xhtml', 'shtml', 'php', 'asp', 'aspx', 'docx', 'txt', 'md', 'markdown'};

final _wholeBook = RegExp(
    r'\b(whole|complete|entire|full)\b.*\b(book|text|file|work)\b|'
    r'\bone file\b|\ball in one\b|\bsingle file\b|\bdownload (the|all)\b',
    caseSensitive: false);

final _space = RegExp(r'\s+');

String _fold(String s) => s.replaceAll(_space, ' ').trim();

String _host(String h) => h.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');

String _ending(Uri u) {
  final last = u.pathSegments.isEmpty ? '' : u.pathSegments.last;
  final dot = last.lastIndexOf('.');
  return dot < 0 ? '' : last.substring(dot + 1).toLowerCase();
}

/// The book [html] is the contents page of, read at [pageUrl]; null when
/// it is not one.
BookContents? findBookContents(String html, Uri pageUrl) {
  final doc = html_parser.parse(html);
  final body = doc.body;
  if (body == null) return null;
  for (final e in body.querySelectorAll('script, style, noscript, template')) {
    e.remove();
  }
  final page = pageUrl.removeFragment();
  final folder = page.path.substring(0, page.path.lastIndexOf('/') + 1);

  final order = <Uri>[];
  final titles = <Uri, String>{};
  for (final a in body.querySelectorAll('a[href]')) {
    final href = a.attributes['href']!.trim();
    if (href.isEmpty || href.startsWith('#')) continue;
    final Uri url;
    try {
      url = page.resolve(href).removeFragment();
    } on FormatException {
      continue;
    }
    if (url.scheme != 'http' && url.scheme != 'https') continue;
    if (_host(url.host) != _host(page.host)) continue;
    if (!url.path.startsWith(folder)) continue;
    if (url.path == page.path && url.query == page.query) continue;
    if (!_readable.contains(_ending(url))) continue;
    final words = _fold(a.text);
    if (_wholeBook.hasMatch(words)) continue;
    if (!titles.containsKey(url)) {
      order.add(url);
      titles[url] = words;
    } else if (titles[url]!.isEmpty) {
      titles[url] = words;
    }
  }
  if (order.length < minBookChapters) return null;

  final linkWords = titles.values.fold<int>(0, (n, t) => n + t.length);
  final pageWords = _fold(body.text).length;
  if (pageWords == 0 || linkWords / pageWords < minLinkShare) return null;

  String nameOf(Uri u) {
    final last = Uri.decodeComponent(
        u.pathSegments.isEmpty ? u.host : u.pathSegments.last);
    final dot = last.lastIndexOf('.');
    return dot > 0 ? last.substring(0, dot) : last;
  }

  final title = _fold(doc.querySelector('title')?.text ?? '');
  final h1 = _fold(body.querySelector('h1')?.text ?? '');
  return BookContents(
    title: title.isNotEmpty ? title : (h1.isNotEmpty ? h1 : page.host),
    contentsUrl: page,
    chapters: [
      for (final u in order)
        BookChapterLink(
            title: titles[u]!.isEmpty ? nameOf(u) : titles[u]!, url: u),
    ],
  );
}

