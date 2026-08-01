/// Scripted fake for the [BrainHttpClient] seam — the POST analogue of
/// comms_core's ScriptedFetcher. NO real network anywhere in this suite.
library;

import 'dart:async';
import 'dart:convert';

import 'package:brain_wiring/brain_wiring.dart';

class RecordedPost {
  RecordedPost(this.url, this.headers, this.body);
  final Uri url;
  final Map<String, String> headers;
  final String body;

  Map<String, dynamic> get jsonBody => jsonDecode(body) as Map<String, dynamic>;
}

class ScriptedHttp implements BrainHttpClient {
  ScriptedHttp(this._handler);

  /// Always answers [status]/[body], whatever the request.
  ScriptedHttp.always(int status, String body)
      : this((_) => BrainHttpResponse(statusCode: status, body: body));

  /// Simulates a transport-level failure (DNS, TLS, reset).
  ScriptedHttp.failing(Object error) : this((_) => throw error);

  final FutureOr<BrainHttpResponse> Function(RecordedPost post) _handler;
  final List<RecordedPost> posts = [];

  @override
  Future<BrainHttpResponse> post(
    Uri url, {
    required Map<String, String> headers,
    required String body,
  }) async {
    final recorded = RecordedPost(url, headers, body);
    posts.add(recorded);
    return _handler(recorded);
  }
}

/// A well-formed messages-API success body with one text block.
String anthropicOk(String text, {String stopReason = 'end_turn'}) =>
    jsonEncode({
      'content': [
        {'type': 'text', 'text': text},
      ],
      'stop_reason': stopReason,
    });
