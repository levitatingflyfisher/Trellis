import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:ml_runtime/ml_runtime.dart';

/// The scripted fakes are the app's test doubles for the FFI engines.
/// Their whole value is determinism: same script, same output, every time.
void main() {
  final script = [
    TranscriptChunk(text: 'hello', tStartMs: 0, tEndMs: 1000, words: [
      WordTiming(word: 'hello', tStartMs: 0, tEndMs: 1000),
    ]),
    TranscriptChunk(text: 'world', tStartMs: 1000, tEndMs: 2000, words: [
      WordTiming(word: 'world', tStartMs: 1000, tEndMs: 2000),
    ]),
  ];

  ListPcmSource source() => ListPcmSource([Float32List.fromList([0.0, 0.5])]);

  group('FakeTranscriber', () {
    test('emits its script in order', () async {
      final fake = FakeTranscriber(script);
      final out = await fake.transcribe(source()).toList();
      expect(out, script);
    });

    test('is deterministic across calls', () async {
      final fake = FakeTranscriber(script);
      final first = await fake.transcribe(source()).toList();
      final second = await fake.transcribe(source()).toList();
      expect(second, first);
    });

    test('wordTimings: false strips word timings from the emissions', () async {
      final fake = FakeTranscriber(script);
      final out = await fake.transcribe(source(), wordTimings: false).toList();
      expect(out.map((c) => c.text), ['hello', 'world']);
      expect(out.every((c) => c.words == null), isTrue);
    });

    test('records each call with its arguments (defaults included)', () async {
      final fake = FakeTranscriber(script);
      await fake.transcribe(source()).toList();
      await fake
          .transcribe(source(),
              lang: 'es', task: WhisperTask.translate, wordTimings: false)
          .toList();

      expect(fake.calls, hasLength(2));
      // Seam defaults per proposal-2 §5: transcribe, word timings on.
      expect(fake.calls[0].lang, isNull);
      expect(fake.calls[0].task, WhisperTask.transcribe);
      expect(fake.calls[0].wordTimings, isTrue);
      expect(fake.calls[1].lang, 'es');
      expect(fake.calls[1].task, WhisperTask.translate);
      expect(fake.calls[1].wordTimings, isFalse);
    });
  });

  group('FakeSynthesizer', () {
    const voice = Voice(id: 'fake-en', lang: 'en');

    test('emits exactly one AudioChunk per input text, indexed in order', () async {
      final fake = FakeSynthesizer();
      final out = await fake.synthesize(['One.', 'Two.', 'Three.'], voice).toList();
      expect(out, hasLength(3));
      expect(out.map((a) => a.inputIndex), [0, 1, 2]);
    });

    test('sample count is deterministic: text runes x samplesPerRune', () async {
      final fake = FakeSynthesizer(samplesPerRune: 10, sampleRate: 16000);
      final out = await fake.synthesize(['abcd'], voice).toList();
      expect(out.single.samples.length, 40);
      expect(out.single.sampleRate, 16000);
    });

    test('two runs over the same input are sample-identical', () async {
      final fake = FakeSynthesizer();
      final a = await fake.synthesize(['same text'], voice).toList();
      final b = await fake.synthesize(['same text'], voice).toList();
      expect(a.single.samples, b.single.samples);
    });

    test('records the voice and texts it was asked to render', () async {
      final fake = FakeSynthesizer();
      await fake.synthesize(['hi'], voice).toList();
      expect(fake.calls.single.voice, voice);
      expect(fake.calls.single.texts, ['hi']);
    });
  });

  group('FakeVad', () {
    test('silence has no speech', () async {
      final vad = FakeVad(threshold: 0.01);
      expect(await vad.hasSpeech(Float32List(512)), isFalse);
    });

    test('a loud window has speech', () async {
      final vad = FakeVad(threshold: 0.01);
      final window = Float32List(512)..[100] = 0.8;
      expect(await vad.hasSpeech(window), isTrue);
    });
  });

  group('ListPcmSource', () {
    test('replays its windows with the declared sample rate', () async {
      final src = ListPcmSource(
        [Float32List.fromList([0.1]), Float32List.fromList([0.2, 0.3])],
        sampleRate: 16000,
      );
      expect(src.sampleRate, 16000);
      final windows = await src.chunks().toList();
      expect(windows, hasLength(2));
      // Compare float32-to-float32: 0.2 has no exact float32 representation.
      expect(windows[1], Float32List.fromList([0.2, 0.3]));
    });
  });
}
