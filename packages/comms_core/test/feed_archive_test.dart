/// walkFeedArchive: the explicit, user-triggered RFC 5005 archive walk.
/// Follows a feed's rel="next"/rel="prev-archive" chain one hop at a time,
/// under a hard page cap, deduping items across pages and reporting exactly
/// how the walk ended — a spinning host or a mid-walk failure must surface
/// as an honest partial result, never as silence or a hang.
library;

import 'dart:convert';

import 'package:comms_core/comms_core.dart';
import 'package:test/test.dart';

import 'scripted_fetcher.dart';

/// Builds a single-page RSS response with an optional `rel="next"` link and
/// the given item titles (each item's link doubles as its identity).
FetchResponse _page(String url,
    {String? nextUrl, List<String> itemLinks = const []}) {
  final items = itemLinks
      .map((l) => '<item><title>$l</title><link>$l</link></item>')
      .join();
  final nextLink =
      nextUrl == null ? '' : '<atom:link rel="next" href="$nextUrl"/>';
  return textResponse('<rss><channel><title>t</title>$nextLink$items'
      '</channel></rss>');
}

void main() {
  // Native surfaces (the walk's real caller) never grant proxy consent
  // (FeedsRepository's NativeDirectConsent) — matching that here keeps
  // these tests to one fetch per hop instead of exercising the proxy
  // ladder as a side effect.
  CommsClient client(ScriptedFetcher fetcher) => clientWith(fetcher);

  test('walks page to page until the chain ends (noMorePages)', () async {
    final fetcher = ScriptedFetcher((url, headers) {
      final u = url.toString();
      if (u == 'https://x.test/page1') {
        return _page(u,
            nextUrl: 'https://x.test/page2', itemLinks: ['https://x/a']);
      }
      if (u == 'https://x.test/page2') {
        return _page(u, itemLinks: ['https://x/b']);
      }
      throw Exception('unexpected $u');
    });

    final result = await walkFeedArchive(client(fetcher),
        startPageUrl: 'https://x.test/page1');

    expect(result.pagesFetched, 2);
    expect(result.stopReason, ArchiveWalkStopReason.noMorePages);
    expect(result.items.map((i) => i.link), ['https://x/a', 'https://x/b']);
    expect(result.message, isNotEmpty);
  });

  test('dedups an item repeated across pages by link identity', () async {
    final fetcher = ScriptedFetcher((url, headers) {
      final u = url.toString();
      if (u == 'https://x.test/page1') {
        return _page(u,
            nextUrl: 'https://x.test/page2',
            itemLinks: ['https://x/a', 'https://x/b']);
      }
      if (u == 'https://x.test/page2') {
        // Host misconfiguration: repeats item b, adds c.
        return _page(u, itemLinks: ['https://x/b', 'https://x/c']);
      }
      throw Exception('unexpected $u');
    });

    final result = await walkFeedArchive(client(fetcher),
        startPageUrl: 'https://x.test/page1');

    expect(result.items.map((i) => i.link),
        ['https://x/a', 'https://x/b', 'https://x/c']);
  });

  test('a hard page cap stops a looping/hostile feed without spinning',
      () async {
    var pageNum = 0;
    final fetcher = ScriptedFetcher((url, headers) {
      pageNum++;
      // Every page links to a "next" page — an infinite chain if unchecked.
      return _page(url.toString(),
          nextUrl: 'https://x.test/page${pageNum + 1}',
          itemLinks: ['https://x/$pageNum']);
    });

    final result = await walkFeedArchive(client(fetcher),
        startPageUrl: 'https://x.test/page1', maxPages: 3);

    expect(result.pagesFetched, 3,
        reason: 'stops at the cap, does not keep following next links');
    expect(result.stopReason, ArchiveWalkStopReason.pageCap);
    expect(result.items, hasLength(3));
    expect(result.message, isNotEmpty,
        reason: 'hitting the cap must be reported, not silent');
  });

  test('defaults to a 25-page cap', () async {
    expect(defaultArchivePageCap, 25);
  });

  test('a mid-walk fetch failure surfaces partial results plus a sentence',
      () async {
    final fetcher = ScriptedFetcher((url, headers) {
      final u = url.toString();
      if (u == 'https://x.test/page1') {
        return _page(u,
            nextUrl: 'https://x.test/page2', itemLinks: ['https://x/a']);
      }
      throw Exception('connection reset');
    });

    final result = await walkFeedArchive(client(fetcher),
        startPageUrl: 'https://x.test/page1');

    expect(result.pagesFetched, 1);
    expect(result.stopReason, ArchiveWalkStopReason.fetchFailed);
    expect(result.items.map((i) => i.link), ['https://x/a']);
    expect(result.message, isNotEmpty);
  });

  test('a mid-walk parse failure surfaces partial results plus a sentence',
      () async {
    final fetcher = ScriptedFetcher((url, headers) {
      final u = url.toString();
      if (u == 'https://x.test/page1') {
        return _page(u,
            nextUrl: 'https://x.test/page2', itemLinks: ['https://x/a']);
      }
      return textResponse('not xml at all <');
    });

    final result = await walkFeedArchive(client(fetcher),
        startPageUrl: 'https://x.test/page1');

    expect(result.pagesFetched, 1);
    expect(result.stopReason, ArchiveWalkStopReason.parseFailed);
    expect(result.items.map((i) => i.link), ['https://x/a']);
    expect(result.message, isNotEmpty);
  });

  test('a safe-url refusal on the first hop stops the walk immediately',
      () async {
    final fetcher = donorFetcher();

    final result = await walkFeedArchive(client(fetcher),
        startPageUrl: 'http://192.168.1.10/page1');

    expect(result.pagesFetched, 0);
    expect(result.stopReason, ArchiveWalkStopReason.unsafeUrl);
    expect(result.items, isEmpty);
    expect(fetcher.calls, isEmpty);
    expect(result.message, isNotEmpty);
  });

  test('a safe-url refusal on a later hop stops the walk with the earlier '
      "pages' items kept", () async {
    final fetcher = ScriptedFetcher((url, headers) {
      final u = url.toString();
      if (u == 'https://x.test/page1') {
        // A hostile or misconfigured host points "next" at a private
        // address — an absolute unsafe URL, not merely an unresolved
        // relative one.
        return _page(u,
            nextUrl: 'http://192.168.1.10/page2', itemLinks: ['https://x/a']);
      }
      throw Exception('unexpected $u');
    });

    final result = await walkFeedArchive(client(fetcher),
        startPageUrl: 'https://x.test/page1');

    expect(result.pagesFetched, 1);
    expect(result.stopReason, ArchiveWalkStopReason.unsafeUrl);
    expect(result.items.map((i) => i.link), ['https://x/a']);
    expect(result.message, isNotEmpty);
  });

  test('a fresh but empty final page yields noMorePages with zero items',
      () async {
    final fetcher =
        ScriptedFetcher((url, headers) => _page(url.toString()));

    final result = await walkFeedArchive(client(fetcher),
        startPageUrl: 'https://x.test/page1');

    expect(result.stopReason, ArchiveWalkStopReason.noMorePages);
    expect(result.items, isEmpty);
    expect(result.pagesFetched, 1);
  });

  test('every hop is decoded via the same byte-cap machinery as a normal '
      'feed fetch', () async {
    final fetcher = ScriptedFetcher((url, headers) => FetchResponse(
          statusCode: 200,
          headers: const {'content-type': 'text/xml'},
          body: Stream.value(
              utf8.encode('x' * (25 * 1024 * 1024 + 1))),
        ));

    final result = await walkFeedArchive(client(fetcher),
        startPageUrl: 'https://x.test/page1');

    expect(result.stopReason, ArchiveWalkStopReason.fetchFailed,
        reason: 'the size cap trips inside fetchFeedConditional, which the '
            'walker treats like any other failed hop');
    expect(result.pagesFetched, 0);
  });
}
