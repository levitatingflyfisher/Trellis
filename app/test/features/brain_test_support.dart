/// Shared fakes + fixtures for the brain/distill/discourse suites.
///
/// Not a test file (no `_test.dart` suffix — the runner skips it). Widget
/// tests drive Brains with FakeBrain scripts and secrets with the in-memory
/// store; no suite here ever touches a socket, a platform channel, or the
/// real flutter_secure_storage plugin.
library;

import 'dart:convert';

import 'package:brain_wiring/brain_wiring.dart';
import 'package:trellis/features/brain/brain_store.dart';

/// The scripted [Brain] fake, mirroring brain_wiring's own test double (its
/// test/ dir is not importable from here by design): a script is a list of
/// steps consumed in order — a `String` is returned as the completion, an
/// `Exception` is thrown. Running past the end fails loudly.
class FakeBrain implements Brain {
  FakeBrain(this._script);

  final List<Object> _script;
  int _next = 0;

  /// Every prompt this brain was asked, in order.
  final List<String> prompts = [];

  int get callCount => prompts.length;

  @override
  Future<String> complete(String prompt) async {
    prompts.add(prompt);
    if (_next >= _script.length) {
      throw StateError(
          'FakeBrain script exhausted after ${_script.length} steps '
          '(call ${prompts.length})');
    }
    final step = _script[_next++];
    if (step is Exception) throw step;
    if (step is String) return step;
    throw StateError('FakeBrain script steps must be String or Exception, '
        'got ${step.runtimeType}');
  }
}

/// The in-memory [BrainSecretStore]: what the widget suites inject instead
/// of the flutter_secure_storage plugin. [values] is inspectable so tests
/// can prove the key lives here and ONLY here — and that deleting deletes.
class InMemorySecretStore implements BrainSecretStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// A [BrainSecretStore] whose reads always fail — the "device without
/// working secure storage" case. The store must degrade to no-brain
/// calmly, never take a study session down.
class ThrowingSecretStore implements BrainSecretStore {
  @override
  Future<String?> read(String key) async =>
      throw StateError('secure storage unavailable');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('secure storage unavailable');

  @override
  Future<void> delete(String key) async =>
      throw StateError('secure storage unavailable');
}

/// Builds a [BrainStore] over in-memory secrets, optionally pre-pinned and
/// pre-keyed, whose BYOK tier resolves to [brain] instead of a real
/// AnthropicBrain — FakeBrain scripts, never a socket.
BrainStore fakeBrainStore({
  required InMemorySecretStore secrets,
  Brain? brain,
  String modelId = 'fake-model',
}) {
  return BrainStore(
    secrets: secrets,
    anthropicFactory: brain == null
        ? null
        : (apiKey) => (
              brain: brain,
              provenance: Provenance(
                  brainTier: BrainTier.byokAnthropic, modelId: modelId),
            ),
  );
}

/// A minimal course that passes study_core's strict parser AND the
/// distill-time discourse invariant (1-2 items per node, kinds distinct) —
/// the same shape brain_wiring's own fixtures use.
Map<String, dynamic> distillableCourseJson() => {
      'schemaVersion': '1.0',
      'id': 'kalman-mini',
      'title': 'A Tiny Course',
      'nodes': [
        {
          'id': 'n1',
          'title': 'First Idea',
          'intake': 'The first idea, explained from the ground up.',
          'items': [
            {
              'id': 'n1-i1',
              'type': 'qa',
              'rung': 3,
              'prompt': 'What is the first idea?',
              'answer': 'The first idea.',
              'acceptable': ['first idea'],
              'rubric': 'Name the first idea.',
            },
          ],
          'discourse': [
            {
              'kind': 'socratic',
              'prompt': 'What would break if the first idea were false?',
            },
            {
              'kind': 'explain_back',
              'prompt': 'Explain the first idea in your own words.',
            },
          ],
        },
      ],
    };

String distillableCourseText() => jsonEncode(distillableCourseJson());
