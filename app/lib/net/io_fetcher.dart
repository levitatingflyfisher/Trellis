/// The native dart:io implementation of comms_core's [HttpFetcher] seam.
///
/// Contract (http_fetcher.dart), honoured here:
/// - Redirects are followed before returning, and the SSRF guard is re-run
///   on EVERY hop target — a public host must not be able to bounce the
///   native app into the LAN (safe_url.dart is lexical; the hop re-check is
///   this layer's duty).
/// - Non-2xx statuses come back as a [FetchResponse]; only transport-level
///   failures throw.
/// - [timeout] is a whole-request deadline covering headers AND body.
/// - The body is never buffered: callers stream it so comms_core's
///   mid-stream size caps can abort a download.
library;

import 'dart:async';
import 'dart:io';

import 'package:comms_core/comms_core.dart';

class IoHttpFetcher implements HttpFetcher {
  IoHttpFetcher({Uri Function(String rawUrl)? checkRedirectTarget})
      : _checkRedirectTarget = checkRedirectTarget ?? assertSafeFetchUrl,
        _client = HttpClient() {
    _client.autoUncompress = true;
  }

  /// SSRF re-check applied to every redirect target. Defaults to
  /// comms_core's [assertSafeFetchUrl]; injectable so hermetic loopback
  /// tests can exercise the redirect mechanics.
  final Uri Function(String rawUrl) _checkRedirectTarget;

  final HttpClient _client;

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
        continue;
      }

      return FetchResponse(
        statusCode: response.statusCode,
        headers: _flattenHeaders(response.headers),
        body: deadline == null
            ? response
            : _deadlineBound(response, deadline),
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

  /// Wraps the body so the whole-request deadline keeps running while the
  /// server dribbles (or stalls) the response.
  static Stream<List<int>> _deadlineBound(
      Stream<List<int>> src, DateTime deadline) {
    final controller = StreamController<List<int>>();
    late StreamSubscription<List<int>> sub;
    Timer? timer;

    void closeWith([Object? error]) {
      timer?.cancel();
      sub.cancel();
      if (error != null) controller.addError(error);
      controller.close();
    }

    controller.onListen = () {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        controller.addError(
            TimeoutException('Request deadline exceeded'));
        controller.close();
        return;
      }
      timer = Timer(left, () {
        closeWith(TimeoutException('Request deadline exceeded'));
      });
      sub = src.listen(
        controller.add,
        onError: (Object e, StackTrace st) => controller.addError(e, st),
        onDone: () {
          timer?.cancel();
          controller.close();
        },
      );
    };
    controller.onCancel = () {
      timer?.cancel();
      return sub.cancel();
    };
    return controller.stream;
  }
}
