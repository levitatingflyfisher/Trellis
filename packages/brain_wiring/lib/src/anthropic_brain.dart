/// The BYOK Anthropic tier: a [Brain] over the messages API
/// (`POST /v1/messages`), reached only through the injectable
/// [BrainHttpClient] seam — no real network in this package, ever.
///
/// Error posture follows the Brain contract: anything a person might
/// need to read becomes a calm [AskException]; the wire detail rides
/// `cause` for logs and tests. No blind retries — one request per
/// `complete()`, and the caller decides what a failure means.
library;

import 'dart:convert';

import 'package:brain_wiring/src/brain_http.dart';
import 'package:brain_wiring/src/provenance.dart';
import 'package:brain_wiring/src/tier.dart';
import 'package:domovoi/domovoi.dart' show AskException, Brain;

class AnthropicBrain implements Brain {
  AnthropicBrain({
    required BrainHttpClient http,
    required String apiKey,
    this.model = defaultModel,
    this.maxTokens = defaultMaxTokens,
    Uri? endpoint,
  })  : _http = http,
        _apiKey = apiKey,
        _endpoint = endpoint ?? Uri.parse(defaultEndpoint);

  /// The default model for distillation and discourse. The user may pick
  /// another in Settings; whichever runs is stamped into [provenance].
  static const String defaultModel = 'claude-sonnet-5';

  /// One completion covers a whole distilled course, so the ceiling is
  /// generous. Non-streaming by design (streaming NOT required here).
  static const int defaultMaxTokens = 16000;

  static const String defaultEndpoint = 'https://api.anthropic.com/v1/messages';

  static const String _apiVersion = '2023-06-01';

  final BrainHttpClient _http;
  final String _apiKey;
  final String model;
  final int maxTokens;
  final Uri _endpoint;

  /// What generated artifacts should carry (tier + model id).
  Provenance get provenance =>
      Provenance(brainTier: BrainTier.byokAnthropic, modelId: model);

  @override
  Future<String> complete(String prompt) async {
    final BrainHttpResponse response;
    try {
      response = await _http.post(
        _endpoint,
        headers: {
          'content-type': 'application/json',
          'x-api-key': _apiKey,
          'anthropic-version': _apiVersion,
        },
        body: jsonEncode({
          'model': model,
          'max_tokens': maxTokens,
          'messages': [
            {'role': 'user', 'content': prompt},
          ],
        }),
      );
    } on AskException {
      rethrow;
    } catch (error) {
      throw AskException(
        'Could not reach Anthropic — check the connection and try again.',
        cause: error,
      );
    }

    if (!response.ok) {
      throw _errorFor(response);
    }
    return _textOf(response);
  }

  /// Maps the messages API's error statuses to calm, displayable
  /// messages. The raw status + body always ride `cause`.
  AskException _errorFor(BrainHttpResponse response) {
    final cause = 'HTTP ${response.statusCode}: ${response.body}';
    final message = switch (response.statusCode) {
      401 || 403 =>
        'Anthropic did not accept the API key — check it in Settings.',
      429 =>
        'Anthropic is asking this key to slow down — wait a moment and '
            'try again.',
      529 || >= 500 =>
        'Anthropic is busy right now — try again in a little while.',
      _ => 'Anthropic could not handle that request — try again, and if '
          'it keeps happening, check for an app update.',
    };
    return AskException(message, cause: cause);
  }

  /// Pulls the answer text out of a 2xx messages-API body.
  String _textOf(BrainHttpResponse response) {
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException catch (error) {
      throw AskException(
        "Anthropic's reply was not in the expected shape — try again.",
        cause: error,
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw AskException(
        "Anthropic's reply was not in the expected shape — try again.",
        cause: response.body,
      );
    }

    // A safety refusal is a valid response with nothing usable in it;
    // surface it as its own calm failure rather than an empty string.
    if (decoded['stop_reason'] == 'refusal') {
      throw AskException(
        'Anthropic declined this request — try rephrasing it.',
        cause: response.body,
      );
    }

    final content = decoded['content'];
    final buffer = StringBuffer();
    if (content is List) {
      for (final block in content) {
        if (block is Map<String, dynamic> &&
            block['type'] == 'text' &&
            block['text'] is String) {
          buffer.write(block['text'] as String);
        }
      }
    }
    if (buffer.isEmpty) {
      throw AskException(
        "Anthropic's reply came back empty — try again.",
        cause: response.body,
      );
    }
    return buffer.toString();
  }
}
