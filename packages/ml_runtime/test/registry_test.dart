import 'package:test/test.dart';
import 'package:ml_runtime/ml_runtime.dart';

/// The model registry is the fleet's model-trust law made local: every
/// downloadable file is (url, sha256, bytes), selection is a pure function
/// of (task, tier, language), and nothing claims a pin it does not have.
void main() {
  ModelSpec spec(
    String id,
    ModelTask task,
    DeviceTier minTier, {
    int bytes = 1000,
    Set<String>? langs,
  }) =>
      ModelSpec(
        id: id,
        task: task,
        files: [ModelFile.unverified(url: 'https://example.test/$id.bin', bytes: bytes)],
        licenses: const ['MIT'],
        minTier: minTier,
        langs: langs,
      );

  group('ModelFile', () {
    test('an empty sha256 means unpinned', () {
      final f = ModelFile.unverified(url: 'https://example.test/m.bin', bytes: 10);
      expect(f.isPinned, isFalse);
    });

    test('a 64-char lowercase hex sha256 is pinned', () {
      final f = ModelFile(
        url: 'https://example.test/m.bin',
        sha256: 'a' * 64,
        bytes: 10,
      );
      expect(f.isPinned, isTrue);
    });

    test('a malformed sha256 is rejected — no half-pins', () {
      expect(
        () => ModelFile(url: 'https://example.test/m.bin', sha256: 'abc', bytes: 10),
        throwsArgumentError,
      );
      expect(
        () => ModelFile(url: 'https://example.test/m.bin', sha256: 'Z' * 64, bytes: 10),
        throwsArgumentError,
      );
    });

    test('a non-positive size is rejected', () {
      expect(
        () => ModelFile.unverified(url: 'https://example.test/m.bin', bytes: 0),
        throwsArgumentError,
      );
    });

    test('an empty url is rejected', () {
      expect(() => ModelFile.unverified(url: '', bytes: 10), throwsArgumentError);
    });
  });

  group('VoiceArchiveLayout (TTS voices, ADR-0006)', () {
    test('archiveLayout is null by default — every existing spec shape '
        'keeps compiling unchanged', () {
      expect(spec('plain', ModelTask.asr, DeviceTier.t1).archiveLayout,
          isNull);
    });

    test('a TTS voice spec carries its archive layout — the "data, not '
        'code" surface for adding a voice', () {
      const layout = VoiceArchiveLayout(
        topLevelDir: 'vits-piper-en_US-example-medium',
        modelFileName: 'en_US-example-medium.onnx',
        tokensFileName: 'tokens.txt',
        dataDirName: 'espeak-ng-data',
      );
      final voice = ModelSpec(
        id: 'piper-example',
        task: ModelTask.tts,
        files: [
          ModelFile.unverified(
              url: 'https://example.test/voice.tar.bz2', bytes: 1000),
        ],
        licenses: const ['CC-BY-4.0', 'GPL-3.0'],
        minTier: DeviceTier.t1,
        archiveLayout: layout,
      );
      expect(voice.archiveLayout, same(layout));
    });
  });

  group('SupertonicVoiceLayout (TTS voices, ADR-0007)', () {
    test('supertonicLayout is null by default — every existing spec shape '
        'keeps compiling unchanged', () {
      expect(spec('plain', ModelTask.asr, DeviceTier.t1).supertonicLayout,
          isNull);
    });

    test('a Supertonic voice spec names which downloaded filename plays '
        'which role — the "data, not code" surface for a voice whose '
        'files ship loose (no archive to extract)', () {
      const layout = SupertonicVoiceLayout(
        durationPredictorFileName: 'duration_predictor.onnx',
        textEncoderFileName: 'text_encoder.onnx',
        vectorEstimatorFileName: 'vector_estimator.onnx',
        vocoderFileName: 'vocoder.onnx',
        unicodeIndexerFileName: 'unicode_indexer.json',
        ttsConfigFileName: 'tts.json',
        voiceStyleFileName: 'voice-style.json',
      );
      final voice = ModelSpec(
        id: 'supertonic-example',
        task: ModelTask.tts,
        files: [
          ModelFile.unverified(
              url: 'https://example.test/duration_predictor.onnx',
              bytes: 1000),
        ],
        licenses: const ['OpenRAIL-M'],
        minTier: DeviceTier.t2,
        supertonicLayout: layout,
      );
      expect(voice.supertonicLayout, same(layout));
    });
  });

  group('ModelSpec', () {
    test('sizeBytes is the sum of its files — derived, never a second copy', () {
      final s = ModelSpec(
        id: 'two-file',
        task: ModelTask.asr,
        files: [
          ModelFile.unverified(url: 'https://example.test/enc.bin', bytes: 300),
          ModelFile.unverified(url: 'https://example.test/dec.bin', bytes: 700),
        ],
        licenses: const ['MIT'],
        minTier: DeviceTier.t1,
      );
      expect(s.sizeBytes, 1000);
    });

    test('a spec with no files is rejected', () {
      expect(
        () => ModelSpec(
          id: 'empty',
          task: ModelTask.asr,
          files: const [],
          licenses: const ['MIT'],
          minTier: DeviceTier.t1,
        ),
        throwsArgumentError,
      );
    });

    test('a spec with no license is rejected — provenance is not optional', () {
      expect(
        () => ModelSpec(
          id: 'unlicensed',
          task: ModelTask.asr,
          files: [ModelFile.unverified(url: 'https://example.test/m.bin', bytes: 1)],
          licenses: const [],
          minTier: DeviceTier.t1,
        ),
        throwsArgumentError,
      );
    });
  });

  group('ModelRegistry construction', () {
    test('duplicate ids are rejected', () {
      expect(
        () => ModelRegistry([
          spec('dup', ModelTask.asr, DeviceTier.t1),
          spec('dup', ModelTask.tts, DeviceTier.t2),
        ]),
        throwsArgumentError,
      );
    });

    test('byId finds a spec; unknown id is null', () {
      final reg = ModelRegistry([spec('one', ModelTask.vad, DeviceTier.t1)]);
      expect(reg.byId('one')?.task, ModelTask.vad);
      expect(reg.byId('missing'), isNull);
    });
  });

  group('pickModel — selection law', () {
    // The most capable model the tier can run wins: highest minTier first,
    // then largest size, then registration order.
    final reg = ModelRegistry([
      spec('asr-tiny', ModelTask.asr, DeviceTier.t1, bytes: 41000000),
      spec('asr-base', ModelTask.asr, DeviceTier.t2, bytes: 77000000),
      spec('vad', ModelTask.vad, DeviceTier.t1, bytes: 2000000),
    ]);

    test('T0 gets nothing — zero models is the honest baseline', () {
      expect(reg.pickModel(ModelTask.asr, DeviceTier.t0), isNull);
      expect(reg.pickModel(ModelTask.vad, DeviceTier.t0), isNull);
    });

    test('a tier picks the most capable model it can run', () {
      expect(reg.pickModel(ModelTask.asr, DeviceTier.t1)?.id, 'asr-tiny');
      expect(reg.pickModel(ModelTask.asr, DeviceTier.t2)?.id, 'asr-base');
      expect(reg.pickModel(ModelTask.asr, DeviceTier.t3)?.id, 'asr-base');
    });

    test('no candidate for the task means null, not a guess', () {
      expect(reg.pickModel(ModelTask.llm, DeviceTier.t3), isNull);
    });

    test('same minTier: the larger model wins', () {
      final r = ModelRegistry([
        spec('small', ModelTask.tts, DeviceTier.t2, bytes: 100),
        spec('large', ModelTask.tts, DeviceTier.t2, bytes: 200),
      ]);
      expect(r.pickModel(ModelTask.tts, DeviceTier.t2)?.id, 'large');
    });

    test('full tie: registration order decides — deterministic forever', () {
      final r = ModelRegistry([
        spec('first', ModelTask.tts, DeviceTier.t2, bytes: 100),
        spec('second', ModelTask.tts, DeviceTier.t2, bytes: 100),
      ]);
      expect(r.pickModel(ModelTask.tts, DeviceTier.t2)?.id, 'first');
    });

    group('langHint', () {
      final r = ModelRegistry([
        spec('tts-en-only', ModelTask.tts, DeviceTier.t2,
            bytes: 92000000, langs: {'en'}),
        spec('tts-multilingual', ModelTask.tts, DeviceTier.t1, bytes: 60000000),
      ]);

      test('a language-restricted model is skipped for other languages', () {
        expect(r.pickModel(ModelTask.tts, DeviceTier.t2, langHint: 'de')?.id,
            'tts-multilingual');
      });

      test('a supported language keeps the more capable restricted model', () {
        expect(r.pickModel(ModelTask.tts, DeviceTier.t2, langHint: 'en')?.id,
            'tts-en-only');
      });

      test('no hint means language does not constrain', () {
        expect(r.pickModel(ModelTask.tts, DeviceTier.t2)?.id, 'tts-en-only');
      });

      test('langs == null matches any hint', () {
        expect(r.pickModel(ModelTask.tts, DeviceTier.t1, langHint: 'ko')?.id,
            'tts-multilingual');
      });
    });
  });

  group('the starter registry', () {
    final starter = ModelRegistry.starter();

    test('carries the pinned v1 catalog: whisper tiny/base ggml, silero '
        'vad, qwen2.5 litert, the supertonic starter voice', () {
      expect(
        starter.specs.map((s) => s.id),
        containsAll([
          'whisper-tiny-ggml',
          'whisper-base-ggml',
          'silero-vad',
          'qwen2.5-0.5b-instruct-litert',
          'supertonic-en-m1',
        ]),
      );
    });

    test('the starter voice carries its loose-file layout and its ONE '
        'license — OpenRAIL-M, no engine license alongside it, because '
        'there is no longer an engine license to list (ADR-0007)', () {
      final voice = starter.byId('supertonic-en-m1')!;
      expect(voice.task, ModelTask.tts);
      expect(voice.minTier, DeviceTier.t2);
      expect(voice.langs, {'en'});
      expect(voice.licenses, ['OpenRAIL-M']);
      final layout = voice.supertonicLayout;
      expect(layout, isNotNull);
      expect(layout!.durationPredictorFileName, 'duration_predictor.onnx');
      expect(layout.textEncoderFileName, 'text_encoder.onnx');
      expect(layout.vectorEstimatorFileName, 'vector_estimator.onnx');
      expect(layout.vocoderFileName, 'vocoder.onnx');
      expect(layout.unicodeIndexerFileName, 'unicode_indexer.json');
      expect(layout.ttsConfigFileName, 'tts.json');
      expect(layout.voiceStyleFileName, 'M1.json');
    });

    test('the tier ladder matches the proposal-2 ML plan: T1 = tiny+vad, T2 = base+llm', () {
      expect(starter.byId('whisper-tiny-ggml')!.minTier, DeviceTier.t1);
      expect(starter.byId('silero-vad')!.minTier, DeviceTier.t1);
      expect(starter.byId('whisper-base-ggml')!.minTier, DeviceTier.t2);
      expect(
          starter.byId('qwen2.5-0.5b-instruct-litert')!.minTier, DeviceTier.t2);
    });

    test('selection over the starter catalog follows the ladder', () {
      expect(starter.pickModel(ModelTask.asr, DeviceTier.t1)?.id,
          'whisper-tiny-ggml');
      expect(starter.pickModel(ModelTask.asr, DeviceTier.t2)?.id,
          'whisper-base-ggml');
      expect(starter.pickModel(ModelTask.vad, DeviceTier.t1)?.id, 'silero-vad');
      expect(starter.pickModel(ModelTask.llm, DeviceTier.t1), isNull);
      expect(starter.pickModel(ModelTask.llm, DeviceTier.t2)?.id,
          'qwen2.5-0.5b-instruct-litert');
    });

    test('sizes carry the research packet size classes', () {
      // ~41MB tiny / ~77MB base / ~2MB vad / ~500MB qwen q8 (research-ml.md).
      expect(starter.byId('whisper-tiny-ggml')!.sizeBytes,
          closeTo(41000000, 5000000));
      expect(starter.byId('whisper-base-ggml')!.sizeBytes,
          closeTo(77000000, 8000000));
      expect(starter.byId('silero-vad')!.sizeBytes, closeTo(2000000, 1000000));
      expect(starter.byId('qwen2.5-0.5b-instruct-litert')!.sizeBytes,
          closeTo(500000000, 50000000));
      // ~263MB fp32 (ADR-0007 Phase 0: no official quantized build exists,
      // and the one unofficial int8 repack failed verification — see the
      // ADR).
      expect(starter.byId('supertonic-en-m1')!.sizeBytes,
          closeTo(263000000, 5000000));
    });

    test('every file is https and every license named', () {
      for (final s in starter.specs) {
        expect(s.licenses, isNotEmpty);
        for (final f in s.files) {
          expect(f.url, startsWith('https://'));
        }
      }
    });

    test(
        'every starter file is PINNED to verified upstream facts: exact url, '
        'sha256 (computed locally from a real download), exact byte size '
        '(verified 2026-08-06)', () {
      // (url, sha256, bytes) per model id — each triple verified by
      // downloading the file and hashing it, not copied from a listing.
      const verified = <String, List<(String, String, int)>>{
        'whisper-tiny-ggml': [
          (
            'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny-q8_0.bin',
            'c2085835d3f50733e2ff6e4b41ae8a2b8d8110461e18821b09a15c40c42d1cca',
            43537433,
          ),
        ],
        'whisper-base-ggml': [
          (
            'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q8_0.bin',
            'c577b9a86e7e048a0b7eada054f4dd79a56bbfa911fbdacf900ac5b567cbb7d9',
            81768585,
          ),
        ],
        'silero-vad': [
          (
            'https://github.com/snakers4/silero-vad/raw/master/src/silero_vad/data/silero_vad.onnx',
            '1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3',
            2327524,
          ),
        ],
        // NOTE: the repo ships NO seq128 .task bundle — the only q8 .task is
        // the multi-prefill-seq variant. The old canonical-looking seq128
        // URL 404s; this is why pins are verified, not assumed.
        'qwen2.5-0.5b-instruct-litert': [
          (
            'https://huggingface.co/litert-community/Qwen2.5-0.5B-Instruct/resolve/main/Qwen2.5-0.5B-Instruct_multi-prefill-seq_q8_ekv1280.task',
            'e608953f169aeb1bd7b9155fec2559825e08453fc209b84eda3a781ed0452fd2',
            546660344,
          ),
        ],
        // Verified 2026-08-14: downloaded every file directly from
        // Supertone/supertonic-2 on Hugging Face and hashed it locally
        // (docs/reference/tts-voices.md has the OpenRAIL-M license text,
        // verbatim, with fetch date). File order here matches
        // registration order below, not [SupertonicVoiceLayout] — that
        // type names each file by role for the engine; this table just
        // has to cover the same seven files.
        'supertonic-en-m1': [
          (
            'https://huggingface.co/Supertone/supertonic-2/resolve/main/onnx/duration_predictor.onnx',
            '6d556b3691165c364be91dc0bd894656b5949f5acd2750d8ec2f954010845011',
            1521526,
          ),
          (
            'https://huggingface.co/Supertone/supertonic-2/resolve/main/onnx/text_encoder.onnx',
            'dd5f535ed629f7df86071043e15f541ce1b2ab7f1bdbce4c7892b307bca79fa3',
            27431318,
          ),
          (
            'https://huggingface.co/Supertone/supertonic-2/resolve/main/onnx/vector_estimator.onnx',
            '105e9d66fd8756876b210a6b4aa03fc393b1eaca3a8dadcc8d9a3bc785c86a35',
            132471364,
          ),
          (
            'https://huggingface.co/Supertone/supertonic-2/resolve/main/onnx/vocoder.onnx',
            '19bd51f47a186069c752403518a40f7ea4c647455056d2511f7249691ecddf7c',
            101405066,
          ),
          (
            'https://huggingface.co/Supertone/supertonic-2/resolve/main/onnx/unicode_indexer.json',
            'b7662a73a0703f43b97c0f2e089f8e8325e26f5d841aca393b5a54c509c92df1',
            262196,
          ),
          (
            'https://huggingface.co/Supertone/supertonic-2/resolve/main/onnx/tts.json',
            'ee531d9af9b80438a2ed703e22155ee6c83b12595ab22fd3bb6de94c7502fe96',
            8699,
          ),
          (
            'https://huggingface.co/Supertone/supertonic-2/resolve/main/voice_styles/M1.json',
            'a04c823cbda6dd1c7de131ec68fea83bbb70d7f29d61623304eb871e3b83b5a1',
            420510,
          ),
        ],
      };
      expect(starter.specs.map((s) => s.id).toSet(), verified.keys.toSet(),
          reason: 'the starter catalog and the verified-pins table must '
              'cover exactly the same models');
      for (final s in starter.specs) {
        final want = verified[s.id]!;
        expect(s.files.length, want.length, reason: '${s.id}: file count');
        for (var i = 0; i < want.length; i++) {
          final f = s.files[i];
          final (url, sha256, bytes) = want[i];
          expect(f.isPinned, isTrue,
              reason: '${s.id}[$i]: an unpinned file is not downloadable');
          expect(f.url, url, reason: '${s.id}[$i]: url');
          expect(f.sha256, sha256, reason: '${s.id}[$i]: sha256');
          expect(f.bytes, bytes, reason: '${s.id}[$i]: exact bytes');
        }
      }
    });
  });
}
