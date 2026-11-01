/// "Open a link" for more than articles (owner, 17 Nov 2026): a link to a
/// Word document opens it, and a web book's contents page of chapter
/// links offers the whole book, brought in chapter by chapter as one
/// work.
///
/// Like [fetchArticle], everything here runs after the consent dialog
/// named the addresses, and every failure is a sentence.
library;

import 'dart:async';

import 'package:comms_core/comms_core.dart' hide decodeResponseBytes;
import 'package:flutter/foundation.dart';
import 'package:intake_core/intake_core.dart';

import '../../db/database.dart' show LinkRow;
import 'article_fetch.dart';
import 'docx_intake.dart';
import 'epub_flatten.dart' show SegmentRow;
import 'text_intake.dart' show textFileRows;

/// The most chapters one book may have; a contents page past this is
/// more likely a site's index than a book.
const maxBookChapters = 300;

/// What one link came to.
sealed class LinkOutcome {
  const LinkOutcome();
}

/// A web page: its article (or why there is none), and the book it is the
/// contents page of, if it is one.
final class LinkPage extends LinkOutcome {
  final ArticleFetchOutcome article;
  final BookContents? book;
  const LinkPage(this.article, this.book);
}

/// A Word document, read.
final class LinkDocument extends LinkOutcome {
  final DocxRows rows;
  const LinkDocument(this.rows);
}

final class LinkRefused extends LinkOutcome {
  final String message;
  const LinkRefused(this.message);
}

bool _isDocx(Uri url, String contentType) =>
    contentType.toLowerCase().startsWith(docxMimeType) ||
    url.path.toLowerCase().endsWith('.docx');

String _fileName(Uri url) => Uri.decodeComponent(
    url.pathSegments.isEmpty ? url.host : url.pathSegments.last);

/// Fetches [url] (already SSRF-checked and consented) and reads it as
/// what it is. Never throws.
Future<LinkOutcome> fetchLink(
    {required HttpFetcher fetcher, required Uri url}) async {
  final got = await fetchBytes(fetcher: fetcher, url: url);
  switch (got) {
    case BytesRefused(:final message):
      return LinkRefused(message);
    case BytesFetched(:final bytes, :final contentType):
      if (_isDocx(url, contentType)) {
        try {
          return LinkDocument(await compute(
              _readDocx, (bytes: bytes, name: _fileName(url), firstIdx: 0)));
        } on FormatException catch (e) {
          return LinkRefused(e.message);
        }
      }
      final html = decodeResponseBytes(bytes, contentType);
      final book = findBookContents(html, url);
      return LinkPage(articleFromHtml(html, url),
          book != null && book.chapters.length <= maxBookChapters ? book : null);
  }
}

DocxRows _readDocx(({Uint8List bytes, String name, int firstIdx}) m) =>
    docxRows(parseDocx(m.bytes, sourceName: m.name), firstIdx: m.firstIdx);

/// What fetching a whole book came to.
sealed class BookOutcome {
  const BookOutcome();
}

final class BookFetched extends BookOutcome {
  final DocxRows rows;
  const BookFetched(this.rows);
}

final class BookRefused extends BookOutcome {
  final String message;
  const BookRefused(this.message);
}

/// Fetches each chapter of [book] in order (all already consented) and
/// joins them into one book's rows: each chapter opens with its title as
/// a heading, unless it opens with a heading of its own. One chapter that
/// can't be read stops the book, naming it, so no book is ever missing a
/// chapter without saying so. [onChapter] hears how many are in hand.
/// Never throws.
Future<BookOutcome> fetchBook({
  required HttpFetcher fetcher,
  required BookContents book,
  void Function(int done, int total)? onChapter,
}) async {
  final total = book.chapters.length;
  if (total > maxBookChapters) {
    return const BookRefused('That book has too many chapters to bring in.');
  }
  final rows = <SegmentRow>[];
  final links = <LinkRow>[];
  for (final (n, chapter) in book.chapters.indexed) {
    onChapter?.call(n, total);
    final got = await fetchBytes(fetcher: fetcher, url: chapter.url);
    final DocxRows part;
    switch (got) {
      case BytesRefused(:final message):
        return BookRefused('“${chapter.title}” couldn’t be brought in. $message');
      case BytesFetched(:final bytes, :final contentType):
        try {
          part = _isDocx(chapter.url, contentType)
              ? await compute(_readDocx,
                  (bytes: bytes, name: chapter.title, firstIdx: rows.length))
              : _readText(chapter, decodeResponseBytes(bytes, contentType),
                  contentType, rows.length);
        } on FormatException catch (e) {
          return BookRefused(
              '“${chapter.title}” couldn’t be read. ${e.message}');
        }
    }
    final opensWithHeading =
        part.rows.isNotEmpty && part.rows.first.kind == 'heading';
    if (!opensWithHeading) {
      // The title goes first; the chapter's rows and links move down one.
      rows.add((idx: rows.length, kind: 'heading', text: chapter.title));
      for (final r in part.rows) {
        rows.add((idx: r.idx + 1, kind: r.kind, text: r.text));
      }
      for (final l in part.links) {
        links.add((segIdx: l.segIdx + 1, start: l.start, end: l.end, href: l.href));
      }
    } else {
      rows.addAll(part.rows);
      links.addAll(part.links);
    }
  }
  onChapter?.call(total, total);
  return BookFetched((title: book.title, rows: rows, links: links));
}

/// A chapter that is a page, Markdown or plain text, as rows numbered
/// from [firstIdx].
DocxRows _readText(
    BookChapterLink chapter, String text, String contentType, int firstIdx) {
  final type = contentType.toLowerCase();
  final path = chapter.url.path.toLowerCase();
  final markdown = type.startsWith('text/markdown') ||
      path.endsWith('.md') ||
      path.endsWith('.markdown');
  final plain = !markdown &&
      (type.startsWith('text/plain') || path.endsWith('.txt'));
  if (markdown || plain) {
    final got = textFileRows(text, name: chapter.title, markdown: markdown);
    return (
      title: chapter.title,
      rows: [
        for (final r in got.rows)
          (idx: firstIdx + r.idx, kind: r.kind, text: r.text)
      ],
      links: const <LinkRow>[],
    );
  }
  // A page: its readable text, however short (a chapter may be a page of
  // a bibliography), with its links.
  final article = extractArticle(text, baseUrl: chapter.url.toString());
  final rows = <SegmentRow>[];
  final links = <LinkRow>[];
  for (final block in article.blocks) {
    if (block is! TextBlock) continue;
    for (final l in block.links) {
      links.add((
        segIdx: firstIdx + rows.length,
        start: l.start,
        end: l.end,
        href: l.href
      ));
    }
    rows.add((idx: firstIdx + rows.length, kind: 'prose', text: block.text));
  }
  return (title: chapter.title, rows: rows, links: links);
}
