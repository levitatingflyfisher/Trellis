/// App-side scripted fake for the comms_core HttpFetcher seam — no network
/// ever runs in tests. Mirrors comms_core's own test double (its test/ dir
/// is not importable from here by design).
library;

import 'dart:async';
import 'dart:convert';

import 'package:comms_core/comms_core.dart';

class RecordedCall {
  RecordedCall(this.url, this.headers, this.timeout);
  final Uri url;
  final Map<String, String>? headers;
  final Duration? timeout;
}

/// A single-chunk text response.
FetchResponse textResponse(
  String body, {
  int status = 200,
  Map<String, String> headers = const {},
}) {
  return FetchResponse(
    statusCode: status,
    headers: {'content-type': 'text/xml; charset=utf-8', ...headers},
    body: Stream.value(utf8.encode(body)),
  );
}

class ScriptedFetcher implements HttpFetcher {
  ScriptedFetcher(this._handler);

  final FutureOr<FetchResponse> Function(Uri url, Map<String, String>? headers)
      _handler;
  final List<RecordedCall> calls = [];

  @override
  Future<FetchResponse> get(Uri url,
      {Map<String, String>? headers, Duration? timeout}) async {
    calls.add(RecordedCall(url, headers, timeout));
    return _handler(url, headers);
  }
}
