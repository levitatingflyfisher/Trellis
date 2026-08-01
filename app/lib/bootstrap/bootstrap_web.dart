/// The web side of the bootstrap seam — the PWA tier of proposal-2 §1:
/// full reader/feeds/study/courses/backup, NO local ML, honest about it.
///
/// Web-safety rules this file exists to enforce:
///  * drift needs its wasm options on the web — `driftDatabase(name:)`
///    THROWS an ArgumentError there without them. The two assets they point
///    at (web/sqlite3.wasm, web/drift_worker.js) are staged in app/web/,
///    the fleet's proven pair (same drift 2.28.2 + sqlite3 2.9.4 as
///    Peckish/StillLife). Relative URIs, so a GitHub-Pages base href
///    resolves them correctly.
///  * DeviceServices.detached() is NOT web-safe: Directory.systemTemp
///    throws UnsupportedError under dart2js the moment it runs. The
///    services object here is built directly from the parts that are
///    web-safe to CONSTRUCT (dart2js stubs dart:io types; only their
///    operations throw) — and the P3 transcription flow that would operate
///    on them never starts on the web tier.
///  * No isolates (InlineTranscribeExecutor), no ffmpeg
///    (WavPassthroughDecoder), no foreground service (Noop gate). The TTS
///    engine is real: flutter_tts has a web implementation
///    (speechSynthesis), and speak mode is part of the reader promise.
library;

import 'dart:async';
import 'dart:convert' show jsonDecode, utf8;
import 'dart:io' show Directory, File;

import 'package:comms_core/comms_core.dart';
import 'package:dio/dio.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:ml_runtime/ml_runtime.dart';

import '../db/database.dart';
import '../features/models/model_store.dart';
import '../features/transcribe/audio_fetcher.dart';
import '../features/transcribe/decoder.dart';
import '../features/transcribe/foreground_gate.dart';
import '../features/transcribe/transcribe_executor.dart';
import '../services/device_services.dart';

/// drift on wasm: IndexedDB/OPFS behind the same AppDatabase.
AppDatabase createDb() => AppDatabase(driftDatabase(
      name: 'trellis',
      web: DriftWebOptions(
        sqlite3Wasm: Uri.parse('sqlite3.wasm'),
        driftWorker: Uri.parse('drift_worker.js'),
      ),
    ));

/// No weighable file on the web — the storage panel skips its row.
Future<File?> databaseFile() async => null;

/// Probes the fetch lane once, then builds the services object carrying
/// it. The probe happens here — awaited once at boot, before the first
/// frame — so every door that reads [DeviceServices.webFetchLane] sees a
/// resolved value synchronously; it is never re-run.
Future<DeviceServices> createServices() async =>
    webServices(lane: await probeWebFetchLane());

/// The web services object, from web-safe parts only. The placeholder
/// support dir is inert: constructing dart:io types is pure Dart under
/// dart2js, and no P3 flow ever operates on them on this tier.
DeviceServices webServices({WebFetchLane lane = WebFetchLane.direct}) =>
    DeviceServices(
      supportDir: Directory('/trellis'),
      modelStore: DiskModelStore(baseDir: Directory('/trellis/models')),
      registry: ModelRegistry.starter(),
      decoder: WavPassthroughDecoder(),
      audioFetcher: DioAudioFetcher(),
      executor: InlineTranscribeExecutor(),
      foregroundGate: NoopJobForegroundGate(),
      tts: FlutterTtsSpeaker(),
      databaseFile: null,
      // The honesty flag the UI doors consult: no transcribe menus, and
      // the models door opens a calm explanation instead of file ops
      // that throw under dart2js.
      localMlAvailable: false,
      engineFor: (modelPath) => WhisperEngineSpec(
          modelPath: modelPath, libraryPath: 'libwhisper.so'),
      webFetchLane: lane,
    );

/// [lane] defaults to direct so existing call sites keep compiling; main()
/// always passes the boot-resolved value from [createServices].
HttpFetcher createFetcher({WebFetchLane lane = WebFetchLane.direct}) =>
    DioHttpFetcher(lane: lane);

/// The daemon's own marker for a response IT originated (refused URL, cap
/// trip, unreachable upstream) as opposed to one proxied byte-for-byte
/// from the real upstream site. Mirrors `skeinErrorHeader` in
/// packages/skein/lib/src/fetch_route.dart — duplicated, not shared,
/// because the app bundle has no business depending on the daemon
/// package; it is a plain string constant, cheap to keep in sync by eye.
const String _skeinErrorHeader = 'x-skein-error';

/// The request-header whitelist forwarded through the skein lane — the
/// client-side half of the same whitelist the daemon enforces server-side
/// (defense in depth: a hostile page's extra headers never even leave the
/// tab).
const List<String> _skeinForwardableHeaders = [
  'accept',
  'if-none-match',
  'if-modified-since',
];

/// Same-origin probe: if a Skein daemon is serving
/// this very page, it also answers `/api/health` on the SAME origin. A
/// relative path is inherently safe from SSRF — there is no
/// attacker-controlled URL here, just "ask the origin this page came
/// from" — so this deliberately bypasses [assertSafeFetchUrl], which
/// would (rightly, for the general-purpose fetch seam) refuse a loopback
/// host outright.
///
/// One shot, ~2s timeout, never throws. [createServices] awaits this once
/// at boot and the result rides in [DeviceServices.webFetchLane] for the
/// rest of the session — this function itself has no cache, so tests stay
/// hermetic across cases.
Future<WebFetchLane> probeWebFetchLane(
    {Dio? dio, Duration timeout = const Duration(seconds: 2)}) async {
  final d = dio ?? Dio();
  try {
    final response = await d.get<String>(
      '/api/health',
      options: Options(
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
        receiveTimeout: timeout,
        sendTimeout: timeout,
      ),
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(response.data ?? '');
      if (data is Map && data['skein'] == true) return WebFetchLane.skein;
    }
  } catch (_) {
    // No daemon, a dead network, a slow/absent answer, or a 200 that
    // isn't the health shape (a same-origin SPA fallback serving
    // index.html for an unknown path, say) — all of these mean "no Skein
    // here", the browser tier's ordinary CORS-bound behavior.
  }
  return WebFetchLane.direct;
}

/// comms_core's [HttpFetcher] over dio's browser adapter.
///
/// Contract deltas vs the native IoHttpFetcher, stated honestly:
///  * Redirects are followed by the BROWSER, which hides the hops — the
///    per-hop SSRF re-check is impossible here. The initial URL is
///    re-guarded ([assertSafeFetchUrl]) as defense in depth; beyond that,
///    the browser's own cross-origin rules are the fence on this tier.
///  * The body arrives buffered (XHR), then streams to the caller — the
///    mid-download abort of comms_core's size caps degrades to
///    an after-download check on this tier.
class DioHttpFetcher implements HttpFetcher {
  DioHttpFetcher({Dio? dio, this.lane = WebFetchLane.direct})
      : _dio = dio ?? Dio();

  final Dio _dio;

  /// Resolved once at boot ([probeWebFetchLane]) and fixed for this
  /// fetcher's lifetime — never re-probed mid-request.
  final WebFetchLane lane;

  @override
  Future<FetchResponse> get(Uri url,
      {Map<String, String>? headers, Duration? timeout}) async {
    assertSafeFetchUrl(url.toString());
    if (lane == WebFetchLane.skein) {
      return _getViaSkein(url, headers: headers, timeout: timeout);
    }
    return _getDirect(url, headers: headers, timeout: timeout);
  }

  Future<FetchResponse> _getDirect(Uri url,
      {Map<String, String>? headers, Duration? timeout}) async {
    final Response<List<int>> response;
    try {
      response = await _dio.get<List<int>>(
        url.toString(),
        options: Options(
          headers: headers,
          responseType: ResponseType.bytes,
          // Non-2xx is a FetchResponse, never a throw (contract).
          validateStatus: (_) => true,
          receiveTimeout: timeout,
          sendTimeout: timeout,
        ),
      );
    } on DioException catch (e) {
      // The browser reports a CORS-refused read and a dead network with the
      // SAME opaque error (deliberately — the page must not learn which).
      // Most sites don't allow web pages to read them, so on this tier the
      // refusal is the overwhelmingly likely cause: say so honestly instead
      // of the false "site couldn't be reached".
      if (e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.unknown) {
        throw const FetchFailedException(
            'The browser blocked this fetch (or the connection failed) — '
            "sites must allow web pages to read them, and most don't. "
            'The installed app fetches directly.');
      }
      // Seam contract: slow answers surface as TimeoutException, so the
      // callers' "took too long" sentences fire on this tier too.
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        throw TimeoutException(null, timeout);
      }
      rethrow;
    }
    return _toFetchResponse(response);
  }

  /// Routes through the household daemon instead: a relative same-origin
  /// request, so CORS never applies. Only the request-header whitelist
  /// travels (defense in depth — the daemon enforces the real whitelist
  /// server-side regardless); Skein's own refusals (marked by
  /// [_skeinErrorHeader]) become a Skein-specific sentence, never the
  /// direct lane's CORS wording, which would be false here — the fetch
  /// never touched the browser's cross-origin machinery at all.
  Future<FetchResponse> _getViaSkein(Uri url,
      {Map<String, String>? headers, Duration? timeout}) async {
    final forwarded = <String, String>{};
    headers?.forEach((name, value) {
      if (_skeinForwardableHeaders.contains(name.toLowerCase())) {
        forwarded[name] = value;
      }
    });

    final Response<List<int>> response;
    try {
      response = await _dio.get<List<int>>(
        '/api/fetch',
        queryParameters: {'url': url.toString()},
        options: Options(
          headers: forwarded,
          responseType: ResponseType.bytes,
          validateStatus: (_) => true,
          receiveTimeout: timeout,
          sendTimeout: timeout,
        ),
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        throw TimeoutException(null, timeout);
      }
      // The daemon itself didn't answer — distinct from Skein answering
      // and refusing (below): here there is no upstream sentence to relay.
      throw const FetchFailedException(
          "Your Skein couldn't be reached — is it still running?");
    }

    if (response.headers.value(_skeinErrorHeader) != null) {
      throw FetchFailedException("Your Skein couldn't reach that address — "
          '${_skeinRefusalMessage(response.data)}');
    }
    return _toFetchResponse(response);
  }

  static String _skeinRefusalMessage(List<int>? bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes ?? const []));
      if (decoded is Map && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } catch (_) {
      // Fall through to the generic sentence below.
    }
    return 'it refused the address.';
  }

  static FetchResponse _toFetchResponse(Response<List<int>> response) {
    final flat = <String, String>{
      for (final e in response.headers.map.entries) e.key: e.value.join(', ')
    };
    return FetchResponse(
      statusCode: response.statusCode ?? 0,
      headers: flat,
      body: Stream.value(response.data ?? const <int>[]),
    );
  }
}
