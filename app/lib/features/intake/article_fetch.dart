/// The URL-intake pipeline: one already-consented fetch through the app's
/// [HttpFetcher] seam, then intake_core's article extraction, mapped onto
/// spine rows. Every failure becomes a calm sentence here — the screen never
/// sees an exception, so no stack can ever reach the user (ADR-0003's tone
/// is a law: errors are sentences).
///
/// The SSRF guard runs twice by design: lexically in the screen BEFORE the
/// consent dialog (a refused address needs no dialog), and again on every
/// redirect hop inside [IoHttpFetcher] — this function trusts the seam for
/// the second half.
library;

import 'dart:async';
import 'dart:typed_data';

// Both packages port the donor's charset sniffing; for article pages the
// intake_core copy is the authority, so comms_core's is hidden here.
import 'package:comms_core/comms_core.dart' hide decodeResponseBytes;
import 'package:intake_core/intake_core.dart';

import 'epub_flatten.dart' show SegmentRow;

/// What one fetch attempt came to.
sealed class ArticleFetchOutcome {
  const ArticleFetchOutcome();
}

/// A readable article: the extraction result plus the spine rows it flattens
/// to (the preview's passage count and the confirm step's insert payload are
/// the SAME list — what you see is what lands).
final class ArticleFetched extends ArticleFetchOutcome {
  final ArticleResult article;
  final List<SegmentRow> rows;
  const ArticleFetched({required this.article, required this.rows});
}

/// A calm refusal: one user-facing sentence, no exception type leaks out.
final class ArticleRefused extends ArticleFetchOutcome {
  final String message;
  const ArticleRefused(this.message);
}

/// Fetches [url] (already SSRF-checked by the caller) and extracts the
/// readable article. Never throws.
Future<ArticleFetchOutcome> fetchArticle({
  required HttpFetcher fetcher,
  required Uri url,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final FetchResponse response;
  try {
    response = await fetcher.get(url,
        headers: const {'accept': 'text/html, application/xhtml+xml, */*'},
        timeout: timeout);
  } on TimeoutException {
    return const ArticleRefused(
        'The site took too long to answer — try again later.');
  } on CommsException catch (e) {
    // Donor-verbatim user-facing messages (redirect refusals, hop SSRF).
    return ArticleRefused(e.message);
  } catch (_) {
    return const ArticleRefused("That address couldn't be reached.");
  }

  if (response.statusCode < 200 || response.statusCode >= 300) {
    return ArticleRefused(
        'The site answered with an error (${response.statusCode}).');
  }

  final Uint8List bytes;
  try {
    bytes = await collectCapped(response.body,
        maxBytes: maxTextFetchBytes,
        message: 'That page is too large to bring in.');
  } on SizeCapException catch (e) {
    return ArticleRefused(e.message);
  } on TimeoutException {
    return const ArticleRefused(
        'The site took too long to answer — try again later.');
  } catch (_) {
    return const ArticleRefused(
        'The page stopped arriving before it finished.');
  }

  final html =
      decodeResponseBytes(bytes, response.headers['content-type'] ?? '');
  final article = extractArticle(html, baseUrl: url.toString());

  if (article.isFeedXml) {
    return const ArticleRefused(
        'That address is a feed of episodes — follow it from the River tab '
        'instead.');
  }
  // Donor loadUrl law: under 200 chars of extracted text is not an article.
  if (article.text.length < 200) {
    return const ArticleRefused(
        'No readable article was found at that address.');
  }

  // Articles flatten to prose-only spine rows (the extractor emits nothing
  // else); keeping the mapping here mirrors epub_flatten's block→row seam.
  final rows = <SegmentRow>[];
  for (final block in article.blocks) {
    if (block is TextBlock) {
      rows.add((idx: rows.length, kind: 'prose', text: block.text));
    }
  }
  return ArticleFetched(article: article, rows: rows);
}
