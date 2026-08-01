/// fetchFeedConditional port (donor 40-comms.js ~L60): conditional GET
/// (ETag/Last-Modified/304), Retry-After throttling, notFound vs error,
/// and the never-prompt background proxy rule (C5).
library;

import 'dart:convert';

import 'package:comms_core/comms_core.dart';
import 'package:test/test.dart';

import 'scripted_fetcher.dart';

CommsClient feedClient(ScriptedFetcher fetcher,
        {FakeConsent? consent, DateTime Function()? now}) =>
    CommsClient(fetcher: fetcher, consent: consent ?? FakeConsent(), now: now);

FetchResponse status(int code, {Map<String, String> headers = const {}}) =>
    FetchResponse(
        statusCode: code, headers: headers, body: const Stream.empty());

void main() {
  test('sends conditional headers and maps 304 to notModified', () async {
    final fetcher = ScriptedFetcher((url, headers) => status(304));
    final res = await feedClient(fetcher).fetchFeedConditional(
        'https://example.com/feed',
        etag: 'W/"abc"',
        lastModified: 'Mon, 01 Jan 2024 00:00:00 GMT');
    expect(res.status, FeedFetchStatus.notModified);
    final sent = fetcher.calls.single.headers!;
    expect(sent['If-None-Match'], 'W/"abc"');
    expect(sent['If-Modified-Since'], 'Mon, 01 Jan 2024 00:00:00 GMT');
  });

  test('sends no conditional headers without stored meta', () async {
    final fetcher =
        ScriptedFetcher((url, headers) => textResponse('<rss/>'));
    await feedClient(fetcher).fetchFeedConditional('https://example.com/feed');
    expect(fetcher.calls.single.headers ?? const <String, String>{}, isEmpty);
  });

  group('throttling (429/503 + Retry-After)', () {
    Future<FeedFetchResult> throttleWith(String? retryAfter,
        {int code = 429, DateTime Function()? now}) {
      final fetcher = ScriptedFetcher((url, headers) => status(code,
          headers: retryAfter == null ? {} : {'retry-after': retryAfter}));
      return feedClient(fetcher, now: now)
          .fetchFeedConditional('https://example.com/feed');
    }

    test('integer seconds', () async {
      final res = await throttleWith('120');
      expect(res.status, FeedFetchStatus.throttled);
      expect(res.retryAfterSeconds, 120);
    });

    test('parseInt prefix quirk: "120s" parses as 120 (JS parseInt)',
        () async {
      expect((await throttleWith('120s')).retryAfterSeconds, 120);
    });

    test('garbage falls back to 60', () async {
      expect((await throttleWith('soon')).retryAfterSeconds, 60);
    });

    test('missing header falls back to 60 on 503 too', () async {
      final res = await throttleWith(null, code: 503);
      expect(res.status, FeedFetchStatus.throttled);
      expect(res.retryAfterSeconds, 60);
    });

    test('HTTP-date is converted to seconds from the injected clock',
        () async {
      final nowDt = DateTime.utc(2026, 8, 5, 12, 0, 0);
      final res = await throttleWith('Wed, 05 Aug 2026 12:01:30 GMT',
          code: 503, now: () => nowDt);
      expect(res.retryAfterSeconds, 90);
    });

    test('a date in the past clamps to 1 second', () async {
      final nowDt = DateTime.utc(2026, 8, 5, 12, 0, 0);
      final res =
          await throttleWith('Wed, 05 Aug 2026 11:00:00 GMT', now: () => nowDt);
      expect(res.retryAfterSeconds, 1);
    });
  });

  test('404 and 410 map to notFound', () async {
    for (final code in [404, 410]) {
      final fetcher = ScriptedFetcher((url, headers) => status(code));
      final res = await feedClient(fetcher)
          .fetchFeedConditional('https://example.com/feed');
      expect(res.status, FeedFetchStatus.notFound, reason: '$code');
    }
  });

  test('200 maps to fresh with body, etag and last-modified captured',
      () async {
    final fetcher = ScriptedFetcher((url, headers) => FetchResponse(
          statusCode: 200,
          headers: const {
            'content-type': 'application/rss+xml; charset=utf-8',
            'ETag': 'W/"v2"',
            'Last-Modified': 'Tue, 02 Jan 2024 00:00:00 GMT',
          },
          body: Stream.value(utf8.encode('<rss>x</rss>')),
        ));
    final res = await feedClient(fetcher)
        .fetchFeedConditional('https://example.com/feed');
    expect(res.status, FeedFetchStatus.fresh);
    expect(res.body, '<rss>x</rss>');
    expect(res.etag, 'W/"v2"');
    expect(res.lastModified, 'Tue, 02 Jan 2024 00:00:00 GMT');
    expect(res.viaProxy, isFalse);
  });

  test('other 4xx returns error with the code and never tries a proxy',
      () async {
    final fetcher = ScriptedFetcher((url, headers) => status(403));
    final res = await feedClient(fetcher, consent: FakeConsent(prior: true))
        .fetchFeedConditional('https://example.com/feed');
    expect(res.status, FeedFetchStatus.error);
    expect(res.errorCode, 403);
    expect(fetcher.calls, hasLength(1),
        reason: 'donor returns 4xx directly, no proxy fallback');
  });

  test('transport failure without consent is a plain error, no proxy hit',
      () async {
    final fetcher =
        ScriptedFetcher((url, headers) => throw Exception('boom'));
    final res = await feedClient(fetcher)
        .fetchFeedConditional('https://example.com/feed');
    expect(res.status, FeedFetchStatus.error);
    expect(res.errorCode, isNull);
    expect(fetcher.calls.where((c) => isProxyUrl(c.url)), isEmpty);
  });

  test(
      'a typed transport refusal keeps its sentence when no proxy may run — '
      'the web fetcher explains a browser-blocked read; destroying that '
      'sentence turns an honest refusal into "site down"', () async {
    const honest = 'The browser blocked this fetch — sites must allow '
        'web pages to read them.';
    final fetcher = ScriptedFetcher(
        (url, headers) => throw const FetchFailedException(honest));
    final res = await feedClient(fetcher)
        .fetchFeedConditional('https://example.com/feed');
    expect(res.status, FeedFetchStatus.error);
    expect(res.message, honest);
  });

  test('an untyped transport failure carries no message (nothing to say)',
      () async {
    final fetcher =
        ScriptedFetcher((url, headers) => throw Exception('boom'));
    final res = await feedClient(fetcher)
        .fetchFeedConditional('https://example.com/feed');
    expect(res.message, isNull);
  });

  test('background refresh never prompts (C5): grantable consent unused',
      () async {
    final consent = FakeConsent(grantOnAsk: true);
    final fetcher =
        ScriptedFetcher((url, headers) => throw Exception('boom'));
    final res = await feedClient(fetcher, consent: consent)
        .fetchFeedConditional('https://example.com/feed');
    expect(res.status, FeedFetchStatus.error);
    expect(consent.askCount, 0,
        reason: 'donor only uses proxies here if already consented');
  });

  test('prior consent falls back to proxy; fresh viaProxy with null '
      'validators (donor drops proxy etags)', () async {
    final fetcher = ScriptedFetcher((url, headers) => isProxyUrl(url)
        ? FetchResponse(
            statusCode: 200,
            headers: const {'ETag': 'W/"proxy"'},
            body: Stream.value(utf8.encode('<rss>p</rss>')))
        : throw Exception('offline'));
    final res = await feedClient(fetcher, consent: FakeConsent(prior: true))
        .fetchFeedConditional('https://example.com/feed');
    expect(res.status, FeedFetchStatus.fresh);
    expect(res.body, '<rss>p</rss>');
    expect(res.viaProxy, isTrue);
    expect(res.etag, isNull);
    expect(res.lastModified, isNull);
  });

  test('consented but all proxies fail: error', () async {
    final fetcher =
        ScriptedFetcher((url, headers) => throw Exception('boom'));
    final res = await feedClient(fetcher, consent: FakeConsent(prior: true))
        .fetchFeedConditional('https://example.com/feed');
    expect(res.status, FeedFetchStatus.error);
    expect(fetcher.calls.length, 1 + defaultCorsProxies.length);
  });

  test('SSRF guard applies before any fetch', () async {
    final fetcher = donorFetcher();
    await expectLater(
        feedClient(fetcher).fetchFeedConditional('http://192.168.1.10/feed'),
        throwsA(isA<UnsafeUrlException>()));
    expect(fetcher.calls, isEmpty);
  });
}
