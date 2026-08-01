import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/reader/speech/supertonic_engine.dart';
import 'package:trellis/features/reader/speech/supertonic_voice_handle.dart';
import 'package:trellis/features/reader/speech/speech_engine.dart';

/// SupertonicSpeechEngine, with the ONNX Runtime layer faked at the
/// [SupertonicVoiceHandle] boundary — this test never touches
/// `package:flutter_onnxruntime` or a platform channel.
class _FakeVoiceHandle implements SupertonicVoiceHandle {
  final List<({String text, String lang})> calls = [];
  bool disposed = false;

  /// Lets a test hold a call open until it chooses to resolve it — the
  /// concurrency tests need to observe "in flight" as a real state, not
  /// infer it from ordering alone.
  final List<Completer<SynthResult>> _pending = [];
  bool immediate;

  _FakeVoiceHandle({this.immediate = true});

  int maxConcurrent = 0;
  int _inFlight = 0;

  @override
  Future<SynthResult> generate(String text, {required String lang}) async {
    calls.add((text: text, lang: lang));
    _inFlight++;
    if (_inFlight > maxConcurrent) maxConcurrent = _inFlight;
    try {
      if (immediate) {
        return SynthResult(samples: Float32List(160), sampleRate: 44100);
      }
      final completer = Completer<SynthResult>();
      _pending.add(completer);
      return await completer.future;
    } finally {
      _inFlight--;
    }
  }

  /// Resolves the OLDEST still-pending call — lets a test drive completion
  /// order deterministically.
  void resolveOldest() {
    _pending.removeAt(0).complete(
        SynthResult(samples: Float32List(160), sampleRate: 44100));
  }

  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  late Directory dir;
  late SupertonicVoiceFiles files;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('supertonic-voice-test');
    for (final name in [
      'duration_predictor.onnx',
      'text_encoder.onnx',
      'vector_estimator.onnx',
      'vocoder.onnx',
      'unicode_indexer.json',
      'tts.json',
      'voice-style.json',
    ]) {
      File('${dir.path}/$name').writeAsBytesSync([1, 2, 3]);
    }
    files = SupertonicVoiceFiles(
      durationPredictorPath: '${dir.path}/duration_predictor.onnx',
      textEncoderPath: '${dir.path}/text_encoder.onnx',
      vectorEstimatorPath: '${dir.path}/vector_estimator.onnx',
      vocoderPath: '${dir.path}/vocoder.onnx',
      unicodeIndexerPath: '${dir.path}/unicode_indexer.json',
      ttsConfigPath: '${dir.path}/tts.json',
      voiceStylePath: '${dir.path}/voice-style.json',
    );
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('canPause is always true — the player owns pause, not the engine',
      () {
    final engine = SupertonicSpeechEngine(
        files: files, openHandle: (_) async => _FakeVoiceHandle());
    expect(engine.canPause, isTrue);
  });

  test('synthesize renders through the injected handle and returns its '
      'SynthResult verbatim', () async {
    final handle = _FakeVoiceHandle();
    final engine =
        SupertonicSpeechEngine(files: files, openHandle: (_) async => handle);

    final result = await engine.synthesize('Hello there.', lang: 'en');

    expect(handle.calls, [(text: 'Hello there.', lang: 'en')]);
    expect(result.sampleRate, 44100);
    expect(result.samples.length, 160);
  });

  test('a null lang defaults to English — the one voice this entry ships',
      () async {
    final handle = _FakeVoiceHandle();
    final engine =
        SupertonicSpeechEngine(files: files, openHandle: (_) async => handle);

    await engine.synthesize('Hello.');

    expect(handle.calls.single.lang, 'en');
  });

  test('the native handle is created lazily — never at construction', () {
    var opened = false;
    SupertonicSpeechEngine(
        files: files,
        openHandle: (_) async {
          opened = true;
          return _FakeVoiceHandle();
        });
    expect(opened, isFalse);
  });

  test('the handle is resident — a second synthesize call reuses it, '
      'never re-opening', () async {
    var openCount = 0;
    final handle = _FakeVoiceHandle();
    final engine = SupertonicSpeechEngine(
        files: files,
        openHandle: (_) async {
          openCount++;
          return handle;
        });

    await engine.synthesize('One.');
    await engine.synthesize('Two.');

    expect(openCount, 1);
    expect(handle.calls.map((c) => c.text).toList(), ['One.', 'Two.']);
  });

  test('two synthesize calls racing before the handle opens still open it '
      'only once — the lazy-open race the Future cache closes', () async {
    var openCount = 0;
    final handle = _FakeVoiceHandle();
    final engine = SupertonicSpeechEngine(
        files: files,
        openHandle: (_) async {
          openCount++;
          // Yield so both callers' synthesize() calls genuinely overlap
          // before either sees the handle resolved.
          await Future<void>.delayed(Duration.zero);
          return handle;
        });

    await Future.wait([
      engine.synthesize('One.'),
      engine.synthesize('Two.'),
    ]);

    expect(openCount, 1);
  });

  test('dispose() releases the native handle and clears residency', () async {
    final handle = _FakeVoiceHandle();
    final engine =
        SupertonicSpeechEngine(files: files, openHandle: (_) async => handle);
    await engine.synthesize('One.');

    await engine.dispose();
    expect(handle.disposed, isTrue);
  });

  test('dispose() before any synthesize call never touches the handle '
      'factory', () async {
    var opened = false;
    final engine = SupertonicSpeechEngine(
        files: files,
        openHandle: (_) async {
          opened = true;
          return _FakeVoiceHandle();
        });
    await engine.dispose();
    expect(opened, isFalse);
  });

  test('a missing model file throws a typed, calm exception — and never '
      'touches the handle factory at all', () async {
    var opened = false;
    final missing = SupertonicVoiceFiles(
      durationPredictorPath: '${dir.path}/does-not-exist.onnx',
      textEncoderPath: files.textEncoderPath,
      vectorEstimatorPath: files.vectorEstimatorPath,
      vocoderPath: files.vocoderPath,
      unicodeIndexerPath: files.unicodeIndexerPath,
      ttsConfigPath: files.ttsConfigPath,
      voiceStylePath: files.voiceStylePath,
    );
    final engine = SupertonicSpeechEngine(
        files: missing,
        openHandle: (_) async {
          opened = true;
          return _FakeVoiceHandle();
        });

    await expectLater(
      () => engine.synthesize('Hello.'),
      throwsA(isA<SupertonicVoiceMissingFilesException>()),
    );
    expect(opened, isFalse);
  });

  test('a native init failure surfaces as a typed, calm exception, not a '
      'bare platform error', () async {
    final engine = SupertonicSpeechEngine(
        files: files,
        openHandle: (_) async =>
            throw Exception('boom from the native side'));

    await expectLater(
      () => engine.synthesize('Hello.'),
      throwsA(isA<SupertonicNativeInitException>()),
    );
  });

  test('an unsupported language is a typed, calm refusal — and never '
      'touches the handle factory (the failure is cheaper than opening a '
      'session)', () async {
    var opened = false;
    final engine = SupertonicSpeechEngine(
        files: files,
        openHandle: (_) async {
          opened = true;
          return _FakeVoiceHandle();
        });

    await expectLater(
      () => engine.synthesize('Bonjour.', lang: 'fr'),
      throwsA(isA<SupertonicUnsupportedLangException>()),
    );
    expect(opened, isFalse);
  });

  test('concurrent synthesize calls (the pipeline\'s lookahead) are '
      'serialized through one engine — never two generate() calls in '
      'flight on the same handle at once', () async {
    final handle = _FakeVoiceHandle(immediate: false);
    final engine =
        SupertonicSpeechEngine(files: files, openHandle: (_) async => handle);

    final a = engine.synthesize('One.');
    final b = engine.synthesize('Two.');
    final c = engine.synthesize('Three.');

    // Let the microtask queue run so all three synthesize() calls have
    // actually reached the handle if they were going to run concurrently.
    await Future<void>.delayed(Duration.zero);
    expect(handle.calls.length, 1,
        reason: 'only the first call should have reached generate() yet');

    handle.resolveOldest();
    await Future<void>.delayed(Duration.zero);
    expect(handle.calls.length, 2);

    handle.resolveOldest();
    await Future<void>.delayed(Duration.zero);
    expect(handle.calls.length, 3);

    handle.resolveOldest();
    await Future.wait([a, b, c]);

    expect(handle.maxConcurrent, 1);
    expect(handle.calls.map((c) => c.text).toList(), ['One.', 'Two.', 'Three.']);
  });

  test('dispose() waits for an in-flight generation before releasing the '
      'handle — closing ONNX sessions under a live run is a native-level '
      'gamble', () async {
    final handle = _FakeVoiceHandle(immediate: false);
    final engine =
        SupertonicSpeechEngine(files: files, openHandle: (_) async => handle);

    final inFlight = engine.synthesize('One.');
    await Future<void>.delayed(Duration.zero);
    expect(handle.calls.length, 1);

    var disposeDone = false;
    final disposing = engine.dispose().then((_) => disposeDone = true);
    await Future<void>.delayed(Duration.zero);
    expect(disposeDone, isFalse,
        reason: 'dispose must not complete while generate() is in flight');
    expect(handle.disposed, isFalse,
        reason: 'the handle must not be released under a live generate()');

    handle.resolveOldest();
    await inFlight;
    await disposing;
    expect(handle.disposed, isTrue);
  });

  test('dispose() after a failed open completes calmly instead of '
      'rethrowing the cached open failure', () async {
    final engine = SupertonicSpeechEngine(
        files: files,
        openHandle: (_) async => throw Exception('boom from the native side'));

    await expectLater(
      () => engine.synthesize('Hello.'),
      throwsA(isA<SupertonicNativeInitException>()),
    );

    await engine.dispose();
  });
}
