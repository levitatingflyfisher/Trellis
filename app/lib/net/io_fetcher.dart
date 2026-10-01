/// The native dart:io implementation of comms_core's [HttpFetcher] seam.
///
/// Contract (http_fetcher.dart), honoured here:
/// - Redirects are followed before returning, and the SSRF guard is re-run
///   on EVERY hop target — a public host must not be able to bounce the
///   native app into the LAN. safe_url.dart is lexical; the client
///   underneath (guarded_http_client.dart) checks every address a name
///   resolves to, and connects only to the address it checked.
/// - An unbroken run of 301/308 hops is reported as
///   [FetchResponse.permanentUrl], so a moved feed can be followed.
/// - Non-2xx statuses come back as a [FetchResponse]; only transport-level
///   failures throw.
/// - [timeout] bounds the wait for headers, then the longest silence allowed
///   while the body streams; [maxBodyTime] caps the body as a whole.
/// - The body is never buffered: callers stream it so comms_core's
///   mid-stream size caps can abort a download.
library;

import 'dart:async';
import 'dart:io';

import 'package:comms_core/comms_core.dart';

import '../app_version.dart';
import 'guarded_http_client.dart';

class IoHttpFetcher implements HttpFetcher {
  /// [resolve] and [allowAddress] reach the socket-level guard
  /// (guarded_http_client.dart); the defaults are real DNS and
  /// comms_core's blocklist.
  IoHttpFetcher(
      {Uri Function(String rawUrl)? checkRedirectTarget,
      this.maxBodyTime = const Duration(minutes: 3),
      HostResolver? resolve,
      AddressPolicy allowAddress = isPublicAddress})
      : _checkRedirectTarget = checkRedirectTarget ?? assertSafeFetchUrl,
        _client = resolve == null
            ? guardedHttpClient(allow: allowAddress)
            : guardedHttpClient(resolve: resolve, allow: allowAddress) {
    _client.autoUncompress = true;
    _client.userAgent = trellisUserAgent;
  }

  /// SSRF re-check applied to every redirect target. Defaults to
  /// comms_core's [assertSafeFetchUrl]; injectable so hermetic loopback
  /// tests can exercise the redirect mechanics.
  final Uri Function(String rawUrl) _checkRedirectTarget;

  final HttpClient _client;

  /// The whole body's ceiling, so a server trickling a byte at a time can't
  /// hold a refresh forever. Three minutes carries a 25 MB feed at about
  /// 140 KB/s.
  final Duration maxBodyTime;

  /// One hop budget for the whole chain (browsers use 20; feeds never
  /// legitimately need more than a handful).
  static const int maxRedirects = 5;

  void close() => _client.close(force: true);

  @override
  Future<FetchResponse> get(Uri url,
      {Map<String, String>? headers, Duration? timeout}) async {
    final deadline = timeout == null ? null : DateTime.now().add(timeout);

    Duration remaining() {
      if (deadline == null) return const Duration(days: 365);
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        throw TimeoutException('Request deadline exceeded', timeout);
      }
      return left;
    }

    var current = url;
    Uri? permanent;
    var unbroken = true;
    for (var hop = 0; hop <= maxRedirects; hop++) {
      final request = await _client.getUrl(current).timeout(remaining());
      request.followRedirects = false; // hops are ours, so the guard runs
      headers?.forEach(request.headers.set);
      final response = await request.close().timeout(remaining());

      if (_isRedirect(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (location == null || location.isEmpty) {
          throw const FetchFailedException(
              'Redirect response carried no Location header.');
        }
        // Resolve relative targets, then re-run the SSRF guard on the hop.
        current = _checkRedirectTarget(current.resolve(location).toString());
        final isPermanent =
            response.statusCode == 301 || response.statusCode == 308;
        unbroken = unbroken && isPermanent;
        if (unbroken) permanent = current;
        continue;
      }

      return FetchResponse(
        statusCode: response.statusCode,
        headers: _flattenHeaders(response.headers),
        permanentUrl: permanent,
        body: timeout == null
            ? response
            : _stallBound(response, stall: timeout, ceiling: maxBodyTime),
      );
    }
    throw const FetchFailedException('Too many redirects.');
  }

  static bool _isRedirect(int status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;

  static Map<String, String> _flattenHeaders(HttpHeaders headers) {
    final out = <String, String>{};
    headers.forEach((name, values) => out[name] = values.join(', '));
    return out;
  }

  /// Wraps the body so it fails when the server goes quiet for [stall], or
  /// when the whole body takes longer than [ceiling]. A steady slow download
  /// is fine: a 20 MB feed on a weak connection is slow but never silent,
  /// and a whole-request deadline failed exactly those feeds.
  static Stream<List<int>> _stallBound(Stream<List<int>> src,
      {required Duration stall, required Duration ceiling}) {
    final controller = StreamController<List<int>>();
    late StreamSubscription<List<int>> sub;
    Timer? quiet;
    Timer? whole;

    void fail(String why) {
      quiet?.cancel();
      whole?.cancel();
      sub.cancel();
      controller.addError(TimeoutException(why));
      controller.close();
    }

    void armQuiet() {
      quiet?.cancel();
      quiet = Timer(stall, () => fail('The server stopped sending'));
    }

    controller.onListen = () {
      whole = Timer(ceiling, () => fail('The body took too long'));
      armQuiet();
      sub = src.listen(
        (chunk) {
          armQuiet();
          controller.add(chunk);
        },
        onError: (Object e, StackTrace st) => controller.addError(e, st),
        onDone: () {
          quiet?.cancel();
          whole?.cancel();
          controller.close();
        },
      );
    };
    // A paused reader is not a silent server.
    controller.onPause = () {
      quiet?.cancel();
      sub.pause();
    };
    controller.onResume = () {
      sub.resume();
      armQuiet();
    };
    controller.onCancel = () {
      quiet?.cancel();
      whole?.cancel();
      return sub.cancel();
    };
    return controller.stream;
  }
}
