/// Fake for the SynthesisSpeechEngine seam — records every synthesize()
/// call and lets a test complete them by hand, in ANY order, so pipeline
/// tests can prove append order follows SENTENCE order rather than
/// synthesis-completion order.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:trellis/features/reader/speech/speech_engine.dart';

class FakeSynthesisCall {
  final String text;
  final String? lang;
  const FakeSynthesisCall(this.text, this.lang);
}

class FakeSynthesisSpeechEngine implements SynthesisSpeechEngine {
  final List<FakeSynthesisCall> calls = [];
  final List<Completer<SynthResult>> _completers = [];
  bool disposed = false;

  @override
  bool get canPause => true;

  @override
  Future<SynthResult> synthesize(String sentence, {String? lang}) {
    calls.add(FakeSynthesisCall(sentence, lang));
    final c = Completer<SynthResult>();
    _completers.add(c);
    return c.future;
  }

  /// Resolves the call at [callIndex] (0-based, in the order `synthesize`
  /// was invoked) with [samples] worth of silence at [sampleRate].
  void complete(int callIndex, {int samples = 100, int sampleRate = 16000}) {
    _completers[callIndex]
        .complete(SynthResult(samples: Float32List(samples), sampleRate: sampleRate));
  }

  void completeWithError(int callIndex, Object error) {
    _completers[callIndex].completeError(error);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}
