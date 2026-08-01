/// The injectable HTTP seam for BYOK Brains. brain_wiring never touches a
/// socket — the app supplies a [BrainHttpClient] (dart:io, package:http,
/// or a test fake), the same pattern as comms_core's `HttpFetcher`.
///
/// Why not reuse comms_core's seam: `HttpFetcher` is GET-only and
/// streaming (feed hygiene needs mid-stream size caps); a messages-API
/// call is a POST with a JSON body and a small buffered reply. Two
/// different contracts, two narrow seams.
///
/// Contract for implementers:
///  * Return non-2xx statuses as a [BrainHttpResponse]; throw only for
///    transport-level failures (DNS, TLS, timeout, connection reset).
///  * Requests to a cloud host must already have passed the app's one
///    egress consent chokepoint (ADR-0003 law 6) — this seam performs
///    the call, it never grants it.
library;

/// A buffered HTTP response.
class BrainHttpResponse {
  const BrainHttpResponse({required this.statusCode, required this.body});

  final int statusCode;

  /// The decoded response body text.
  final String body;

  /// Status in [200, 299].
  bool get ok => statusCode >= 200 && statusCode < 300;
}

/// The seam. Implementations live in the app layer (or a test fake).
abstract class BrainHttpClient {
  Future<BrainHttpResponse> post(
    Uri url, {
    required Map<String, String> headers,
    required String body,
  });
}
