/// The injectable HTTP seam. comms_core never talks to a socket itself —
/// the app supplies an [HttpFetcher] (dart:io, package:http, a test fake)
/// and this package supplies the hygiene: SSRF guard, consent gating,
/// mid-stream size caps, charset decoding.
///
/// Contract for implementers:
/// - Follow redirects before returning (the donor relied on `fetch`'s
///   redirect-following); re-run your own SSRF check on redirect targets.
/// - Return non-2xx statuses as a [FetchResponse]; throw only for
///   transport-level failures (DNS, TLS, timeout, connection reset).
/// - Honour [timeout] as a whole-request deadline (donor `AbortSignal.timeout`).
/// - Do not buffer the body: [FetchResponse.body] must stream, so the caps
///   in this package can abort mid-download.
library;

/// A streamed HTTP response. Header names are case-insensitive
/// (stored lowercased).
class FetchResponse {
  FetchResponse({
    required this.statusCode,
    required Map<String, String> headers,
    required this.body,
  }) : headers = Map.unmodifiable(
            {for (final e in headers.entries) e.key.toLowerCase(): e.value});

  final int statusCode;

  /// Response headers, keys lowercased.
  final Map<String, String> headers;

  /// The response body as a byte stream (single subscription).
  final Stream<List<int>> body;

  /// Mirrors `Response.ok` from the fetch API: status in [200, 299].
  bool get ok => statusCode >= 200 && statusCode < 300;

  /// Case-insensitive header lookup.
  String? header(String name) => headers[name.toLowerCase()];
}

/// The seam. Implementations live in the app layer (or a test fake).
abstract class HttpFetcher {
  Future<FetchResponse> get(Uri url,
      {Map<String, String>? headers, Duration? timeout});
}
