import 'dart:convert';

import 'package:brain_wiring/brain_wiring.dart';
import 'package:test/test.dart';

import 'scripted_http.dart';

void main() {
  AnthropicBrain brain(ScriptedHttp http,
          {String? model, int? maxTokens}) =>
      AnthropicBrain(
        http: http,
        apiKey: 'sk-test-key',
        model: model ?? AnthropicBrain.defaultModel,
        maxTokens: maxTokens ?? AnthropicBrain.defaultMaxTokens,
      );

  group('request shape', () {
    test('POSTs the messages API with key, version, and JSON body', () async {
      final http = ScriptedHttp.always(200, anthropicOk('hi'));
      await brain(http).complete('Hello there');

      final post = http.posts.single;
      expect(post.url.toString(), 'https://api.anthropic.com/v1/messages');
      expect(post.headers['x-api-key'], 'sk-test-key');
      expect(post.headers['anthropic-version'], '2023-06-01');
      expect(post.headers['content-type'], 'application/json');

      final body = post.jsonBody;
      expect(body['model'], 'claude-sonnet-5');
      expect(body['max_tokens'], AnthropicBrain.defaultMaxTokens);
      expect(body['messages'], [
        {'role': 'user', 'content': 'Hello there'},
      ]);
    });

    test('the default model is claude-sonnet-5', () {
      expect(AnthropicBrain.defaultModel, 'claude-sonnet-5');
    });

    test('a caller-chosen model rides the body and the provenance', () async {
      final http = ScriptedHttp.always(200, anthropicOk('hi'));
      final b = brain(http, model: 'claude-haiku-4-5');
      await b.complete('x');
      expect(http.posts.single.jsonBody['model'], 'claude-haiku-4-5');
      expect(
        b.provenance,
        const Provenance(
          brainTier: BrainTier.byokAnthropic,
          modelId: 'claude-haiku-4-5',
        ),
      );
    });
  });

  group('success', () {
    test('returns the text of a single text block', () async {
      final http = ScriptedHttp.always(200, anthropicOk('The answer.'));
      expect(await brain(http).complete('q'), 'The answer.');
    });

    test('concatenates multiple text blocks, ignoring non-text blocks',
        () async {
      final body = jsonEncode({
        'content': [
          {'type': 'thinking', 'thinking': 'hmm'},
          {'type': 'text', 'text': 'Part one. '},
          {'type': 'text', 'text': 'Part two.'},
        ],
        'stop_reason': 'end_turn',
      });
      final http = ScriptedHttp.always(200, body);
      expect(await brain(http).complete('q'), 'Part one. Part two.');
    });
  });

  group('calm error mapping', () {
    Matcher calmAsk(Pattern messageContains) => throwsA(
          isA<AskException>().having(
            (e) => e.message.toLowerCase(),
            'message',
            contains(messageContains),
          ),
        );

    test('401 maps to a check-your-key message', () async {
      final http = ScriptedHttp.always(
          401,
          jsonEncode({
            'type': 'error',
            'error': {
              'type': 'authentication_error',
              'message': 'invalid x-api-key',
            },
          }));
      await expectLater(brain(http).complete('q'), calmAsk('key'));
    });

    test('the 401 cause keeps the wire body for logs, not for people',
        () async {
      final http = ScriptedHttp.always(401, '{"type":"error"}');
      try {
        await brain(http).complete('q');
        fail('expected AskException');
      } on AskException catch (e) {
        expect('${e.cause}', contains('401'));
        expect(e.message, isNot(contains('401')));
      }
    });

    test('429 maps to a wait-and-retry message', () async {
      final http = ScriptedHttp.always(
          429,
          jsonEncode({
            'type': 'error',
            'error': {'type': 'rate_limit_error', 'message': 'slow down'},
          }));
      await expectLater(brain(http).complete('q'), calmAsk('moment'));
    });

    test('529 overload maps to a calm busy message', () async {
      final http = ScriptedHttp.always(529, '{"type":"error"}');
      await expectLater(brain(http).complete('q'), calmAsk('busy'));
    });

    test('500 maps to the same calm busy message', () async {
      final http = ScriptedHttp.always(500, 'oops');
      await expectLater(brain(http).complete('q'), calmAsk('busy'));
    });

    test('other 4xx maps to a generic calm message carrying no jargon',
        () async {
      final http = ScriptedHttp.always(400, '{"type":"error"}');
      await expectLater(brain(http).complete('q'), calmAsk('anthropic'));
    });

    test('a transport failure is wrapped, with the cause preserved',
        () async {
      final boom = Exception('connection reset');
      final http = ScriptedHttp.failing(boom);
      try {
        await brain(http).complete('q');
        fail('expected AskException');
      } on AskException catch (e) {
        expect(e.message.toLowerCase(), contains('reach'));
        expect(e.cause, same(boom));
      }
    });

    test('garbage JSON on a 200 fails calmly', () async {
      final http = ScriptedHttp.always(200, 'not json at all');
      await expectLater(brain(http).complete('q'), calmAsk('reply'));
    });

    test('a 200 with no text content fails calmly', () async {
      final http =
          ScriptedHttp.always(200, jsonEncode({'content': <Object>[]}));
      await expectLater(brain(http).complete('q'), calmAsk('reply'));
    });

    test('a refusal stop reason fails calmly instead of returning nothing',
        () async {
      final http = ScriptedHttp.always(
          200, anthropicOk('', stopReason: 'refusal'));
      await expectLater(brain(http).complete('q'), calmAsk('declined'));
    });

    test('never retries on its own — one request per complete()', () async {
      final http = ScriptedHttp.always(429, '{}');
      await expectLater(
          brain(http).complete('q'), throwsA(isA<AskException>()));
      expect(http.posts, hasLength(1));
    });
  });
}
