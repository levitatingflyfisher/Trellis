import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/reader/speech/piper/piper_engine.dart';
import 'package:trellis/features/reader/speech/piper/piper_voice_config.dart';
import 'package:trellis/features/reader/speech/speech_engine.dart';

/// PiperSpeechEngine (Russian, ru_RU denis), with the model faked at
/// [PiperModel]: no ONNX Runtime, no platform channel.
class _FakeModel implements PiperModel {
  final calls = <({List<int> ids, Float32List scales})>[];
  bool disposed = false;
  Float32List Function(List<int> ids)? audio;

  /// When set, each run waits for it: a call held in flight.
  Completer<void>? hold;

  @override
  Future<Float32List> run(List<int> ids, Float32List scales) async {
    calls.add((ids: ids, scales: scales));
    await hold?.future;
    return audio?.call(ids) ??
        Float32List.fromList(List.filled(ids.length * 10, 0.25));
  }

  @override
  Future<void> dispose() async => disposed = true;
}

const _config = PiperVoiceConfig(
  phonemeIdMap: {
    '_': [0],
    '^': [1],
    r'$': [2],
    'a': [14],
    'b': [15],
  },
  vowelClusters: [],
  sampleRate: 22050,
  noiseScale: 0.5,
  lengthScale: 1.0,
  noiseW: 0.333,
);

void main() {
  late _FakeModel model;
  var frontEndLoads = 0;
  PiperSpeechEngine engine({List<String> Function(String)? phonemes}) {
    model = _FakeModel();
    frontEndLoads = 0;
    return PiperSpeechEngine(
      openModel: () async => model,
      loadFrontEnd: () async {
        frontEndLoads++;
        return PiperFrontEnd(
          config: _config,
          phonemes: phonemes ?? (s) => ['a', 'b'],
        );
      },
    );
  }

  test('it speaks Russian only, and can pause', () {
    final e = engine();
    expect(e.speaks, {'ru'});
    expect(e.canPause, isTrue);
    expect(
      () => e.synthesize('Hallo', lang: 'de'),
      throwsA(isA<PiperUnsupportedLangException>()),
    );
  });

  test('a sentence goes to the model as Piper ids, with the config’s '
      'numbers, and comes back at 22,050 Hz', () async {
    final e = engine();
    final r = await e.synthesize('Привет', lang: 'ru-RU');
    expect(r.sampleRate, 22050);
    final call = model.calls.single;
    expect(call.ids, [1, 0, 14, 0, 15, 0, 2]);
    expect(call.scales, [0.5, 1.0, closeTo(0.333, 1e-6)]);
  });

  test('a slower pace makes length_scale longer in proportion', () async {
    final e = engine();
    await e.synthesize('Привет', lang: 'ru', pace: const SpeechPace(rate: 0.8));
    expect(model.calls.single.scales[1], closeTo(1.25, 1e-6));
    expect(model.calls.single.scales[0], 0.5);
  });

  test('each sentence is brought to full scale and clipped, as Piper '
      'does by default', () async {
    final e = engine();
    model.audio = (_) => Float32List.fromList([0.1, -0.25, 0.2]);
    final r = await e.synthesize('Привет', lang: 'ru');
    expect(r.samples, [closeTo(0.4, 1e-6), -1.0, closeTo(0.8, 1e-6)]);
  });

  test('a silent clip stays silent', () async {
    final e = engine();
    model.audio = (_) => Float32List(4);
    final r = await e.synthesize('Привет', lang: 'ru');
    expect(r.samples, [0, 0, 0, 0]);
  });

  test('a sentence with nothing to say is silence, and the model is not '
      'run', () async {
    final e = engine(phonemes: (s) => const []);
    final r = await e.synthesize('…', lang: 'ru');
    expect(r.samples, isEmpty);
    expect(r.sampleRate, 22050);
    expect(model.calls, isEmpty);
  });

  test(
    'audio that comes back as NaN is refused, never played as noise',
    () async {
      final e = engine();
      model.audio = (_) => Float32List.fromList([0.1, double.nan, 0.2]);
      await expectLater(
        e.synthesize('Привет', lang: 'ru'),
        throwsA(isA<PiperBadAudioException>()),
      );
    },
  );

  test('the front end and the model load once, on first use', () async {
    final e = engine();
    expect(frontEndLoads, 0);
    await e.synthesize('Один', lang: 'ru');
    await e.synthesize('Два', lang: 'ru');
    expect(frontEndLoads, 1);
  });

  test('one call at a time: the second sentence waits for the first', () async {
    final e = engine();
    model.hold = Completer<void>();
    final first = e.synthesize('Один', lang: 'ru');
    final second = e.synthesize('Два', lang: 'ru');
    await pumpEventQueue();
    expect(model.calls, hasLength(1));
    model.hold!.complete();
    await first;
    await second;
    expect(model.calls, hasLength(2));
  });

  test(
    'dispose waits for the call in flight, then releases the model',
    () async {
      final e = engine();
      model.hold = Completer<void>();
      final first = e.synthesize('Один', lang: 'ru');
      await pumpEventQueue();
      var disposed = false;
      final disposing = e.dispose().then((_) => disposed = true);
      await pumpEventQueue();
      expect(disposed, isFalse);
      expect(model.disposed, isFalse);
      model.hold!.complete();
      await first;
      await disposing;
      expect(model.disposed, isTrue);
    },
  );

  test('missing files are a calm, typed error, and the next sentence '
      'tries again', () async {
    var missing = true;
    final good = _FakeModel();
    final e = PiperSpeechEngine(
      openModel: () async => good,
      loadFrontEnd: () async {
        if (missing) {
          throw const PiperMissingFilesException('gone');
        }
        return PiperFrontEnd(config: _config, phonemes: (s) => ['a']);
      },
    );
    await expectLater(
      e.synthesize('Привет', lang: 'ru'),
      throwsA(isA<PiperMissingFilesException>()),
    );
    missing = false;
    await e.synthesize('Привет', lang: 'ru');
    expect(good.calls, hasLength(1));
  });

  test(
    'a model that fails to start is tried again on the next sentence',
    () async {
      var fail = true;
      final good = _FakeModel();
      final e = PiperSpeechEngine(
        openModel: () async {
          if (fail) throw StateError('boom');
          return good;
        },
        loadFrontEnd: () async =>
            PiperFrontEnd(config: _config, phonemes: (s) => ['a']),
      );
      await expectLater(
        e.synthesize('Привет', lang: 'ru'),
        throwsA(isA<PiperNativeInitException>()),
      );
      fail = false;
      await e.synthesize('Привет', lang: 'ru');
      expect(good.calls, hasLength(1));
    },
  );
}
