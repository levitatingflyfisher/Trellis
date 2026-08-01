/// Scripted fake for the HttpFetcher seam — the Dart analogue of the
/// donor test's stubbed `fetch` (rebuild/test/comms.test.mjs).
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

/// A single-chunk text response, donor `makeResp`.
FetchResponse textResponse(
  String body, {
  int status = 200,
  Map<String, String> headers = const {},
}) {
  return FetchResponse(
    statusCode: status,
    headers: {'content-type': 'text/plain; charset=utf-8', ...headers},
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

final _proxyHost = RegExp(r'cors\.eu\.org|allorigins|codetabs');

bool isProxyUrl(Uri u) => _proxyHost.hasMatch(u.toString());

/// Donor-shaped fetcher: proxy hosts answer "PROXIED", everything else
/// answers "DIRECT" (ok controlled by [directOk]).
ScriptedFetcher donorFetcher({bool directOk = true}) =>
    ScriptedFetcher((url, headers) => isProxyUrl(url)
        ? textResponse('PROXIED')
        : textResponse('DIRECT', status: directOk ? 200 : 500));

class FakeConsent implements ProxyConsent {
  FakeConsent({this.prior = false, this.grantOnAsk = false});

  bool prior;
  bool grantOnAsk;
  int askCount = 0;

  @override
  bool get proxyConsented => prior;

  @override
  Future<bool> requestProxyConsent() async {
    askCount++;
    return grantOnAsk;
  }
}

CommsClient clientWith(ScriptedFetcher fetcher,
        {FakeConsent? consent, int? maxTextBytes, int? maxAudioBytes}) =>
    CommsClient(
      fetcher: fetcher,
      consent: consent ?? FakeConsent(),
      maxTextBytes: maxTextBytes ?? maxTextFetchBytes,
      maxAudioBytes: maxAudioBytes ?? maxAudioFetchBytes,
    );
