/// Unit tests for [WhisperTranscriber] against a fake symbol table — no
/// native library, no model, no I/O. The fake implements the same shim ABI
/// the real `libwhisper.so` exports, records every call, and replays
/// scripted segments, so these tests pin down:
///
///  * params marshalling (language, translate, token timestamps, threads,
///    no_context) across the FFI boundary,
///  * chunk mapping (centiseconds -> ms, window offset accumulation,
///    token -> word grouping, special-token filtering),
///  * error paths and the context lifecycle (init/free pairing, free on
///    error and on cancellation).
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:test/test.dart';
import 'package:whisper_ffi/whisper_ffi.dart';

/// One scripted whisper segment (times in centiseconds, like whisper's).
class _Seg {
  final String text;
  final int t0;
  final int t1;
  final List<_Tok> tokens;

  const _Seg(this.text, this.t0, this.t1, [this.tokens = const []]);
}

/// One scripted token within a segment (times in centiseconds).
class _Tok {
  final String text;
  final int t0;
  final int t1;
  final bool special;

  const _Tok(this.text, this.t0, this.t1, {this.special = false});
}

/// One recorded `full` invocation, with everything read back off the
/// native-memory arguments before they were freed.
class _FullCall {
  final List<double> samples;
  final String? lang;
  final int translate;
  final int tokenTimestamps;
  final int nThreads;
  final int noContext;

  const _FullCall({
    required this.samples,
    required this.lang,
    required this.translate,
    required this.tokenTimestamps,
    required this.nThreads,
    required this.noContext,
  });
}

/// A fake whisper symbol table: same shape as the real bindings, scripted
/// output, full call recording. `script[k]` is the segment list "produced"
/// by the k-th `full` call.
class _FakeWhisper {
  final List<List<_Seg>> script;
  bool failInit = false;
  int fullResult = 0;

  /// What `wfs_full_lang` answers after each `full`; null models a shipped
  /// `.so` built before the shim exported it (the binding is absent).
  String? Function()? detectedLang;
  int initCalls = 0;
  int freeCalls = 0;

  /// Whether the fake also exports the wfs_state_* set (model loaded with
  /// no state, a fresh state per window). Off models a `.so` built before
  /// 1.5.3's per-window state.
  bool withState = false;
  int modelInitCalls = 0;
  int stateNewCalls = 0;
  int stateFreeCalls = 0;
  bool failStateNew = false;

  /// The state the last stateFull ran in; getters must be handed it.
  Pointer<Void>? _liveState;
  int _nextState = 0x5000;
  final List<String> initPaths = [];
  final List<_FullCall> fullCalls = [];

  final List<Pointer<Utf8>> _allocated = [];
  List<_Seg> _current = const [];
  final Pointer<Void> _ctx = Pointer<Void>.fromAddress(0xC0FFEE);

  _FakeWhisper(this.script);

  Pointer<Utf8> _utf8(String s) {
    final p = s.toNativeUtf8();
    _allocated.add(p);
    return p;
  }

  void dispose() {
    for (final p in _allocated) {
      malloc.free(p);
    }
    _allocated.clear();
  }

  /// A getter read off anything but the live, unfreed state is the bug
  /// the per-window state exists to prevent.
  T _onState<T>(Pointer<Void> state, T Function() read) {
    if (state != _liveState) {
      throw StateError('read from a state that is not live: $state');
    }
    return read();
  }

  WhisperStateBindings get _stateBindings => WhisperStateBindings(
        initModel: (path) {
          modelInitCalls++;
          initPaths.add(path.toDartString());
          return failInit ? nullptr : _ctx;
        },
        newState: (ctx) {
          expect(ctx, _ctx);
          stateNewCalls++;
          if (failStateNew) return nullptr;
          return _liveState = Pointer<Void>.fromAddress(_nextState++);
        },
        freeState: (state) {
          expect(state, _liveState);
          stateFreeCalls++;
          _liveState = null;
        },
        full: (ctx, state, samples, nSamples, lang, translate,
            tokenTimestamps, nThreads, noContext) {
          expect(state, _liveState);
          return bindings.full(ctx, samples, nSamples, lang, translate,
              tokenTimestamps, nThreads, noContext);
        },
        nSegments: (st) => _onState(st, () => _current.length),
        segmentText: (st, i) => _onState(st, () => _utf8(_current[i].text)),
        segmentT0: (st, i) => _onState(st, () => _current[i].t0),
        segmentT1: (st, i) => _onState(st, () => _current[i].t1),
        nTokens: (st, i) => _onState(st, () => _current[i].tokens.length),
        tokenText: (ctx, st, i, j) =>
            _onState(st, () => _utf8(_current[i].tokens[j].text)),
        tokenT0: (st, i, j) => _onState(st, () => _current[i].tokens[j].t0),
        tokenT1: (st, i, j) => _onState(st, () => _current[i].tokens[j].t1),
        tokenIsSpecial: (ctx, st, i, j) =>
            _onState(st, () => _current[i].tokens[j].special ? 1 : 0),
        fullLang: (st) => _onState(st, () {
          final code = detectedLang?.call();
          return code == null ? nullptr : _utf8(code);
        }),
      );

  WhisperBindings get bindings => WhisperBindings(
        initFromFile: (path) {
          initCalls++;
          initPaths.add(path.toDartString());
          return failInit ? nullptr : _ctx;
        },
        free: (ctx) {
          freeCalls++;
        },
        full: (ctx, samples, nSamples, lang, translate, tokenTimestamps,
            nThreads, noContext) {
          fullCalls.add(_FullCall(
            samples: List<double>.from(samples.asTypedList(nSamples)),
            lang: lang == nullptr ? null : lang.toDartString(),
            translate: translate,
            tokenTimestamps: tokenTimestamps,
            nThreads: nThreads,
            noContext: noContext,
          ));
          final k = fullCalls.length - 1;
          _current = k < script.length ? script[k] : const [];
          return fullResult;
        },
        nSegments: (ctx) => _current.length,
        segmentText: (ctx, i) => _utf8(_current[i].text),
        segmentT0: (ctx, i) => _current[i].t0,
        segmentT1: (ctx, i) => _current[i].t1,
        nTokens: (ctx, i) => _current[i].tokens.length,
        tokenText: (ctx, i, j) => _utf8(_current[i].tokens[j].text),
        tokenT0: (ctx, i, j) => _current[i].tokens[j].t0,
        tokenT1: (ctx, i, j) => _current[i].tokens[j].t1,
        tokenIsSpecial: (ctx, i, j) => _current[i].tokens[j].special ? 1 : 0,
        fullLang: detectedLang == null
            ? null
            : (ctx) {
                final code = detectedLang!();
                return code == null ? nullptr : _utf8(code);
              },
        state: withState ? _stateBindings : null,
      );
}

Float32List _window(int n, [double Function(int)? gen]) {
  final w = Float32List(n);
  if (gen != null) {
    for (var i = 0; i < n; i++) {
      w[i] = gen(i);
    }
  }
  return w;
}

void main() {
  late _FakeWhisper fake;

  tearDown(() => fake.dispose());

  WhisperTranscriber transcriber(
          {int? threads, bool noContext = true, bool keepContext = false}) =>
      WhisperTranscriber(
        bindings: fake.bindings,
        modelPath: 'model.bin',
        threads: threads,
        noContext: noContext,
        keepContext: keepContext,
      );

  group('params marshalling', () {
    test('passes language, translate, token timestamps, threads, no_context',
        () async {
      fake = _FakeWhisper([[]]);
      final samples = _window(64, (i) => math.sin(i / 8.0));
      final src = ListPcmSource([samples]);

      await transcriber(threads: 3)
          .transcribe(src,
              lang: 'de', task: WhisperTask.translate, wordTimings: false)
          .toList();

      final call = fake.fullCalls.single;
      expect(call.lang, 'de');
      expect(call.translate, 1);
      expect(call.tokenTimestamps, 0);
      expect(call.nThreads, 3);
      expect(call.noContext, 1);
      expect(call.samples, hasLength(64));
      for (var i = 0; i < 64; i++) {
        expect(call.samples[i], closeTo(samples[i], 1e-6));
      }
      expect(fake.initPaths.single, 'model.bin');
    });

    test('null lang crosses as nullptr (auto-detect)', () async {
      fake = _FakeWhisper([[]]);
      await transcriber().transcribe(ListPcmSource([_window(8)])).toList();
      expect(fake.fullCalls.single.lang, isNull);
    });

    test('defaults: transcribe task, word timings on, cores-1 threads, '
        'no_context on', () async {
      fake = _FakeWhisper([[]]);
      await transcriber().transcribe(ListPcmSource([_window(8)])).toList();
      final call = fake.fullCalls.single;
      expect(call.translate, 0);
      expect(call.tokenTimestamps, 1);
      expect(call.nThreads, math.max(1, Platform.numberOfProcessors - 1));
      expect(call.noContext, 1);
    });

    test('noContext false crosses as 0', () async {
      fake = _FakeWhisper([[]]);
      await transcriber(noContext: false)
          .transcribe(ListPcmSource([_window(8)]))
          .toList();
      expect(fake.fullCalls.single.noContext, 0);
    });
  });

  group('chunk mapping', () {
    test('centiseconds -> ms, one chunk per segment, text trimmed', () async {
      fake = _FakeWhisper([
        [_Seg(' Hello there.', 0, 150), _Seg(' Second segment.', 150, 290)],
      ]);
      final chunks = await transcriber()
          .transcribe(ListPcmSource([_window(48000)]), wordTimings: false)
          .toList();

      expect(chunks, hasLength(2));
      expect(chunks[0].text, 'Hello there.');
      expect(chunks[0].tStartMs, 0);
      expect(chunks[0].tEndMs, 1500);
      expect(chunks[1].text, 'Second segment.');
      expect(chunks[1].tStartMs, 1500);
      expect(chunks[1].tEndMs, 2900);
      expect(chunks[0].words, isNull);
    });

    test('later windows are offset by the samples already consumed', () async {
      fake = _FakeWhisper([
        [_Seg(' one', 0, 150)],
        [_Seg(' two', 0, 100)],
      ]);
      // 2s window then a 1s window at 16kHz.
      final chunks = await transcriber()
          .transcribe(
            ListPcmSource([_window(32000), _window(16000)]),
            wordTimings: false,
          )
          .toList();

      expect(chunks, hasLength(2));
      expect(chunks[0].tStartMs, 0);
      expect(chunks[0].tEndMs, 1500);
      expect(chunks[1].tStartMs, 2000);
      expect(chunks[1].tEndMs, 3000);
    });

    test('tokens group into words; specials and unstamped tokens drop',
        () async {
      fake = _FakeWhisper([
        [
          _Seg(' Hello world', 0, 60, [
            _Tok('[_BEG_]', 0, 0, special: true),
            _Tok(' Hel', 0, 20),
            _Tok('lo', 20, 30),
            _Tok(' world', 30, 60),
            _Tok('[_EOT_]', 60, 60, special: true),
          ]),
        ],
      ]);
      final chunks =
          await transcriber().transcribe(ListPcmSource([_window(16000)])).toList();

      final words = chunks.single.words;
      expect(words, isNotNull);
      expect(words, [
        WordTiming(word: 'Hello', tStartMs: 0, tEndMs: 300),
        WordTiming(word: 'world', tStartMs: 300, tEndMs: 600),
      ]);
    });

    test('word timings inherit the window offset', () async {
      fake = _FakeWhisper([
        [],
        [
          _Seg(' Hi', 0, 50, [_Tok(' Hi', 10, 40)]),
        ],
      ]);
      final chunks = await transcriber()
          .transcribe(ListPcmSource([_window(16000), _window(16000)]))
          .toList();

      final chunk = chunks.single;
      expect(chunk.tStartMs, 1000);
      expect(chunk.words, [
        WordTiming(word: 'Hi', tStartMs: 1100, tEndMs: 1400),
      ]);
    });

    test('tokens without timestamps (t0 < 0) are skipped', () async {
      fake = _FakeWhisper([
        [
          _Seg(' Hi there', 0, 80, [
            _Tok(' Hi', -1, -1),
            _Tok(' there', 30, 80),
          ]),
        ],
      ]);
      final chunks =
          await transcriber().transcribe(ListPcmSource([_window(16000)])).toList();
      expect(chunks.single.words, [
        WordTiming(word: 'there', tStartMs: 300, tEndMs: 800),
      ]);
    });

    test('wordTimings false yields null words and asks the engine for none',
        () async {
      fake = _FakeWhisper([
        [
          _Seg(' Hey', 0, 50, [_Tok(' Hey', 0, 50)]),
        ],
      ]);
      final chunks = await transcriber()
          .transcribe(ListPcmSource([_window(16000)]), wordTimings: false)
          .toList();
      expect(chunks.single.words, isNull);
      expect(fake.fullCalls.single.tokenTimestamps, 0);
    });

    test('a window producing zero segments yields no chunks', () async {
      fake = _FakeWhisper([[]]);
      final chunks =
          await transcriber().transcribe(ListPcmSource([_window(16000)])).toList();
      expect(chunks, isEmpty);
    });

    test('empty windows are skipped without a native call', () async {
      fake = _FakeWhisper([
        [_Seg(' ok', 0, 50)],
      ]);
      final chunks = await transcriber()
          .transcribe(ListPcmSource([_window(0), _window(16000)]),
              wordTimings: false)
          .toList();
      expect(fake.fullCalls, hasLength(1));
      expect(chunks.single.text, 'ok');
      // The empty window must not advance the clock.
      expect(chunks.single.tStartMs, 0);
    });
  });

  group('error paths and lifecycle', () {
    test('a non-16kHz source is rejected before any native call', () async {
      fake = _FakeWhisper([[]]);
      final src = ListPcmSource([_window(8)], sampleRate: 44100);
      await expectLater(
        transcriber().transcribe(src).toList(),
        throwsA(isA<ArgumentError>()),
      );
      expect(fake.initCalls, 0);
      expect(fake.fullCalls, isEmpty);
    });

    test('init failure throws WhisperException and never frees', () async {
      fake = _FakeWhisper([[]])..failInit = true;
      await expectLater(
        transcriber().transcribe(ListPcmSource([_window(8)])).toList(),
        throwsA(isA<WhisperException>()),
      );
      expect(fake.initCalls, 1);
      expect(fake.freeCalls, 0);
      expect(fake.fullCalls, isEmpty);
    });

    test('whisper_full failure throws and still frees the context', () async {
      fake = _FakeWhisper([[]])..fullResult = -6;
      await expectLater(
        transcriber().transcribe(ListPcmSource([_window(8)])).toList(),
        throwsA(isA<WhisperException>()),
      );
      expect(fake.initCalls, 1);
      expect(fake.freeCalls, 1);
    });

    test('success frees exactly once; a second run re-inits cleanly',
        () async {
      fake = _FakeWhisper([[], []]);
      final t = transcriber();
      await t.transcribe(ListPcmSource([_window(8)])).toList();
      expect(fake.initCalls, 1);
      expect(fake.freeCalls, 1);
      await t.transcribe(ListPcmSource([_window(8)])).toList();
      expect(fake.initCalls, 2);
      expect(fake.freeCalls, 2);
    });

    test('cancelling the stream mid-way frees the context', () async {
      fake = _FakeWhisper([
        [_Seg(' one', 0, 50)],
        [_Seg(' two', 0, 50)],
      ]);
      final stream = transcriber()
          .transcribe(ListPcmSource([_window(16000), _window(16000)]),
              wordTimings: false);

      final gotFirst = Completer<TranscriptChunk>();
      late StreamSubscription<TranscriptChunk> sub;
      sub = stream.listen((chunk) {
        if (!gotFirst.isCompleted) gotFirst.complete(chunk);
      });
      await gotFirst.future;
      await sub.cancel();

      expect(fake.freeCalls, 1);
    });
  });

  group('job-scoped context (keepContext)', () {
    test('one init across many calls; close frees it exactly once', () async {
      fake = _FakeWhisper([[], [], []]);
      final t = transcriber(keepContext: true);
      for (var k = 0; k < 3; k++) {
        await t.transcribe(ListPcmSource([_window(8)])).toList();
      }
      expect(fake.initCalls, 1);
      expect(fake.freeCalls, 0);
      t.close();
      t.close();
      expect(fake.freeCalls, 1);
    });

    test('close before any call loads nothing and frees nothing', () {
      fake = _FakeWhisper([]);
      transcriber(keepContext: true).close();
      expect(fake.initCalls, 0);
      expect(fake.freeCalls, 0);
    });

    test('a failed whisper_full keeps the context for the retry', () async {
      fake = _FakeWhisper([[], []])..fullResult = -6;
      final t = transcriber(keepContext: true);
      await expectLater(t.transcribe(ListPcmSource([_window(8)])).toList(),
          throwsA(isA<WhisperException>()));
      fake.fullResult = 0;
      await t.transcribe(ListPcmSource([_window(8)])).toList();
      expect(fake.initCalls, 1);
      expect(fake.freeCalls, 0);
      t.close();
      expect(fake.freeCalls, 1);
    });

    test('cancelling a stream mid-way keeps the context', () async {
      fake = _FakeWhisper([
        [_Seg(' one', 0, 50)],
        [_Seg(' two', 0, 50)],
      ]);
      final t = transcriber(keepContext: true);
      final gotFirst = Completer<void>();
      final sub = t
          .transcribe(ListPcmSource([_window(16000), _window(16000)]),
              wordTimings: false)
          .listen((_) {
        if (!gotFirst.isCompleted) gotFirst.complete();
      });
      await gotFirst.future;
      await sub.cancel();
      expect(fake.freeCalls, 0);
      t.close();
      expect(fake.freeCalls, 1);
    });

    test('window offsets restart with each call', () async {
      fake = _FakeWhisper([
        [_Seg(' a', 0, 50)],
        [_Seg(' b', 0, 50)],
      ]);
      final t = transcriber(keepContext: true);
      final first = await t
          .transcribe(ListPcmSource([_window(16000)]), wordTimings: false)
          .toList();
      final second = await t
          .transcribe(ListPcmSource([_window(16000)]), wordTimings: false)
          .toList();
      expect(first.single.tStartMs, 0);
      expect(second.single.tStartMs, 0);
      t.close();
    });
  });

  group('detected language', () {
    test('reports what whisper detected for the last window', () async {
      final answers = ['ru', 'en'];
      var k = 0;
      fake = _FakeWhisper([[], []])..detectedLang = () => answers[k++];
      final t = transcriber();
      expect(t.lastLanguage, isNull);
      await t.transcribe(ListPcmSource([_window(8)])).toList();
      expect(t.lastLanguage, 'ru');
      await t.transcribe(ListPcmSource([_window(8)])).toList();
      expect(t.lastLanguage, 'en');
    });

    test('a native that cannot tell reports null', () async {
      fake = _FakeWhisper([[]])..detectedLang = () => null;
      final t = transcriber();
      await t.transcribe(ListPcmSource([_window(8)])).toList();
      expect(t.lastLanguage, isNull);
    });

    test('an older .so without the export reports null and still runs',
        () async {
      fake = _FakeWhisper([
        [_Seg(' hi', 0, 50)]
      ]);
      final t = transcriber();
      final chunks = await t
          .transcribe(ListPcmSource([_window(8)]), wordTimings: false)
          .toList();
      expect(chunks.single.text, 'hi');
      expect(t.lastLanguage, isNull);
    });
  });

  group('per-window state (wfs_state_*)', () {
    test('a kept model loads once; every window gets a fresh state, freed',
        () async {
      fake = _FakeWhisper([
        [_Seg(' a', 0, 50)],
        [_Seg(' b', 0, 50)],
        [_Seg(' c', 0, 50)],
      ])
        ..withState = true;
      final t = transcriber(keepContext: true);
      final first = await t
          .transcribe(ListPcmSource([_window(16000), _window(16000)]),
              wordTimings: false)
          .toList();
      final second = await t
          .transcribe(ListPcmSource([_window(16000)]), wordTimings: false)
          .toList();
      expect(first.map((c) => c.text), ['a', 'b']);
      expect(second.single.text, 'c');
      expect(fake.modelInitCalls, 1);
      expect(fake.initCalls, 0, reason: 'the stateful init is never used');
      expect(fake.stateNewCalls, 3);
      expect(fake.stateFreeCalls, 3);
      expect(fake.freeCalls, 0);
      t.close();
      expect(fake.freeCalls, 1);
    });

    test('words and language are read off the window state', () async {
      fake = _FakeWhisper([
        [
          _Seg(' Hi there', 0, 100, [
            _Tok('[_BEG_]', 0, 0, special: true),
            _Tok(' Hi', 0, 40),
            _Tok(' there', 40, 100),
          ]),
        ],
      ])
        ..withState = true
        ..detectedLang = () => 'en';
      final t = transcriber(keepContext: true);
      final chunks = await t.transcribe(ListPcmSource([_window(8)])).toList();
      expect(chunks.single.words!.map((w) => w.word), ['Hi', 'there']);
      expect(t.lastLanguage, 'en');
      t.close();
    });

    test('a failed whisper_full frees the state and keeps the model',
        () async {
      fake = _FakeWhisper([[], []])
        ..withState = true
        ..fullResult = -6;
      final t = transcriber(keepContext: true);
      await expectLater(t.transcribe(ListPcmSource([_window(8)])).toList(),
          throwsA(isA<WhisperException>()));
      expect(fake.stateFreeCalls, 1);
      fake.fullResult = 0;
      await t.transcribe(ListPcmSource([_window(8)])).toList();
      expect(fake.modelInitCalls, 1);
      expect(fake.stateFreeCalls, 2);
      t.close();
      expect(fake.freeCalls, 1);
    });

    test('a state that cannot be allocated throws, model kept', () async {
      fake = _FakeWhisper([[]])
        ..withState = true
        ..failStateNew = true;
      final t = transcriber(keepContext: true);
      await expectLater(t.transcribe(ListPcmSource([_window(8)])).toList(),
          throwsA(isA<WhisperException>()));
      expect(fake.stateFreeCalls, 0);
      expect(fake.freeCalls, 0);
      t.close();
      expect(fake.freeCalls, 1);
    });

    test('cancelling mid-stream leaves no state alive', () async {
      fake = _FakeWhisper([
        [_Seg(' one', 0, 50)],
        [_Seg(' two', 0, 50)],
      ])
        ..withState = true;
      final t = transcriber(keepContext: true);
      final gotFirst = Completer<void>();
      final sub = t
          .transcribe(ListPcmSource([_window(16000), _window(16000)]),
              wordTimings: false)
          .listen((_) {
        if (!gotFirst.isCompleted) gotFirst.complete();
      });
      await gotFirst.future;
      await sub.cancel();
      expect(fake.stateFreeCalls, fake.stateNewCalls);
      t.close();
      expect(fake.freeCalls, 1);
    });

    test('without keepContext the model is loaded and freed per call',
        () async {
      fake = _FakeWhisper([[], []])..withState = true;
      final t = transcriber();
      await t.transcribe(ListPcmSource([_window(8), _window(8)])).toList();
      expect(fake.modelInitCalls, 1);
      expect(fake.stateNewCalls, 2);
      expect(fake.stateFreeCalls, 2);
      expect(fake.freeCalls, 1);
    });
  });
}
