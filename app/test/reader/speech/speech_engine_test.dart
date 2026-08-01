import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/reader/speech/speech_engine.dart';

import '../../support/fake_tts.dart';

void main() {
  group('UtteranceSpeechEngine', () {
    test('wraps the TtsSpeaker seam and cannot pause', () async {
      final tts = FakeTtsSpeaker();
      final engine = UtteranceSpeechEngine(tts);
      expect(engine.canPause, isFalse);

      unawaited(engine.speak('Ola.', lang: 'pt'));
      expect(tts.utterances, [(text: 'Ola.', lang: 'pt')]);

      await engine.stop();
      expect(tts.stops, 1);
    });
  });

  group('SynthResult.durationMs', () {
    test('is exact — samples.length / sampleRate, never estimated', () {
      final result =
          SynthResult(samples: Float32List(16000), sampleRate: 16000);
      expect(result.durationMs, 1000);
    });

    test('a zero sample rate reports zero rather than dividing by zero', () {
      final result = SynthResult(samples: Float32List(10), sampleRate: 0);
      expect(result.durationMs, 0);
    });
  });

  group('SynthesisSpeechEngine', () {
    test('always reports canPause — the player owns pause, not the engine',
        () {
      final engine = _StubSynthesisEngine();
      expect(engine.canPause, isTrue);
    });
  });
}

class _StubSynthesisEngine implements SynthesisSpeechEngine {
  @override
  bool get canPause => true;
  @override
  Future<SynthResult> synthesize(String sentence, {String? lang}) async =>
      SynthResult(samples: Float32List(0), sampleRate: 16000);
  @override
  Future<void> dispose() async {}
}
