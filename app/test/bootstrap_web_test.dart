/// The web side of the conditional bootstrap, imported DIRECTLY (the VM can
/// compile it; only dart2js picks it via the conditional export). What these
/// tests pin: the web services object is built from web-safe parts only —
/// never DeviceServices.detached(), whose Directory.systemTemp throws on
/// dart2js the moment the app boots — and the web fetcher honours the
/// comms_core HttpFetcher contract.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:comms_core/comms_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/bootstrap/bootstrap_web.dart' as web;
import 'package:trellis/features/models/model_store.dart';
import 'package:trellis/features/transcribe/decoder.dart';
import 'package:trellis/features/transcribe/foreground_gate.dart';
import 'package:trellis/features/transcribe/transcribe_executor.dart';
import 'package:trellis/services/device_services.dart';

/// Scripted dio adapter: no socket, no channel — exercises only the
/// response-mapping code in [web.DioHttpFetcher].
class _ScriptedAdapter implements HttpClientAdapter {
  final int statusCode;
  final Map<String, List<String>> headers;
  final List<int> bytes;
  _ScriptedAdapter(this.statusCode, this.headers, this.bytes);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return ResponseBody.fromBytes(Uint8List.fromList(bytes), statusCode,
        headers: headers);
  }

  @override
  void close({bool force = false}) {}
}

/// Same as [_ScriptedAdapter], but records the [RequestOptions] it was
/// called with — what the routing tests inspect to prove the outgoing
/// request was rewritten (path, query, headers) rather than guessing from
/// the response alone.
class _CapturingAdapter implements HttpClientAdapter {
  final int statusCode;
  final Map<String, List<String>> headers;
  final List<int> bytes;
  RequestOptions? lastOptions;
  _CapturingAdapter(this.statusCode, this.headers, this.bytes);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    lastOptions = options;
    return ResponseBody.fromBytes(Uint8List.fromList(bytes), statusCode,
        headers: headers);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('web services are built from web-safe parts', () {
    final s = web.webServices();
    // No weighable database file on the web (IndexedDB/OPFS).
    expect(s.databaseFile, isNull);
    // dart2js has no isolates for our pipeline; nothing may spawn one.
    expect(s.executor, isA<InlineTranscribeExecutor>());
    expect(s.foregroundGate, isA<NoopJobForegroundGate>());
    // No ffmpeg on the web tier.
    expect(s.decoder, isA<WavPassthroughDecoder>());
    // flutter_tts has a real web implementation (speechSynthesis) — the
    // reader's speak mode is part of the web promise.
    expect(s.tts, isA<FlutterTtsSpeaker>());
    expect(s.modelStore, isA<DiskModelStore>());
  });

  test('web databaseFile is null', () async {
    expect(await web.databaseFile(), isNull);
  });

  test('web fetcher returns non-2xx as a FetchResponse, headers lowercased',
      () async {
    final dio = Dio()
      ..httpClientAdapter = _ScriptedAdapter(404, {
        'Content-Type': ['text/plain'],
      }, [
        104,
        101,
        108,
        108,
        111
      ]);
    final fetcher = web.DioHttpFetcher(dio: dio);

    final r = await fetcher.get(Uri.parse('https://example.com/feed.xml'));

    expect(r.statusCode, 404);
    expect(r.ok, isFalse);
    expect(r.headers.containsKey('content-type'), isTrue);
    expect(r.header('Content-Type'), 'text/plain');
    final total = await r.body.fold<int>(0, (n, chunk) => n + chunk.length);
    expect(total, 5);
  });

  test('web fetcher re-runs the SSRF guard before fetching', () async {
    final dio = Dio()..httpClientAdapter = _ScriptedAdapter(200, {}, []);
    final fetcher = web.DioHttpFetcher(dio: dio);
    await expectLater(fetcher.get(Uri.parse('http://192.168.1.10/feed')),
        throwsA(isA<UnsafeUrlException>()));
  });

  test('the web fetcher is what createFetcher builds', () {
    expect(web.createFetcher(), isA<web.DioHttpFetcher>());
  });

  test(
      'browser connection errors become an honest CommsException — the '
      'browser refusing a cross-site read must not surface as "site down"',
      () async {
    final dio = Dio()
      ..httpClientAdapter = _ThrowingAdapter(DioExceptionType.connectionError);
    final fetcher = web.DioHttpFetcher(dio: dio);

    await expectLater(
      fetcher.get(Uri.parse('https://example.substack.com/p/essay')),
      throwsA(isA<FetchFailedException>().having(
          (e) => e.message, 'message', contains('browser'))),
    );
  });

  test('dio timeouts honour the seam contract: TimeoutException, so the '
      '"took too long" sentences fire on web too', () async {
    for (final t in [
      DioExceptionType.connectionTimeout,
      DioExceptionType.sendTimeout,
      DioExceptionType.receiveTimeout,
    ]) {
      final dio = Dio()..httpClientAdapter = _ThrowingAdapter(t);
      final fetcher = web.DioHttpFetcher(dio: dio);
      await expectLater(
        fetcher.get(Uri.parse('https://example.org/feed.xml'),
            timeout: const Duration(seconds: 5)),
        throwsA(isA<TimeoutException>()),
        reason: '$t must map to TimeoutException',
      );
    }
  });

  // The lane probe. A relative same-origin GET, so it is
  // deliberately outside assertSafeFetchUrl's general-purpose guard (which
  // rightly refuses loopback for an attacker-controlled URL) — here the
  // path is fixed and the origin is whatever the page loaded from, so
  // there is nothing for SSRF to exploit.
  group('probeWebFetchLane', () {
    test('a Skein health response resolves the skein lane', () async {
      final dio = Dio()
        ..httpClientAdapter = _ScriptedAdapter(
            200, {}, utf8.encode('{"skein":true,"version":"0.1.0"}'));
      expect(await web.probeWebFetchLane(dio: dio), WebFetchLane.skein);
    });

    test('no daemon (connection refused) resolves the direct lane', () async {
      final dio = Dio()
        ..httpClientAdapter =
            _ThrowingAdapter(DioExceptionType.connectionError);
      expect(await web.probeWebFetchLane(dio: dio), WebFetchLane.direct);
    });

    test('a slow/absent probe times out to the direct lane, not a hang',
        () async {
      final dio = Dio()
        ..httpClientAdapter = _ThrowingAdapter(DioExceptionType.receiveTimeout);
      expect(await web.probeWebFetchLane(dio: dio), WebFetchLane.direct);
    });

    test(
        'a 200 that is NOT the health shape resolves the direct lane — the '
        'false-positive guard: a same-origin SPA fallback answering '
        '/api/health with index.html must never be read as Skein',
        () async {
      final dio = Dio()
        ..httpClientAdapter =
            _ScriptedAdapter(200, {}, utf8.encode('<html>index</html>'));
      expect(await web.probeWebFetchLane(dio: dio), WebFetchLane.direct);
    });

    test('a non-200 health response resolves the direct lane', () async {
      final dio = Dio()
        ..httpClientAdapter = _ScriptedAdapter(404, {}, utf8.encode(''));
      expect(await web.probeWebFetchLane(dio: dio), WebFetchLane.direct);
    });
  });

  test('webServices threads the resolved lane onto DeviceServices', () {
    expect(web.webServices().webFetchLane, WebFetchLane.direct);
    expect(web.webServices(lane: WebFetchLane.skein).webFetchLane,
        WebFetchLane.skein);
  });

  test('createFetcher wires the given lane onto the DioHttpFetcher it builds',
      () {
    expect(
        (web.createFetcher(lane: WebFetchLane.skein) as web.DioHttpFetcher)
            .lane,
        WebFetchLane.skein);
    expect((web.createFetcher() as web.DioHttpFetcher).lane,
        WebFetchLane.direct);
  });

  // Routing: once the lane is skein, DioHttpFetcher rewrites outgoing GETs
  // to the same-origin proxy instead of fetching the target directly.
  group('the skein lane', () {
    test('rewrites the request to /api/fetch?url=<enc>, whitelist headers '
        'only', () async {
      final adapter = _CapturingAdapter(200, {}, utf8.encode('body'));
      final dio = Dio()..httpClientAdapter = adapter;
      final fetcher = web.DioHttpFetcher(dio: dio, lane: WebFetchLane.skein);

      await fetcher.get(Uri.parse('https://example.com/feed.xml?a=b'),
          headers: const {
            'accept': 'text/html',
            'if-none-match': '"v1"',
            'cookie': 'session=hostile', // must NOT be forwarded
          });

      final sent = adapter.lastOptions!;
      expect(sent.uri.path, '/api/fetch');
      expect(sent.uri.queryParameters['url'], 'https://example.com/feed.xml?a=b');
      final sentHeaderKeys =
          sent.headers.keys.map((k) => k.toLowerCase()).toSet();
      expect(sentHeaderKeys, containsAll(['accept', 'if-none-match']));
      expect(sentHeaderKeys, isNot(contains('cookie')));
    });

    test('a normal proxied response maps to FetchResponse like the direct '
        'lane', () async {
      final dio = Dio()
        ..httpClientAdapter = _ScriptedAdapter(200, {
          'Content-Type': ['text/xml'],
        }, utf8.encode('<rss></rss>'));
      final fetcher = web.DioHttpFetcher(dio: dio, lane: WebFetchLane.skein);

      final r = await fetcher.get(Uri.parse('https://example.com/feed.xml'));

      expect(r.statusCode, 200);
      expect(r.header('content-type'), 'text/xml');
      final total = await r.body.fold<int>(0, (n, c) => n + c.length);
      expect(total, 11);
    });

    test("Skein's own refusal (x-skein-error) becomes an honest, "
        'Skein-specific sentence — never the CORS one, which would be '
        'false here', () async {
      final dio = Dio()
        ..httpClientAdapter = _ScriptedAdapter(502, {
          'x-skein-error': ['1'],
          'Content-Type': ['application/json'],
        }, utf8.encode('{"error":"That page is too large to bring in."}'));
      final fetcher = web.DioHttpFetcher(dio: dio, lane: WebFetchLane.skein);

      await expectLater(
        fetcher.get(Uri.parse('https://example.com/huge.epub')),
        throwsA(isA<FetchFailedException>()
            .having((e) => e.message, 'message', contains('Skein'))
            .having((e) => e.message, 'message',
                contains('That page is too large to bring in.'))
            .having((e) => e.message, 'message',
                isNot(contains('browser')))), // the direct-lane sentence
      );
    });

    test('Skein itself unreachable gets its own sentence, distinct from '
        "Skein reaching-but-refusing", () async {
      final dio = Dio()
        ..httpClientAdapter =
            _ThrowingAdapter(DioExceptionType.connectionError);
      final fetcher = web.DioHttpFetcher(dio: dio, lane: WebFetchLane.skein);

      await expectLater(
        fetcher.get(Uri.parse('https://example.com/feed.xml')),
        throwsA(isA<FetchFailedException>()
            .having((e) => e.message, 'message', contains('Skein'))),
      );
    });
  });
}

/// Scripted failure: throws the given dio error type, as the browser
/// adapter does for CORS-refused (connectionError) and slow (timeout)
/// fetches — no socket, no channel.
class _ThrowingAdapter implements HttpClientAdapter {
  final DioExceptionType type;
  _ThrowingAdapter(this.type);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    throw DioException(requestOptions: options, type: type);
  }

  @override
  void close({bool force = false}) {}
}
