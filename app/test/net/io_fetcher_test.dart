import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:comms_core/comms_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/net/io_fetcher.dart';

/// The dart:io [HttpFetcher] against a real loopback server — hermetic, no
/// external network. The seam contract under test (http_fetcher.dart):
/// redirects followed with the SSRF check re-run per hop, non-2xx returned
/// (not thrown), the body streamed (never buffered), timeout as a
/// whole-request deadline.
void main() {
  // The canonical flutter_test_config initializes the widgets binding for
  // every suite, and the binding swaps HttpClient for a 400-refusing mock
  // so no test can egress by accident. THIS suite speaks real HTTP to a
  // loopback server it starts itself — loopback is not egress — so the
  // guard is lifted for this file alone.
  setUpAll(() => HttpOverrides.global = null);

  late HttpServer server;
  late Uri base;

  /// A permissive redirect check for mechanics tests — the default check
  /// correctly refuses loopback (tested separately below).
  Uri permissive(String raw) => Uri.parse(raw);

  Future<void> serve(
      Future<void> Function(HttpRequest request) handler) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen((req) async {
      try {
        await handler(req);
      } catch (_) {
        try {
          await req.response.close();
        } catch (_) {}
      }
    });
  }

  tearDown(() async {
    await server.close(force: true);
  });

  Future<String> collect(Stream<List<int>> body) async =>
      utf8.decode([for (final chunk in await body.toList()) ...chunk]);

  test('status, lowercased headers, and body come through', () async {
    await serve((req) async {
      req.response.statusCode = 200;
      req.response.headers.set('X-Trellis-Test', 'yes');
      req.response.write('hello');
      await req.response.close();
    });
    final fetcher = IoHttpFetcher(checkRedirectTarget: permissive);
    addTearDown(fetcher.close);

    final r = await fetcher.get(base.replace(path: '/'));
    expect(r.statusCode, 200);
    expect(r.header('x-trellis-test'), 'yes');
    expect(await collect(r.body), 'hello');
  });

  test('a non-2xx status is returned as a response, not thrown', () async {
    await serve((req) async {
      req.response.statusCode = 404;
      req.response.write('gone');
      await req.response.close();
    });
    final fetcher = IoHttpFetcher(checkRedirectTarget: permissive);
    addTearDown(fetcher.close);

    final r = await fetcher.get(base);
    expect(r.statusCode, 404);
    expect(r.ok, isFalse);
  });

  test('request headers are forwarded (conditional GET)', () async {
    await serve((req) async {
      req.response.statusCode =
          req.headers.value('If-None-Match') == '"v1"' ? 304 : 200;
      await req.response.close();
    });
    final fetcher = IoHttpFetcher(checkRedirectTarget: permissive);
    addTearDown(fetcher.close);

    final r = await fetcher.get(base, headers: {'If-None-Match': '"v1"'});
    expect(r.statusCode, 304);
  });

  test('redirects are followed before returning', () async {
    await serve((req) async {
      if (req.uri.path == '/a') {
        req.response.statusCode = 302;
        req.response.headers.set('Location', '/b');
      } else if (req.uri.path == '/b') {
        req.response.statusCode = 301;
        req.response.headers.set('Location', base.replace(path: '/c').toString());
      } else {
        req.response.write('end of the chain');
      }
      await req.response.close();
    });
    final fetcher = IoHttpFetcher(checkRedirectTarget: permissive);
    addTearDown(fetcher.close);

    final r = await fetcher.get(base.replace(path: '/a'));
    expect(r.statusCode, 200);
    expect(await collect(r.body), 'end of the chain');
  });

  test('a redirect loop gives up after the hop budget', () async {
    await serve((req) async {
      req.response.statusCode = 302;
      req.response.headers.set('Location', '/loop');
      await req.response.close();
    });
    final fetcher = IoHttpFetcher(checkRedirectTarget: permissive);
    addTearDown(fetcher.close);

    await expectLater(
        fetcher.get(base.replace(path: '/loop')),
        throwsA(isA<FetchFailedException>()));
  });

  test('the DEFAULT redirect check re-runs the SSRF guard per hop: a hop '
      'onto the loopback is refused', () async {
    await serve((req) async {
      req.response.statusCode = 302;
      // A malicious host redirecting the native app into the LAN/loopback.
      req.response.headers
          .set('Location', base.replace(path: '/internal').toString());
      await req.response.close();
    });
    final fetcher = IoHttpFetcher(); // default = assertSafeFetchUrl
    addTearDown(fetcher.close);

    // The INITIAL url is the caller's responsibility (comms_core guards
    // it); the fetcher's own duty is every subsequent hop.
    await expectLater(fetcher.get(base.replace(path: '/out')),
        throwsA(isA<UnsafeUrlException>()));
  });

  test('the body STREAMS — the first chunk arrives while the server still '
      'holds the connection open', () async {
    final gate = Completer<void>();
    await serve((req) async {
      req.response.bufferOutput = false;
      req.response.write('first');
      await req.response.flush();
      await gate.future; // held open until the test saw "first"
      req.response.write('rest');
      await req.response.close();
    });
    final fetcher = IoHttpFetcher(checkRedirectTarget: permissive);
    addTearDown(fetcher.close);

    // A buffering implementation would hang here awaiting the full body.
    final r = await fetcher.get(base).timeout(const Duration(seconds: 5));
    final it = StreamIterator(r.body);
    final received = StringBuffer();
    await it.moveNext();
    received.write(utf8.decode(it.current));
    expect(received.toString(), startsWith('first'));
    gate.complete();
    while (await it.moveNext()) {
      received.write(utf8.decode(it.current));
    }
    expect(received.toString(), 'firstrest');
  });

  test('timeout is a whole-request deadline: a server that never answers',
      () async {
    await serve((req) async {
      // Never respond; hold the socket.
      await Completer<void>().future;
    });
    final fetcher = IoHttpFetcher(checkRedirectTarget: permissive);
    addTearDown(fetcher.close);

    await expectLater(
        fetcher.get(base, timeout: const Duration(milliseconds: 300)),
        throwsA(isA<TimeoutException>()));
  });

  test('timeout covers the body too: headers sent, body stalled', () async {
    await serve((req) async {
      req.response.bufferOutput = false;
      req.response.write('start');
      await req.response.flush();
      await Completer<void>().future; // stall forever mid-body
    });
    final fetcher = IoHttpFetcher(checkRedirectTarget: permissive);
    addTearDown(fetcher.close);

    final r = await fetcher.get(base, timeout: const Duration(milliseconds: 300));
    await expectLater(collect(r.body), throwsA(isA<TimeoutException>()));
  });
}
