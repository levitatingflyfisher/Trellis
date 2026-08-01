/// `/api/fetch` (laws 3, 4, 6): SSRF-guarded both ends, byte-capped,
/// header-whitelisted, conditional GET kept working. Real loopback servers
/// throughout — fine in this pure-Dart package.
///
/// The guard tension: the REAL [assertSafeFetchUrl] blocks ALL loopback
/// hosts, including any test upstream server this file starts — and since
/// this Phase's resolve-time classifier ALSO refuses loopback (by design,
/// unconditionally), every mechanics test now needs BOTH the lexical guard
/// AND the resolve-time classifier admitted for this file's own upstream.
/// Mechanics tests (does the proxy forward correctly, follow redirects,
/// enforce the cap) inject a permissive version of both — the
/// io_fetcher_test.dart precedent, extended to the new layer. The tests
/// that must prove the REAL guards are wired use constructions that never
/// need either to admit a loopback address: a fabricated private IP for
/// the lexical initial-url case (the guard throws before any I/O — no
/// server needed), a fake resolver for the resolve-time cases (no real DNS
/// needed), and a HYBRID override for the redirect-hop cases (admits only
/// this file's own upstream, defers to the real function for everything
/// else) so the hop decision is made by production code.
import 'dart:convert';
import 'dart:io';

import 'package:comms_core/comms_core.dart' show assertSafeFetchUrl;
import 'package:skein/skein.dart';
import 'package:test/test.dart';

void main() {
  late Directory webRoot;
  late HttpServer upstream;
  late Uri upstreamBase;

  setUp(() {
    webRoot = Directory.systemTemp.createTempSync('skein-webroot-fetch');
  });

  tearDown(() async {
    webRoot.deleteSync(recursive: true);
    await upstream.close(force: true);
  });

  Future<void> serveUpstream(
      Future<void> Function(HttpRequest request) handler) async {
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstreamBase = Uri.parse('http://127.0.0.1:${upstream.port}');
    upstream.listen((req) async {
      try {
        await handler(req);
      } catch (_) {
        try {
          await req.response.close();
        } catch (_) {}
      }
    });
  }

  Uri permissive(String raw) => Uri.parse(raw);

  /// The resolve-time classifier's permissive stand-in for mechanics
  /// tests — nothing is ever unsafe. Real classification is proven
  /// separately in host_guard_test.dart (the pure function) and in this
  /// file's own "resolve-time SSRF" group (the wiring, with the real
  /// function).
  bool neverUnsafe(InternetAddress addr) => false;

  Future<SkeinServer> startSkein(
      {int maxFetchBytes = skeinMaxFetchBytes,
      Uri Function(String raw)? urlGuard,
      HostResolver? resolver,
      bool Function(InternetAddress)? isUnsafeAddress}) async {
    final s = SkeinServer(
        webRoot: webRoot,
        port: 0,
        maxFetchBytes: maxFetchBytes,
        urlGuard: urlGuard,
        resolver: resolver,
        isUnsafeAddress: isUnsafeAddress);
    await s.start();
    return s;
  }

  Uri fetchUrl(SkeinServer skein, String target) =>
      Uri.parse('http://127.0.0.1:${skein.boundPort}').replace(
          path: '/api/fetch', queryParameters: {'url': target});

  Future<Map<String, dynamic>> jsonBody(HttpClientResponse resp) async =>
      jsonDecode(await resp.transform(utf8.decoder).join())
          as Map<String, dynamic>;

  test('proxies status, whitelisted headers and the body', () async {
    await serveUpstream((req) async {
      req.response.statusCode = 200;
      req.response.headers.set('content-type', 'text/plain');
      req.response.headers.set('etag', '"abc"');
      req.response.headers.set('x-powered-by', 'nope'); // not whitelisted
      req.response.write('hello from upstream');
      await req.response.close();
    });
    final skein =
        await startSkein(urlGuard: permissive, isUnsafeAddress: neverUnsafe);
    addTearDown(skein.close);

    final client = HttpClient();
    final req = await client.getUrl(fetchUrl(skein, upstreamBase.toString()));
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();

    expect(resp.statusCode, 200);
    expect(body, 'hello from upstream');
    expect(resp.headers.value('content-type'), contains('text/plain'));
    expect(resp.headers.value('etag'), '"abc"');
    expect(resp.headers.value('x-powered-by'), isNull);
    expect(resp.headers.value(skeinErrorHeader), isNull);
    client.close(force: true);
  });

  test(
      'forwards only the request-header whitelist, stamped with '
      "Skein's own User-Agent", () async {
    String? seenAccept, seenUA, seenCookie;
    await serveUpstream((req) async {
      seenAccept = req.headers.value('accept');
      seenUA = req.headers.value('user-agent');
      seenCookie = req.headers.value('cookie');
      req.response.write('ok');
      await req.response.close();
    });
    final skein =
        await startSkein(urlGuard: permissive, isUnsafeAddress: neverUnsafe);
    addTearDown(skein.close);

    final client = HttpClient();
    final req = await client.getUrl(fetchUrl(skein, upstreamBase.toString()));
    req.headers.set('accept', 'text/html');
    req.headers.set('cookie', 'session=hostile'); // must NOT be forwarded
    final resp = await req.close();
    await resp.drain<void>();

    expect(seenAccept, 'text/html');
    expect(seenUA, startsWith('trellis-skein/'));
    expect(seenCookie, isNull);
    client.close(force: true);
  });

  test('conditional GET: If-None-Match forwarded, 304 passes through untouched',
      () async {
    await serveUpstream((req) async {
      if (req.headers.value('if-none-match') == '"v1"') {
        req.response.statusCode = 304;
        await req.response.close();
      } else {
        req.response.statusCode = 200;
        req.response.write('fresh');
        await req.response.close();
      }
    });
    final skein =
        await startSkein(urlGuard: permissive, isUnsafeAddress: neverUnsafe);
    addTearDown(skein.close);

    final client = HttpClient();
    final req = await client.getUrl(fetchUrl(skein, upstreamBase.toString()));
    req.headers.set('if-none-match', '"v1"');
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();

    expect(resp.statusCode, 304);
    expect(body, isEmpty);
    client.close(force: true);
  });

  test('a non-2xx upstream status passes through as-is, not a Skein error',
      () async {
    await serveUpstream((req) async {
      req.response.statusCode = 404;
      req.response.write('not found upstream');
      await req.response.close();
    });
    final skein =
        await startSkein(urlGuard: permissive, isUnsafeAddress: neverUnsafe);
    addTearDown(skein.close);

    final client = HttpClient();
    final req = await client.getUrl(fetchUrl(skein, upstreamBase.toString()));
    final resp = await req.close();
    await resp.drain<void>();

    expect(resp.statusCode, 404);
    expect(resp.headers.value(skeinErrorHeader), isNull);
    client.close(force: true);
  });

  test('follows redirects and delivers the final body', () async {
    await serveUpstream((req) async {
      if (req.uri.path == '/a') {
        req.response.statusCode = 302;
        req.response.headers.set('location', '/b');
        await req.response.close();
      } else {
        req.response.statusCode = 200;
        req.response.write('end of chain');
        await req.response.close();
      }
    });
    final skein =
        await startSkein(urlGuard: permissive, isUnsafeAddress: neverUnsafe);
    addTearDown(skein.close);

    final client = HttpClient();
    final req = await client.getUrl(
        fetchUrl(skein, upstreamBase.replace(path: '/a').toString()));
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();

    expect(resp.statusCode, 200);
    expect(body, 'end of chain');
    client.close(force: true);
  });

  test('a redirect loop gives up after the hop budget with a Skein error',
      () async {
    await serveUpstream((req) async {
      req.response.statusCode = 302;
      req.response.headers.set('location', '/loop');
      await req.response.close();
    });
    final skein =
        await startSkein(urlGuard: permissive, isUnsafeAddress: neverUnsafe);
    addTearDown(skein.close);

    final client = HttpClient();
    final req = await client.getUrl(
        fetchUrl(skein, upstreamBase.replace(path: '/loop').toString()));
    final resp = await req.close();
    final body = await jsonBody(resp);

    expect(resp.statusCode, 502);
    expect(resp.headers.value(skeinErrorHeader), '1');
    expect(body['error'], isA<String>());
    client.close(force: true);
  });

  test(
      'a response over the byte cap is refused with a Skein error — the '
      'oversized body never arrives', () async {
    await serveUpstream((req) async {
      req.response.bufferOutput = false;
      req.response.statusCode = 200;
      for (var i = 0; i < 5; i++) {
        req.response.write('0123456789'); // 50 bytes total
        await req.response.flush();
      }
      await req.response.close();
    });
    final skein = await startSkein(
        maxFetchBytes: 10, urlGuard: permissive, isUnsafeAddress: neverUnsafe);
    addTearDown(skein.close);

    final client = HttpClient();
    final req = await client.getUrl(fetchUrl(skein, upstreamBase.toString()));
    final resp = await req.close();
    final raw = await resp.transform(utf8.decoder).join();

    expect(resp.statusCode, 502);
    expect(resp.headers.value(skeinErrorHeader), '1');
    final body = jsonDecode(raw) as Map<String, dynamic>;
    expect(body['error'], isA<String>());
    expect(raw, isNot(contains('0123456789')));
    client.close(force: true);
  });

  test('a missing url parameter is refused with a sentence', () async {
    final skein =
        await startSkein(urlGuard: permissive, isUnsafeAddress: neverUnsafe);
    addTearDown(skein.close);

    final client = HttpClient();
    final req = await client
        .getUrl(Uri.parse('http://127.0.0.1:${skein.boundPort}/api/fetch'));
    final resp = await req.close();
    final body = await jsonBody(resp);

    expect(resp.statusCode, 400);
    expect(resp.headers.value(skeinErrorHeader), '1');
    expect(body['error'], isA<String>());
    client.close(force: true);
  });

  test('the DEFAULT guard refuses an unsafe initial url (no server needed — '
      'the guard throws before any I/O)', () async {
    final skein = await startSkein(); // real assertSafeFetchUrl, default
    addTearDown(skein.close);

    final client = HttpClient();
    final req =
        await client.getUrl(fetchUrl(skein, 'http://192.168.1.5/router'));
    final resp = await req.close();
    final body = await jsonBody(resp);

    expect(resp.statusCode, 400);
    expect(resp.headers.value(skeinErrorHeader), '1');
    expect(body['error'], isA<String>());
    client.close(force: true);
  });

  test(
      'THE classic proxy-SSRF attack: a redirect hop onto a private target '
      'is refused by the REAL guard, the private target never contacted',
      () async {
    await serveUpstream((req) async {
      if (req.uri.path == '/lure') {
        req.response.statusCode = 302;
        // A compromised/malicious site bouncing Skein at the LAN.
        req.response.headers.set('location', 'http://192.168.50.7/admin');
        await req.response.close();
      }
    });
    // Admits only this file's own loopback upstream so the redirect can be
    // issued at all; every OTHER hop target — including the lure's
    // location — is decided by the real production guard. The redirect
    // target is refused at the LEXICAL layer (a private literal IP), so
    // the resolve-time classifier never even runs for that hop — but the
    // INITIAL hop's resolve-time check still needs the same admission, or
    // it would refuse the (loopback) upstream before the redirect is ever
    // issued.
    final skein = await startSkein(
      urlGuard: (raw) {
        final u = Uri.parse(raw);
        if (u.host == '127.0.0.1') return u;
        return assertSafeFetchUrl(raw);
      },
      isUnsafeAddress: (addr) =>
          addr.address == '127.0.0.1' ? false : isUnsafeResolvedAddress(addr),
    );
    addTearDown(skein.close);

    final client = HttpClient();
    final req = await client.getUrl(
        fetchUrl(skein, upstreamBase.replace(path: '/lure').toString()));
    final resp = await req.close();
    final body = await jsonBody(resp);

    expect(resp.statusCode, 400);
    expect(resp.headers.value(skeinErrorHeader), '1');
    expect(body['error'], isA<String>());
    client.close(force: true);
  });

  // Resolve-time SSRF hardening: the lexical guard cannot see DNS, so a
  // public-looking HOSTNAME that resolves to a private/loopback address
  // slips past it entirely (DNS rebinding). These tests inject a fake
  // resolver — no real DNS anywhere — and use the REAL classifier
  // (isUnsafeResolvedAddress), proving the wiring with production logic,
  // matching this file's existing hybrid-guard idiom.
  group('resolve-time SSRF (DNS rebinding)', () {
    test('a hostname resolving to 127.0.0.1 is refused, no server needed — '
        'classification throws before any connection is attempted',
        () async {
      final skein = await startSkein(
        resolver: (host) async => [InternetAddress('127.0.0.1')],
      );
      addTearDown(skein.close);

      final client = HttpClient();
      final req = await client
          .getUrl(fetchUrl(skein, 'http://rebinds-to-loopback.test/secret'));
      final resp = await req.close();
      final body = await jsonBody(resp);

      expect(resp.statusCode, 400);
      expect(resp.headers.value(skeinErrorHeader), '1');
      expect(body['error'], isA<String>());
      client.close(force: true);
    });

    test('a hostname resolving to a private LAN address is refused',
        () async {
      final skein = await startSkein(
        resolver: (host) async => [InternetAddress('192.168.50.7')],
      );
      addTearDown(skein.close);

      final client = HttpClient();
      final req = await client
          .getUrl(fetchUrl(skein, 'http://rebinds-to-lan.test/secret'));
      final resp = await req.close();
      final body = await jsonBody(resp);

      expect(resp.statusCode, 400);
      expect(resp.headers.value(skeinErrorHeader), '1');
      expect(body['error'], isA<String>());
      client.close(force: true);
    });

    test(
        'a hostname resolving to a public-looking address still fetches — '
        'the resolved address is what gets connected to, and a passing '
        'classification does not block the plumbing', () async {
      await serveUpstream((req) async {
        req.response.write('reached via the resolved address');
        await req.response.close();
      });
      // The resolver is genuinely exercised (maps the fake hostname to
      // THIS file's loopback upstream); the classifier is the permissive
      // stand-in ONLY because a real loopback test fixture can never pass
      // the real classifier by definition — the real classifier's refusal
      // behavior is proven by the two tests above and by
      // host_guard_test.dart.
      final skein = await startSkein(
        resolver: (host) async => [InternetAddress('127.0.0.1')],
        isUnsafeAddress: neverUnsafe,
      );
      addTearDown(skein.close);

      final client = HttpClient();
      final req = await client.getUrl(fetchUrl(
          skein,
          upstreamBase.replace(host: 'looks-public.test').toString()));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();

      expect(resp.statusCode, 200);
      expect(body, 'reached via the resolved address');
      client.close(force: true);
    });

    test(
        'a redirect hop to a hostname that resolves to a private address is '
        'refused — the full sequence (lexical guard, lookup, classify) '
        'repeats per hop, not just on the first one', () async {
      await serveUpstream((req) async {
        if (req.uri.path == '/lure') {
          req.response.statusCode = 302;
          req.response.headers
              .set('location', 'http://rebinds-mid-chain.test/secret');
          await req.response.close();
        }
      });
      final skein = await startSkein(
        // The lexical guard passes both hostnames through unexamined —
        // neither is numeric nor carries a blocked suffix; the resolver
        // is what reveals the second one is unsafe.
        urlGuard: permissive,
        resolver: (host) async => host == 'rebinds-mid-chain.test'
            ? [InternetAddress('10.1.2.3')]
            : [InternetAddress('127.0.0.1')],
        // Admits only this file's own upstream so the FIRST hop's
        // resolve-time check passes; the second hop is judged for real.
        isUnsafeAddress: (addr) => addr.address == '127.0.0.1'
            ? false
            : isUnsafeResolvedAddress(addr),
      );
      addTearDown(skein.close);

      final client = HttpClient();
      final req = await client.getUrl(
          fetchUrl(skein, upstreamBase.replace(path: '/lure').toString()));
      final resp = await req.close();
      final body = await jsonBody(resp);

      expect(resp.statusCode, 400);
      expect(resp.headers.value(skeinErrorHeader), '1');
      expect(body['error'], isA<String>());
      client.close(force: true);
    });
  });
}
