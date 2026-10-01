import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:comms_core/comms_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/app_version.dart';
import 'package:trellis/features/transcribe/audio_fetcher.dart';
import 'package:trellis/net/guarded_http_client.dart';
import 'package:trellis/net/io_fetcher.dart';

/// The dart:io [HttpFetcher] against a real loopback server — hermetic, no
/// external network. The seam contract under test (http_fetcher.dart):
/// redirects followed with the SSRF check re-run per hop, non-2xx returned
/// (not thrown), the body streamed (never buffered), timeout as the wait
/// for headers and the longest silence allowed mid-body.
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

  /// These tests talk to their own loopback server, which the default
  /// address policy rightly refuses.
  bool loopbackOk(InternetAddress a) => a.isLoopback || isPublicAddress(a);

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
    final fetcher = IoHttpFetcher(allowAddress: loopbackOk, checkRedirectTarget: permissive);
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
    final fetcher = IoHttpFetcher(allowAddress: loopbackOk, checkRedirectTarget: permissive);
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
    final fetcher = IoHttpFetcher(allowAddress: loopbackOk, checkRedirectTarget: permissive);
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
    final fetcher = IoHttpFetcher(allowAddress: loopbackOk, checkRedirectTarget: permissive);
    addTearDown(fetcher.close);

    final r = await fetcher.get(base.replace(path: '/a'));
    expect(r.statusCode, 200);
    expect(await collect(r.body), 'end of the chain');
  });

  group('a permanent move (ADR-0017)', () {
    Future<Uri?> permanentAfter(List<int> codes) async {
      await serve((req) async {
        final i = int.parse(req.uri.path.substring(1));
        if (i < codes.length) {
          req.response.statusCode = codes[i];
          req.response.headers.set('Location', '/${i + 1}');
        } else {
          req.response.write('here');
        }
        await req.response.close();
      });
      final fetcher = IoHttpFetcher(allowAddress: loopbackOk, checkRedirectTarget: permissive);
      addTearDown(fetcher.close);
      final r = await fetcher.get(base.replace(path: '/0'));
      await r.body.drain<void>();
      return r.permanentUrl;
    }

    test('an unbroken 301/308 run reports where it ended', () async {
      expect((await permanentAfter([301, 308]))?.path, '/2');
    });

    test('a temporary hop first means nothing permanent', () async {
      expect(await permanentAfter([302, 301]), isNull);
      await server.close(force: true);
      expect(await permanentAfter([307]), isNull);
    });

    test('a temporary hop after a permanent one stops the run there',
        () async {
      expect((await permanentAfter([301, 302]))?.path, '/1');
    });

    test('no redirect, no move', () async {
      expect(await permanentAfter([]), isNull);
    });
  });

  test('every request names the app in its User-Agent', () async {
    String? seen;
    await serve((req) async {
      seen = req.headers.value(HttpHeaders.userAgentHeader);
      await req.response.close();
    });
    final fetcher = IoHttpFetcher(allowAddress: loopbackOk, checkRedirectTarget: permissive);
    addTearDown(fetcher.close);
    await (await fetcher.get(base)).body.drain<void>();
    expect(seen, trellisUserAgent);
  });

  test('downloads name the app too', () async {
    String? seen;
    await serve((req) async {
      seen = req.headers.value(HttpHeaders.userAgentHeader);
      req.response.write('audio');
      await req.response.close();
    });
    final dir = Directory.systemTemp.createTempSync('trellis-ua');
    addTearDown(() => dir.deleteSync(recursive: true));
    await DioAudioFetcher(userAgent: trellisUserAgent)
        .fetch(base.replace(path: '/e.mp3').toString(), File('${dir.path}/e.mp3'));
    expect(seen, trellisUserAgent);
  });

  group('the guard at the socket (ADR-0017)', () {
    // Names resolved by a fake: no DNS, and a public-looking name can be
    // made to answer with whatever address the attack needs.
    HostResolver fake(Map<String, List<String>> table, {List<String>? log}) =>
        (host) async {
          log?.add(host);
          return [for (final a in table[host]!) InternetAddress(a)];
        };

    test('a name is connected to at the address that was checked, and '
        'keeps its Host header', () async {
      String? hostHeader;
      await serve((req) async {
        hostHeader = req.headers.value(HttpHeaders.hostHeader);
        req.response.write('ok');
        await req.response.close();
      });
      final lookups = <String>[];
      final fetcher = IoHttpFetcher(
          resolve: fake({'feed.test': ['127.0.0.1']}, log: lookups),
          allowAddress: loopbackOk);
      addTearDown(fetcher.close);
      final r = await fetcher.get(Uri.parse('http://feed.test:${server.port}/'));
      expect(await collect(r.body), 'ok');
      expect(hostHeader, 'feed.test:${server.port}');
      // One lookup, then the socket: no second answer to rebind with.
      expect(lookups, ['feed.test']);
    });

    test('a public name that resolves to the LAN is refused before any '
        'connection', () async {
      var hits = 0;
      await serve((req) async {
        hits++;
        await req.response.close();
      });
      final fetcher =
          IoHttpFetcher(resolve: fake({'evil.test': ['127.0.0.1']}));
      addTearDown(fetcher.close);
      await expectLater(
          fetcher.get(Uri.parse('http://evil.test:${server.port}/')),
          throwsA(isA<UnsafeUrlException>()));
      expect(hits, 0);
    });

    test('one private answer among public ones is refused', () async {
      await serve((req) async => req.response.close());
      final fetcher = IoHttpFetcher(
          resolve: fake({'mixed.test': ['93.184.216.34', '10.0.0.7']}));
      addTearDown(fetcher.close);
      await expectLater(fetcher.get(Uri.parse('http://mixed.test/')),
          throwsA(isA<UnsafeUrlException>()));
    });

    test('a dead first address does not hold up a live one', () async {
      // A name listing IPv6 first on a network with no IPv6 route: the
      // documentation prefix never answers, the loopback does.
      await serve((req) async {
        req.response.write('ok');
        await req.response.close();
      });
      final fetcher = IoHttpFetcher(
          resolve: fake({
            'dual.test': ['2001:db8::1', '2001:db8::2', '127.0.0.1']
          }),
          allowAddress: (_) => true);
      addTearDown(fetcher.close);
      final r = await fetcher
          .get(Uri.parse('http://dual.test:${server.port}/'))
          .timeout(const Duration(seconds: 5));
      expect(await collect(r.body), 'ok');
    });

    test('a cancelled race closes a socket that connects late and never '
        'starts the attempts still waiting', () async {
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(listener.close);
      final closedByPeer = Completer<void>();
      listener.listen((peer) => peer.listen((_) {},
          onDone: () => closedByPeer.complete(), onError: (_) {}));
      final pending = <Completer<Socket>>[];
      final race = raceForTest(
          [InternetAddress.loopbackIPv4, InternetAddress.loopbackIPv4],
          listener.port, connect: (a, p) async {
        final c = Completer<Socket>();
        pending.add(c);
        return ConnectionTask.fromSocket(c.future, () {});
      });
      final outcome = expectLater(race.socket, throwsA(isA<SocketException>()));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(pending, hasLength(1));
      race.cancel();
      pending.single.complete(
          await Socket.connect(InternetAddress.loopbackIPv4, listener.port));
      // The race closes it: the other end sees the connection end.
      await closedByPeer.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(pending, hasLength(1), reason: 'the staggered attempt never ran');
      await outcome;
    });

    test('downloads pass the same guard', () async {
      var hits = 0;
      await serve((req) async {
        hits++;
        await req.response.close();
      });
      final dir = Directory.systemTemp.createTempSync('trellis-guard');
      addTearDown(() => dir.deleteSync(recursive: true));
      final fetcher = DioAudioFetcher.guarded(
          resolve: fake({'cdn.test': ['127.0.0.1']}));
      await expectLater(
          fetcher.fetch('http://cdn.test:${server.port}/e.mp3',
              File('${dir.path}/e.mp3')),
          throwsA(anything));
      expect(hits, 0);
      expect(File('${dir.path}/e.mp3').existsSync(), isFalse);
    });

    test('a redirect hop to a name that resolves privately is refused',
        () async {
      await serve((req) async {
        req.response.statusCode = 302;
        req.response.headers
            .set('Location', 'http://inside.test:${server.port}/admin');
        await req.response.close();
      });
      final fetcher = IoHttpFetcher(
          // The lexical check passes any name; the socket guard is what
          // must catch this one.
          checkRedirectTarget: permissive,
          resolve: fake({
            'outside.test': ['127.0.0.1'],
            'inside.test': ['192.168.1.20'],
          }),
          allowAddress: loopbackOk);
      addTearDown(fetcher.close);
      await expectLater(
          fetcher.get(Uri.parse('http://outside.test:${server.port}/')),
          throwsA(isA<UnsafeUrlException>()));
    });
  });

  test('a redirect loop gives up after the hop budget', () async {
    await serve((req) async {
      req.response.statusCode = 302;
      req.response.headers.set('Location', '/loop');
      await req.response.close();
    });
    final fetcher = IoHttpFetcher(allowAddress: loopbackOk, checkRedirectTarget: permissive);
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
    // The loopback server itself must be reachable for the hop to happen.
    final fetcher = IoHttpFetcher(allowAddress: loopbackOk);
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
    final fetcher = IoHttpFetcher(allowAddress: loopbackOk, checkRedirectTarget: permissive);
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

  test('timeout bounds the wait for headers: a server that never answers',
      () async {
    await serve((req) async {
      // Never respond; hold the socket.
      await Completer<void>().future;
    });
    final fetcher = IoHttpFetcher(allowAddress: loopbackOk, checkRedirectTarget: permissive);
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
    final fetcher = IoHttpFetcher(allowAddress: loopbackOk, checkRedirectTarget: permissive);
    addTearDown(fetcher.close);

    final r = await fetcher.get(base, timeout: const Duration(milliseconds: 300));
    await expectLater(collect(r.body), throwsA(isA<TimeoutException>()));
  });

  test('a slow but steady body outlasts the timeout: only silence fails it',
      () async {
    // Why: a 20 MB feed on a weak connection takes far longer than any
    // sensible timeout, yet never goes quiet. A whole-request deadline
    // failed exactly those feeds.
    await serve((req) async {
      req.response.bufferOutput = false;
      for (var i = 0; i < 8; i++) {
        req.response.write('$i');
        await req.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await req.response.close();
    });
    final fetcher = IoHttpFetcher(allowAddress: loopbackOk, checkRedirectTarget: permissive);
    addTearDown(fetcher.close);

    final r = await fetcher.get(base, timeout: const Duration(milliseconds: 300));
    expect(await collect(r.body), '01234567');
  });

  test('a body that trickles forever still ends at the ceiling', () async {
    await serve((req) async {
      req.response.bufferOutput = false;
      while (true) {
        req.response.write('.');
        await req.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    final fetcher = IoHttpFetcher(
        allowAddress: loopbackOk,
        checkRedirectTarget: permissive,
        maxBodyTime: const Duration(milliseconds: 400));
    addTearDown(fetcher.close);

    final r = await fetcher.get(base, timeout: const Duration(milliseconds: 300));
    await expectLater(collect(r.body), throwsA(isA<TimeoutException>()));
  });
}
