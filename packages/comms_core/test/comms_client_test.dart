/// Port of the donor's module-level comms tests
/// (ohPrimer rebuild/test/comms.test.mjs — SSRF guard H15, direct success
/// path, proxy gating C5, size cap H16), plus the mid-stream cap mechanics
/// the streaming seam makes possible.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:comms_core/comms_core.dart';
import 'package:test/test.dart';

import 'scripted_fetcher.dart';

void main() {
  group('SSRF guard (H15)', () {
    test('blocked URLs reject and never reach the fetcher', () async {
      final fetcher = donorFetcher();
      final client = clientWith(fetcher);
      for (final url in [
        'http://localhost:9/x',
        'http://169.254.169.254/',
        'http://127.1.2.3/x',
        'http://[::ffff:7f00:1]/x',
      ]) {
        await expectLater(client.fetchWithProxies(url),
            throwsA(isA<UnsafeUrlException>()),
            reason: url);
      }
      expect(fetcher.calls, isEmpty,
          reason: 'no fetch attempted for blocked URL');
    });
  });

  group('direct success path', () {
    test('returns direct body, no proxy used', () async {
      final fetcher = donorFetcher();
      final client = clientWith(fetcher);
      expect(await client.fetchWithProxies('https://example.com/a'), 'DIRECT');
      expect(fetcher.calls.length, 1);
      expect(isProxyUrl(fetcher.calls.single.url), isFalse,
          reason: 'no proxy used when direct works');
    });

    test('direct try uses the short 5s timeout (donor fetchT(url,5000))',
        () async {
      final fetcher = donorFetcher();
      await clientWith(fetcher).fetchWithProxies('https://example.com/a');
      expect(fetcher.calls.single.timeout, const Duration(seconds: 5));
    });
  });

  group('proxy gating (C5)', () {
    test('no consent + non-interactive refuses, no proxy host hit', () async {
      final fetcher = donorFetcher(directOk: false);
      final client = clientWith(fetcher, consent: FakeConsent());
      await expectLater(
        client.fetchWithProxies('https://example.com/a', interactive: false),
        throwsA(isA<FetchFailedException>().having((e) => e.message, 'message',
            contains('public proxies are off'))),
      );
      expect(fetcher.calls.where((c) => isProxyUrl(c.url)), isEmpty,
          reason: 'no proxy host hit without consent');
    });

    test('prior consent falls back to proxy', () async {
      final fetcher = donorFetcher(directOk: false);
      final consent = FakeConsent(prior: true);
      final client = clientWith(fetcher, consent: consent);
      expect(
          await client.fetchWithProxies('https://example.com/a',
              interactive: false),
          'PROXIED');
      expect(fetcher.calls.where((c) => isProxyUrl(c.url)), isNotEmpty,
          reason: 'proxy host hit with consent');
      expect(consent.askCount, 0, reason: 'prior consent — no dialog');
    });

    test('interactive consent grant leads to proxy', () async {
      final fetcher = donorFetcher(directOk: false);
      final consent = FakeConsent(grantOnAsk: true);
      final client = clientWith(fetcher, consent: consent);
      expect(await client.fetchWithProxies('https://example.com/a'), 'PROXIED');
      expect(consent.askCount, 1);
    });

    test('interactive consent denied throws the proxies-off message',
        () async {
      final fetcher = donorFetcher(directOk: false);
      final client = clientWith(fetcher, consent: FakeConsent());
      await expectLater(
        client.fetchWithProxies('https://example.com/a'),
        throwsA(isA<FetchFailedException>().having((e) => e.message, 'message',
            contains('public proxies are off'))),
      );
    });

    test('all proxies failing throws the blocked-by-CORS message', () async {
      final fetcher = ScriptedFetcher(
          (url, headers) => textResponse('nope', status: 500));
      final client = clientWith(fetcher, consent: FakeConsent(prior: true));
      await expectLater(
        client.fetchWithProxies('https://example.com/a'),
        throwsA(isA<FetchFailedException>().having(
            (e) => e.message, 'message', contains('Blocked by CORS'))),
      );
      // Direct once + every proxy tried.
      expect(fetcher.calls.length, 1 + defaultCorsProxies.length);
    });
  });

  group('size cap (H16) — enforced mid-stream', () {
    test('collectCapped throws before draining the stream', () async {
      var pulled = 0;
      Stream<List<int>> chunks() async* {
        for (var i = 0; i < 40; i++) {
          pulled++;
          yield Uint8List(1024 * 1024); // 1 MiB
        }
      }

      // Cap trips at chunk 26 (26 MiB > 25 MiB); the remaining chunks must
      // never be pulled.
      await expectLater(
        collectCapped(chunks(), maxBytes: 25 * 1024 * 1024),
        throwsA(isA<SizeCapException>()),
      );
      expect(pulled, lessThan(30),
          reason: 'cap must trip mid-stream, not after buffering everything');
    });

    test('collectCapped returns exactly the bytes at or under the cap',
        () async {
      final out = await collectCapped(
          Stream.fromIterable([
            [1, 2, 3],
            [4, 5],
          ]),
          maxBytes: 5);
      expect(out, [1, 2, 3, 4, 5]);
    });

    test(
        'oversized direct page surfaces SizeCapException and skips the '
        'proxy ladder entirely', () async {
      // Why: fixed donor bug — its catch swallowed the size error, retried
      // the same oversized body through every proxy, then showed the
      // unrelated "Blocked by CORS" message instead of the size cap.
      final fetcher =
          ScriptedFetcher((url, headers) => textResponse('X' * 40));
      final client = clientWith(fetcher,
          consent: FakeConsent(prior: true), maxTextBytes: 10);
      await expectLater(
        client.fetchWithProxies('https://example.com/a'),
        throwsA(isA<SizeCapException>()
            .having((e) => e.message, 'message', contains('too large'))),
      );
      expect(fetcher.calls, hasLength(1),
          reason: 'a proxy cannot shrink the body — no proxy attempted');
    });
  });

  group('fetchBinaryWithProxies', () {
    test('returns bytes and reports progress against content-length',
        () async {
      final bytes = Uint8List.fromList(List.generate(10, (i) => i));
      final fetcher = ScriptedFetcher((url, headers) => FetchResponse(
            statusCode: 200,
            headers: {
              'content-type': 'audio/mpeg',
              'content-length': '${bytes.length}',
            },
            body: Stream.fromIterable([bytes.sublist(0, 4), bytes.sublist(4)]),
          ));
      final progress = <(int?, int, int)>[];
      final result = await clientWith(fetcher).fetchBinaryWithProxies(
          'https://example.com/e.mp3',
          onProgress: (p, got, total) => progress.add((p, got, total)));
      expect(result.bytes, bytes);
      expect(result.contentType, 'audio/mpeg');
      expect(progress, [(40, 4, 10), (100, 10, 10)]);
    });

    test('progress percent is null when content-length is missing', () async {
      final fetcher = ScriptedFetcher((url, headers) => FetchResponse(
            statusCode: 200,
            headers: const {},
            body: Stream.value(const [1, 2, 3]),
          ));
      final progress = <(int?, int, int)>[];
      final result = await clientWith(fetcher).fetchBinaryWithProxies(
          'https://example.com/e.mp3',
          onProgress: (p, got, total) => progress.add((p, got, total)));
      expect(result.contentType, 'audio/mpeg',
          reason: 'donor defaults the blob type to audio/mpeg');
      expect(progress, [(null, 3, 0)]);
    });

    test('SSRF guard applies', () async {
      final fetcher = donorFetcher();
      await expectLater(
          clientWith(fetcher).fetchBinaryWithProxies('http://10.0.0.1/e.mp3'),
          throwsA(isA<UnsafeUrlException>()));
      expect(fetcher.calls, isEmpty);
    });

    test('no consent + non-interactive refuses with the donor message',
        () async {
      final fetcher =
          ScriptedFetcher((url, headers) => textResponse('x', status: 500));
      await expectLater(
        clientWith(fetcher).fetchBinaryWithProxies('https://example.com/e.mp3',
            interactive: false),
        throwsA(isA<FetchFailedException>().having((e) => e.message, 'message',
            contains('public proxies are off'))),
      );
    });

    test('audio cap trips mid-stream and surfaces SizeCapException, not the '
        'all-proxies-failed message', () async {
      // Why: fixed donor bug — the tripped cap was swallowed, every binary
      // proxy re-downloaded the oversized episode, and the user saw the
      // generic all-proxies-failed message instead of the size cap.
      var directPulled = 0;
      Stream<List<int>> bigBody() async* {
        for (var i = 0; i < 100; i++) {
          directPulled++;
          yield Uint8List(10);
        }
      }

      final fetcher = ScriptedFetcher((url, headers) => FetchResponse(
          statusCode: 200, headers: const {}, body: bigBody()));
      final client = clientWith(fetcher,
          consent: FakeConsent(prior: true), maxAudioBytes: 50);
      await expectLater(
        client.fetchBinaryWithProxies('https://example.com/e.mp3'),
        throwsA(isA<SizeCapException>()
            .having((e) => e.message, 'message', contains('cap'))),
      );
      expect(directPulled, lessThan(100),
          reason: 'cap must trip mid-stream, not after buffering everything');
      expect(fetcher.calls, hasLength(1),
          reason: 'a proxy cannot shrink the episode — no proxy attempted');
    });

    test('proxied binary success after direct failure with consent', () async {
      final fetcher = ScriptedFetcher((url, headers) => isProxyUrl(url)
          ? FetchResponse(
              statusCode: 200,
              headers: const {'content-type': 'audio/ogg'},
              body: Stream.value(const [9, 9]))
          : textResponse('no', status: 403));
      final client = clientWith(fetcher, consent: FakeConsent(prior: true));
      final result = await client
          .fetchBinaryWithProxies('https://example.com/e.mp3');
      expect(result.bytes, [9, 9]);
      expect(result.contentType, 'audio/ogg');
    });
  });

  group('proxy URL builders (donor CORS_PROXIES)', () {
    test('shapes match the donor, including encodeURIComponent', () {
      const u = 'https://example.com/a?b=c&d=e';
      expect(defaultCorsProxies[0](u), 'https://cors.eu.org/$u');
      expect(defaultCorsProxies[1](u),
          'https://api.allorigins.win/raw?url=${Uri.encodeComponent(u)}');
      expect(defaultCorsProxies[2](u),
          'https://api.codetabs.com/v1/proxy?quest=${Uri.encodeComponent(u)}');
      expect(defaultBinaryProxies.length, 2);
    });
  });

  group('FetchResponse', () {
    test('headers are case-insensitive via header()', () {
      final r = FetchResponse(
          statusCode: 200,
          headers: const {'ETag': 'W/"x"', 'Last-Modified': 'y'},
          body: const Stream.empty());
      expect(r.header('etag'), 'W/"x"');
      expect(r.header('LAST-MODIFIED'), 'y');
      expect(r.header('missing'), isNull);
    });

    test('ok mirrors the fetch() semantics', () {
      FetchResponse mk(int s) => FetchResponse(
          statusCode: s, headers: const {}, body: const Stream.empty());
      expect(mk(200).ok, isTrue);
      expect(mk(299).ok, isTrue);
      expect(mk(304).ok, isFalse);
      expect(mk(500).ok, isFalse);
    });
  });

  test('readText decodes a capped utf-8 body', () async {
    final fetcher = ScriptedFetcher((url, headers) => FetchResponse(
        statusCode: 200,
        headers: const {'content-type': 'text/html; charset=utf-8'},
        body: Stream.value(utf8.encode('héllo'))));
    expect(await clientWith(fetcher).fetchWithProxies('https://example.com/'),
        'héllo');
  });
}
