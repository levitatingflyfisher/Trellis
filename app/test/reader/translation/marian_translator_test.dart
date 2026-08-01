import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/reader/translation/marian_engine.dart';

/// MarianTranslator, with the ONNX Runtime layer faked at the
/// [MarianModelHandle] boundary — this test never touches
/// `package:flutter_onnxruntime` or a platform channel (the generation
/// loop's OWN mechanics are covered separately, against a lower-level
/// faked [MarianSessionRunner], in marian_generation_loop_test.dart).
class _FakeModelHandle implements MarianModelHandle {
  final List<String> calls = [];
  bool disposed = false;

  final List<Completer<String>> _pending = [];
  bool immediate;

  _FakeModelHandle({this.immediate = true});

  int maxConcurrent = 0;
  int _inFlight = 0;

  @override
  Future<String> translate(String sentence) async {
    calls.add(sentence);
    _inFlight++;
    if (_inFlight > maxConcurrent) maxConcurrent = _inFlight;
    try {
      if (immediate) return 'translated: $sentence';
      final completer = Completer<String>();
      _pending.add(completer);
      return await completer.future;
    } finally {
      _inFlight--;
    }
  }

  void resolveOldest() {
    final c = _pending.removeAt(0);
    c.complete('translated: ${calls[_pending.length]}');
  }

  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  late Directory dir;
  late MarianTranslatorFiles files;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('marian-translator-test');
    for (final name in [
      'encoder_model_quantized.onnx',
      'decoder_model_merged_quantized.onnx',
      'source.spm',
      'vocab.json',
    ]) {
      File('${dir.path}/$name').writeAsBytesSync([1, 2, 3]);
    }
    files = MarianTranslatorFiles(
      encoderPath: '${dir.path}/encoder_model_quantized.onnx',
      decoderMergedPath: '${dir.path}/decoder_model_merged_quantized.onnx',
      sourceSpmPath: '${dir.path}/source.spm',
      vocabPath: '${dir.path}/vocab.json',
    );
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('translate renders through the injected handle and returns its '
      'result verbatim', () async {
    final handle = _FakeModelHandle();
    final engine = MarianTranslator(
      files: files,
      openHandle: (_) async => handle,
    );

    final result = await engine.translate('Hello there.');

    expect(handle.calls, ['Hello there.']);
    expect(result, 'translated: Hello there.');
  });

  test('the native handle is created lazily — never at construction', () {
    var opened = false;
    MarianTranslator(
      files: files,
      openHandle: (_) async {
        opened = true;
        return _FakeModelHandle();
      },
    );
    expect(opened, isFalse);
  });

  test('the handle is resident — a second translate call reuses it, '
      'never re-opening', () async {
    var openCount = 0;
    final handle = _FakeModelHandle();
    final engine = MarianTranslator(
      files: files,
      openHandle: (_) async {
        openCount++;
        return handle;
      },
    );

    await engine.translate('One.');
    await engine.translate('Two.');

    expect(openCount, 1);
    expect(handle.calls, ['One.', 'Two.']);
  });

  test('two translate calls racing before the handle opens still open it '
      'only once — the lazy-open race the Future cache closes', () async {
    var openCount = 0;
    final handle = _FakeModelHandle();
    final engine = MarianTranslator(
      files: files,
      openHandle: (_) async {
        openCount++;
        await Future<void>.delayed(Duration.zero);
        return handle;
      },
    );

    await Future.wait([engine.translate('One.'), engine.translate('Two.')]);

    expect(openCount, 1);
  });

  test('dispose() releases the native handle and clears residency', () async {
    final handle = _FakeModelHandle();
    final engine = MarianTranslator(
      files: files,
      openHandle: (_) async => handle,
    );
    await engine.translate('One.');

    await engine.dispose();
    expect(handle.disposed, isTrue);
  });

  test('dispose() before any translate call never touches the handle '
      'factory', () async {
    var opened = false;
    final engine = MarianTranslator(
      files: files,
      openHandle: (_) async {
        opened = true;
        return _FakeModelHandle();
      },
    );
    await engine.dispose();
    expect(opened, isFalse);
  });

  test('a missing model file throws a typed, calm exception — and never '
      'touches the handle factory at all', () async {
    var opened = false;
    final missing = MarianTranslatorFiles(
      encoderPath: '${dir.path}/does-not-exist.onnx',
      decoderMergedPath: files.decoderMergedPath,
      sourceSpmPath: files.sourceSpmPath,
      vocabPath: files.vocabPath,
    );
    final engine = MarianTranslator(
      files: missing,
      openHandle: (_) async {
        opened = true;
        return _FakeModelHandle();
      },
    );

    await expectLater(
      () => engine.translate('Hello.'),
      throwsA(isA<MarianModelMissingFilesException>()),
    );
    expect(opened, isFalse);
  });

  test('a native init failure surfaces as a typed, calm exception, not a '
      'bare platform error', () async {
    final engine = MarianTranslator(
      files: files,
      openHandle: (_) async => throw Exception('boom from the native side'),
    );

    await expectLater(
      () => engine.translate('Hello.'),
      throwsA(isA<MarianModelInitException>()),
    );
  });

  test('concurrent translate calls (Phase 3\'s translate-ahead) are '
      'serialized through one engine — never two translate() calls in '
      'flight on the same handle at once', () async {
    final handle = _FakeModelHandle(immediate: false);
    final engine = MarianTranslator(
      files: files,
      openHandle: (_) async => handle,
    );

    final a = engine.translate('One.');
    final b = engine.translate('Two.');
    final c = engine.translate('Three.');

    await Future<void>.delayed(Duration.zero);
    expect(
      handle.calls.length,
      1,
      reason: 'only the first call should have reached translate() yet',
    );

    handle.resolveOldest();
    await Future<void>.delayed(Duration.zero);
    expect(handle.calls.length, 2);

    handle.resolveOldest();
    await Future<void>.delayed(Duration.zero);
    expect(handle.calls.length, 3);

    handle.resolveOldest();
    await Future.wait([a, b, c]);

    expect(handle.maxConcurrent, 1);
    expect(handle.calls, ['One.', 'Two.', 'Three.']);
  });

  test('dispose() waits for an in-flight translation before releasing the '
      'handle — closing ONNX sessions under a live run is a native-level '
      'gamble', () async {
    final handle = _FakeModelHandle(immediate: false);
    final engine = MarianTranslator(
      files: files,
      openHandle: (_) async => handle,
    );

    final inFlight = engine.translate('One.');
    await Future<void>.delayed(Duration.zero);
    expect(handle.calls.length, 1);

    var disposeDone = false;
    final disposing = engine.dispose().then((_) => disposeDone = true);
    await Future<void>.delayed(Duration.zero);
    expect(
      disposeDone,
      isFalse,
      reason: 'dispose must not complete while translate() is in flight',
    );
    expect(handle.disposed, isFalse);

    handle.resolveOldest();
    await inFlight;
    await disposing;
    expect(handle.disposed, isTrue);
  });

  test('dispose() after a failed open completes calmly instead of '
      'rethrowing the cached open failure', () async {
    final engine = MarianTranslator(
      files: files,
      openHandle: (_) async => throw Exception('boom from the native side'),
    );

    await expectLater(
      () => engine.translate('Hello.'),
      throwsA(isA<MarianModelInitException>()),
    );

    await engine.dispose();
  });
}
