/// A scripted [Brain] fake for app-level Brain-consumer tests — mirrors
/// brain_wiring's own internal `test/fake_brain.dart` (not reusable
/// directly: that file lives outside `lib/`, so app tests need their own
/// copy of the same small shape).
///
/// A script is a list of steps consumed in order: a `String` is returned
/// as the completion; an `Exception` is thrown. Running past the end of
/// the script is a test bug and fails loudly.
library;

import 'package:brain_wiring/brain_wiring.dart';

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
