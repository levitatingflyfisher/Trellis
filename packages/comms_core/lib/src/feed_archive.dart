/// The RFC 5005 archive walk: follows a feed's rel="next"/rel="prev-archive"
/// chain one hop at a time to recover episodes a host has truncated off its
/// current feed document. This is an explicit, user-triggered action, not
/// part of a normal refresh — callers invoke it only when a parsed feed
/// already carries a [ParsedFeed.nextPageUrl].
///
/// Every hop reuses [CommsClient.fetchFeedConditional], which already
/// applies the safe-url guard and the byte caps; this file adds the walk's
/// own laws: a hard page cap so a looping or hostile chain cannot spin,
/// cross-page item dedup, and an honest sentence for every way the walk can
/// end — including partway through, on failure.
library;

import 'comms_client.dart';
import 'exceptions.dart';
import 'feed_fetch_result.dart';
import 'feed_models.dart';
import 'feed_parser.dart';
import 'limits.dart';

/// How a [walkFeedArchive] call ended.
enum ArchiveWalkStopReason {
  /// The last page fetched carried no further next/prev-archive link — the
  /// archive was walked to its actual end.
  noMorePages,

  /// [FeedArchiveResult.pagesFetched] hit the cap while a further link was
  /// still on offer.
  pageCap,

  /// A hop could not be fetched — transport failure, or the host answered
  /// with a non-fresh status (throttled, not-found, error) for that page.
  fetchFailed,

  /// A hop's body arrived but would not parse as a feed.
  parseFailed,

  /// A next/prev-archive URL failed the safe-url guard.
  unsafeUrl,
}

/// The outcome of one archive walk.
class FeedArchiveResult {
  const FeedArchiveResult({
    required this.items,
    required this.pagesFetched,
    required this.stopReason,
    required this.message,
  });

  /// Every item collected across the walked pages, in the order
  /// encountered, deduped by link (else enclosure URL, else title#date) —
  /// a host that repeats an item across pages must not double it here.
  final List<FeedItem> items;

  /// How many archive pages were successfully fetched and parsed before the
  /// walk stopped (the starting page counts as page 1).
  final int pagesFetched;

  final ArchiveWalkStopReason stopReason;

  /// An honest, technical account of how the walk ended — present for
  /// every [stopReason], including the happy path. Callers with their own
  /// exact wording (e.g. "Found N older episodes.") are free to ignore
  /// this and compose their own from [items] and [stopReason]; it exists
  /// so a capped or interrupted walk is never reported as silent success.
  final String message;
}

/// Item identity for the walk's own cross-page dedup — mirrors the app
/// layer's guid choice (link, else enclosure, else title#date) without
/// depending on it: this is an in-memory dedup over one walk's results,
/// not the persisted-storage dedup the caller applies afterward.
String _archiveItemKey(FeedItem item) {
  if (item.link.isNotEmpty) return item.link;
  if (item.audio.isNotEmpty) return item.audio;
  return '${item.title}#${item.date}';
}

String _pageWord(int n) => n == 1 ? 'page' : 'pages';

/// Walks a feed's paged archive starting at [startPageUrl] (a
/// [ParsedFeed.nextPageUrl] the caller already has in hand), fetching and
/// parsing one hop at a time until the chain ends, [maxPages] is reached,
/// or a hop fails.
Future<FeedArchiveResult> walkFeedArchive(
  CommsClient client, {
  required String startPageUrl,
  int maxPages = defaultArchivePageCap,
}) async {
  final items = <FeedItem>[];
  final seenKeys = <String>{};
  String? nextUrl = startPageUrl;
  var pagesFetched = 0;

  while (nextUrl != null) {
    if (pagesFetched >= maxPages) {
      return FeedArchiveResult(
        items: items,
        pagesFetched: pagesFetched,
        stopReason: ArchiveWalkStopReason.pageCap,
        message: 'Stopped after $pagesFetched archive '
            '${_pageWord(pagesFetched)} — that is the safety limit. Some '
            'older episodes may remain unfetched.',
      );
    }

    final url = nextUrl;
    final FeedFetchResult res;
    try {
      res = await client.fetchFeedConditional(url);
    } on UnsafeUrlException {
      return FeedArchiveResult(
        items: items,
        pagesFetched: pagesFetched,
        stopReason: ArchiveWalkStopReason.unsafeUrl,
        message: pagesFetched == 0
            ? "The archive link isn't a safe address to fetch — no older "
                'episodes were fetched.'
            : 'Stopped after $pagesFetched archive '
                '${_pageWord(pagesFetched)} — the next link was not a safe '
                'address to follow.',
      );
    }

    if (res.status != FeedFetchStatus.fresh) {
      return FeedArchiveResult(
        items: items,
        pagesFetched: pagesFetched,
        stopReason: ArchiveWalkStopReason.fetchFailed,
        message: pagesFetched == 0
            ? "The archive couldn't be reached — no older episodes were "
                'fetched.'
            : 'Stopped after $pagesFetched archive '
                "${_pageWord(pagesFetched)} — the next one couldn't be "
                'reached.',
      );
    }

    final ParsedFeed parsed;
    try {
      parsed = parseRssFeed(res.body!, url);
    } on FeedParseException {
      return FeedArchiveResult(
        items: items,
        pagesFetched: pagesFetched,
        stopReason: ArchiveWalkStopReason.parseFailed,
        message: pagesFetched == 0
            ? "The archive page couldn't be read as a feed."
            : 'Stopped after $pagesFetched archive '
                "${_pageWord(pagesFetched)} — the next one couldn't be read "
                'as a feed.',
      );
    }

    pagesFetched++;
    for (final item in parsed.items) {
      if (seenKeys.add(_archiveItemKey(item))) items.add(item);
    }
    nextUrl = parsed.nextPageUrl;
  }

  return FeedArchiveResult(
    items: items,
    pagesFetched: pagesFetched,
    stopReason: ArchiveWalkStopReason.noMorePages,
    message: items.isEmpty
        ? 'The archive was reached and had no further episodes.'
        : 'Reached the end of the archive after $pagesFetched '
            '${_pageWord(pagesFetched)}.',
  );
}
