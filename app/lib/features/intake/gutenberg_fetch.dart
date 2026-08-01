/// The Gutenberg intake pipeline: gutendex.com catalogue search and the
/// book-file download, both through the app's [HttpFetcher] seam, every
/// failure a calm sentence (the screen never sees an exception).
///
/// SSRF law (the url_intake precedent): EVERY URL is re-guarded with
/// [assertSafeFetchUrl] immediately before it is fetched — the search URL we
/// build, the `next` page URL the server hands back, and the book file URL
/// out of the catalogue JSON. The last two come off the wire and are treated
/// as hostile until the guard says otherwise.
///
/// Web tier: plain HTTP through the seam, no dart:io — this compiles and
/// runs on web builds. (Measured 2026-08-12: gutendex.com allows browser
/// reads, but gutenberg.org's book files do NOT — so in a browser the
/// search works and the download is refused with the fetcher's honest
/// transport sentence. The screen's web note names the fallback: save the
/// EPUB with the browser, then Import an EPUB. No proxy workaround, by
/// design.)
library;

import 'dart:async';
import 'dart:typed_data';

// Both packages port the donor's charset sniffing; for fetched documents the
// intake_core copy is the authority, so comms_core's is hidden here (the
// article_fetch precedent).
import 'package:comms_core/comms_core.dart' hide decodeResponseBytes;
import 'package:intake_core/intake_core.dart';

import 'epub_flatten.dart' show SegmentRow;

/// What one catalogue search came to.
sealed class GutendexSearchOutcome {
  const GutendexSearchOutcome();
}

final class GutendexSearchResults extends GutendexSearchOutcome {
  final GutendexPage page;
  const GutendexSearchResults(this.page);
}

final class GutendexSearchRefused extends GutendexSearchOutcome {
  final String message;
  const GutendexSearchRefused(this.message);
}

/// What one book download came to.
sealed class GutenbergBookOutcome {
  const GutenbergBookOutcome();
}

/// Clean paragraphs as spine rows — what the preview counts is what lands.
final class GutenbergBookFetched extends GutenbergBookOutcome {
  final List<SegmentRow> rows;
  final String sourceUrl;
  const GutenbergBookFetched({required this.rows, required this.sourceUrl});
}

final class GutenbergBookRefused extends GutenbergBookOutcome {
  final String message;
  const GutenbergBookRefused(this.message);
}

/// Searches the catalogue. Pass [query] for a fresh search (the typed words
/// become `?search=`), or [pageUrl] to follow a server-supplied `next` link.
/// Never throws.
Future<GutendexSearchOutcome> searchGutendex({
  required HttpFetcher fetcher,
  String? query,
  String? pageUrl,
  Duration timeout = const Duration(seconds: 20),
}) async {
  assert((query == null) != (pageUrl == null),
      'exactly one of query / pageUrl');
  final raw = pageUrl ?? buildGutendexSearchUrl(query!).toString();
  final Uri url;
  try {
    // Re-guard even our own built URL; the next-page URL is server data.
    url = assertSafeFetchUrl(raw);
  } on UnsafeUrlException catch (e) {
    return GutendexSearchRefused(e.message);
  }

  final FetchResponse response;
  try {
    response = await fetcher.get(url,
        headers: const {'accept': 'application/json'}, timeout: timeout);
  } on TimeoutException {
    return const GutendexSearchRefused(
        'The catalogue took too long to answer — try again later.');
  } on CommsException catch (e) {
    return GutendexSearchRefused(e.message);
  } catch (_) {
    return const GutendexSearchRefused(
        "The catalogue couldn't be reached right now.");
  }
  if (!response.ok) {
    return GutendexSearchRefused(
        'The catalogue answered with an error (${response.statusCode}).');
  }

  final Uint8List bytes;
  try {
    bytes = await collectCapped(response.body,
        maxBytes: maxXmlBytes,
        message: 'The catalogue answer was too large to read.');
  } on SizeCapException catch (e) {
    return GutendexSearchRefused(e.message);
  } catch (_) {
    return const GutendexSearchRefused(
        'The answer stopped arriving before it finished.');
  }

  try {
    return GutendexSearchResults(parseGutendexPage(
        decodeResponseBytes(bytes, response.headers['content-type'] ?? '')));
  } on FormatException {
    return const GutendexSearchRefused(
        "The catalogue's answer couldn't be read.");
  }
}

/// Downloads one book's readable edition (plain text preferred, html the
/// fallback) and turns it into prose spine rows: boilerplate stripped,
/// hard-wrap undone, blank line = paragraph break. [onBytes] reports the
/// cumulative bytes that survived the mid-stream cap. Never throws.
Future<GutenbergBookOutcome> fetchGutenbergBook({
  required HttpFetcher fetcher,
  required GutendexBook book,
  void Function(int got)? onBytes,
  Duration timeout = const Duration(seconds: 60),
}) async {
  final raw = book.importUrl;
  if (raw == null) {
    return const GutenbergBookRefused(
        'This edition has no readable text — try another result.');
  }
  final Uri url;
  try {
    // The file URL came out of catalogue JSON — hostile until guarded.
    url = assertSafeFetchUrl(raw);
  } on UnsafeUrlException catch (e) {
    return GutenbergBookRefused(e.message);
  }

  final FetchResponse response;
  try {
    response = await fetcher.get(url,
        headers: const {'accept': 'text/plain, text/html, */*'},
        timeout: timeout);
  } on TimeoutException {
    return const GutenbergBookRefused(
        'The download took too long — try again later.');
  } on CommsException catch (e) {
    return GutenbergBookRefused(e.message);
  } catch (_) {
    return const GutenbergBookRefused(
        "That book couldn't be reached right now.");
  }
  if (!response.ok) {
    return GutenbergBookRefused(
        'The download answered with an error (${response.statusCode}).');
  }

  final Uint8List bytes;
  try {
    bytes = await collectCapped(response.body,
        maxBytes: maxTextFetchBytes,
        message: 'That book is too large to bring in.',
        onBytes: onBytes);
  } on SizeCapException catch (e) {
    return GutenbergBookRefused(e.message);
  } on TimeoutException {
    return const GutenbergBookRefused(
        'The download took too long — try again later.');
  } catch (_) {
    return const GutenbergBookRefused(
        'The book stopped arriving before it finished.');
  }

  final text =
      decodeResponseBytes(bytes, response.headers['content-type'] ?? '');
  final paragraphs = gutenbergParagraphs(text, isHtml: book.importIsHtml);
  if (paragraphs.isEmpty) {
    return const GutenbergBookRefused(
        'No readable text arrived from that address.');
  }
  return GutenbergBookFetched(
    rows: [
      for (final (i, p) in paragraphs.indexed) (idx: i, kind: 'prose', text: p)
    ],
    sourceUrl: url.toString(),
  );
}
