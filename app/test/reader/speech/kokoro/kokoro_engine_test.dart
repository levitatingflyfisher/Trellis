import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/reader/speech/kokoro/kokoro_engine.dart';
import 'package:trellis/features/reader/speech/speech_engine.dart';

/// KokoroSpeechEngine (Chinese, Kokoro-82M v1.1-zh), with the model faked
/// at [KokoroModel]: no ONNX Runtime, no platform channel.
class _FakeModel implements KokoroModel {
  final calls = <({List<int> ids, Float32List style, double speed})>[];
  bool disposed = false;
  Float32List Function(List<int> ids)? audio;

  @override
  Future<Float32List> run(List<int> inputIds, Float32List style, double speed) async {
    calls.add((ids: inputIds, style: style, speed: speed));
    return audio?.call(inputIds) ?? Float32List(inputIds.length * 10);
  }

  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  late Directory dir;
  late File voice;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('trellis-kokoro');
    // A voice is 510 rows of 256 floats; row r is filled with r.
    final rows = Float32List(510 * 256);
    for (var r = 0; r < 510; r++) {
      rows.fillRange(r * 256, (r + 1) * 256, r.toDouble());
    }
    voice = File('${dir.path}/zf_001.bin')
      ..writeAsBytesSync(rows.buffer.asUint8List());
  });
  tearDown(() => dir.deleteSync(recursive: true));

  late _FakeModel model;
  var frontEndLoads = 0;
  KokoroSpeechEngine engine({List<KokoroChunk> Function(String)? frontEnd}) {
    model = _FakeModel();
    frontEndLoads = 0;
    return KokoroSpeechEngine(
      voicePath: voice.path,
      openModel: () async => model,
      loadFrontEnd: () async {
        frontEndLoads++;
        return frontEnd ??
            (s) => [KokoroChunk(inputIds: [0, 5, 6, 7, 0], lenPs: 3)];
      },
    );
  }

  test('it speaks Chinese only, and can pause', () {
    final e = engine();
    expect(e.speaks, {'zh'});
    expect(e.canPause, isTrue);
    expect(() => e.synthesize('Hallo', lang: 'de'),
        throwsA(isA<KokoroUnsupportedLangException>()));
  });

  test('the style row is the phoneme count less one, and the speed '
      'follows the maker’s curve', () async {
    final e = engine(frontEnd: (s) => [
          KokoroChunk(inputIds: [0, ...List.filled(120, 9), 0], lenPs: 120)
        ]);
    final r = await e.synthesize('你好', lang: 'zh-CN');
    expect(r.sampleRate, 24000);
    final call = model.calls.single;
    expect(call.style.length, 256);
    expect(call.style.first, 119);
    expect(call.speed, closeTo(kokoroZhSpeed(120), 1e-9));
  });

  test('the maker’s speed curve: 1.1 up to 83 phonemes, down to 0.88 at '
      '183, then flat (make_zh.py)', () {
    expect(kokoroZhSpeed(10), closeTo(1.1, 1e-9));
    expect(kokoroZhSpeed(83), closeTo(1.1, 1e-9));
    expect(kokoroZhSpeed(133), closeTo(0.99, 1e-9));
    expect(kokoroZhSpeed(183), closeTo(0.88, 1e-9));
    expect(kokoroZhSpeed(400), closeTo(0.88, 1e-9));
  });

  test('a slower pace slows the voice in proportion', () async {
    final e = engine();
    await e.synthesize('你好', lang: 'zh', pace: const SpeechPace(rate: 0.75));
    expect(model.calls.single.speed, closeTo(kokoroZhSpeed(3) * 0.75, 1e-9));
  });

  test('a long sentence in several chunks comes back as one clip, in '
      'order', () async {
    final e = engine(frontEnd: (s) => [
          KokoroChunk(inputIds: [0, 1, 0], lenPs: 1),
          KokoroChunk(inputIds: [0, 2, 2, 0], lenPs: 2),
        ]);
    model.audio = null;
    final r = await e.synthesize('长句', lang: 'zh');
    expect(model.calls.map((c) => c.ids), [
      [0, 1, 0],
      [0, 2, 2, 0]
    ]);
    expect(r.samples.length, 30 + 40);
  });

  test('a sentence with nothing to say (Latin only) is silence, and the '
      'model is not run', () async {
    final e = engine(frontEnd: (s) => const []);
    final r = await e.synthesize('Hello', lang: 'zh');
    expect(r.samples, isEmpty);
    expect(model.calls, isEmpty);
  });

  test('audio that comes back as NaN is refused in a sentence, never '
      'played as noise', () async {
    final e = engine();
    model.audio = (_) => Float32List.fromList([0.1, double.nan, 0.2]);
    await expectLater(e.synthesize('你好', lang: 'zh'),
        throwsA(isA<KokoroBadAudioException>()));
  });

  test('the front end and the model load once, on first use; dispose '
      'releases the model', () async {
    final e = engine();
    expect(frontEndLoads, 0);
    await e.synthesize('一', lang: 'zh');
    await e.synthesize('二', lang: 'zh');
    expect(frontEndLoads, 1);
    await e.dispose();
    expect(model.disposed, isTrue);
  });

  test('a missing voice file is a calm, typed error, and once the file '
      'is back the next sentence works', () async {
    final bytes = voice.readAsBytesSync();
    voice.deleteSync();
    final e = engine();
    await expectLater(e.synthesize('你好', lang: 'zh'),
        throwsA(isA<KokoroMissingFilesException>()));
    voice.writeAsBytesSync(bytes);
    final r = await e.synthesize('你好', lang: 'zh');
    expect(r.samples, isNotEmpty);
  });

  test('a model that fails to start is tried again on the next sentence',
      () async {
    var fail = true;
    final good = _FakeModel();
    final e = KokoroSpeechEngine(
      voicePath: voice.path,
      openModel: () async {
        if (fail) throw StateError('boom');
        return good;
      },
      loadFrontEnd: () async =>
          (s) => [const KokoroChunk(inputIds: [0, 1, 0], lenPs: 1)],
    );
    await expectLater(e.synthesize('你好', lang: 'zh'),
        throwsA(isA<KokoroNativeInitException>()));
    fail = false;
    await e.synthesize('你好', lang: 'zh');
    expect(good.calls, hasLength(1));
  });
}
