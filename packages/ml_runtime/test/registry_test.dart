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
    String? sourceLang,
  }) =>
      ModelSpec(
        id: id,
        task: task,
        files: [
          ModelFile.unverified(
              url: 'https://example.test/$id.bin', bytes: bytes)
        ],
        licenses: const ['MIT'],
        minTier: minTier,
        langs: langs,
        sourceLang: sourceLang,
      );

  group('ModelFile', () {
    test('an empty sha256 means unpinned', () {
      final f =
          ModelFile.unverified(url: 'https://example.test/m.bin', bytes: 10);
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
        () => ModelFile(
            url: 'https://example.test/m.bin', sha256: 'abc', bytes: 10),
        throwsArgumentError,
      );
      expect(
        () => ModelFile(
            url: 'https://example.test/m.bin', sha256: 'Z' * 64, bytes: 10),
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
      expect(
          () => ModelFile.unverified(url: '', bytes: 10), throwsArgumentError);
    });
  });

  group('VoiceArchiveLayout (TTS voices, ADR-0006)', () {
    test(
        'archiveLayout is null by default — every existing spec shape '
        'keeps compiling unchanged', () {
      expect(spec('plain', ModelTask.asr, DeviceTier.t1).archiveLayout, isNull);
    });

    test(
        'a TTS voice spec carries its archive layout — the "data, not '
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
    test(
        'supertonicLayout is null by default — every existing spec shape '
        'keeps compiling unchanged', () {
      expect(
          spec('plain', ModelTask.asr, DeviceTier.t1).supertonicLayout, isNull);
    });

    test(
        'a Supertonic voice spec names which downloaded filename plays '
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
              url: 'https://example.test/duration_predictor.onnx', bytes: 1000),
        ],
        licenses: const ['OpenRAIL-M'],
        minTier: DeviceTier.t2,
        supertonicLayout: layout,
      );
      expect(voice.supertonicLayout, same(layout));
    });
  });

  group('ModelSpec', () {
    test('sizeBytes is the sum of its files — derived, never a second copy',
        () {
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
          files: [
            ModelFile.unverified(url: 'https://example.test/m.bin', bytes: 1)
          ],
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

  group('pickTranslationPair — (source, target) selection (Campaign 8 '
      '"Babel widens")', () {
    // Three reverse pairs sharing the SAME target language ('en') — the
    // exact shape that breaks `pickModel`'s single langHint: three specs
    // would all carry `langs: {'en'}` and `pickModel` could not tell them
    // apart. `sourceLang` is the second axis `pickTranslationPair` adds.
    final reg = ModelRegistry([
      spec('opus-mt-en-es', ModelTask.translation, DeviceTier.t2,
          bytes: 248686982, langs: {'es'}, sourceLang: 'en'),
      spec('opus-mt-de-en', ModelTask.translation, DeviceTier.t2,
          bytes: 175000000, langs: {'en'}, sourceLang: 'de'),
      spec('opus-mt-ru-en', ModelTask.translation, DeviceTier.t2,
          bytes: 186000000, langs: {'en'}, sourceLang: 'ru'),
      spec('opus-mt-zh-en', ModelTask.translation, DeviceTier.t2,
          bytes: 193000000, langs: {'en'}, sourceLang: 'zh'),
    ]);

    test('three pairs producing the same target language are '
        'disambiguated by source language — the exact case pickModel '
        'cannot express', () {
      expect(
        reg.pickTranslationPair(DeviceTier.t2,
            sourceLang: 'de', targetLang: 'en')?.id,
        'opus-mt-de-en',
      );
      expect(
        reg.pickTranslationPair(DeviceTier.t2,
            sourceLang: 'ru', targetLang: 'en')?.id,
        'opus-mt-ru-en',
      );
      expect(
        reg.pickTranslationPair(DeviceTier.t2,
            sourceLang: 'zh', targetLang: 'en')?.id,
        'opus-mt-zh-en',
      );
    });

    test('the forward pair is found by its own (source, target)', () {
      expect(
        reg.pickTranslationPair(DeviceTier.t2,
            sourceLang: 'en', targetLang: 'es')?.id,
        'opus-mt-en-es',
      );
    });

    test('a (source, target) with no registered pair is null, never a '
        'guess', () {
      expect(
        reg.pickTranslationPair(DeviceTier.t2,
            sourceLang: 'en', targetLang: 'de'),
        isNull,
        reason: 'only de-en (reverse) is registered in this fixture, not '
            'en-de (forward)',
      );
      expect(
        reg.pickTranslationPair(DeviceTier.t2,
            sourceLang: 'fr', targetLang: 'en'),
        isNull,
      );
    });

    test('below the pair\'s tier finds nothing — T0 by design gets '
        'nothing', () {
      expect(
        reg.pickTranslationPair(DeviceTier.t1,
            sourceLang: 'de', targetLang: 'en'),
        isNull,
      );
    });

    test('a spec with no sourceLang never matches a real source '
        'language — half-populated data fails closed, not open', () {
      final r = ModelRegistry([
        spec('legacy-no-source', ModelTask.translation, DeviceTier.t2,
            langs: {'en'}),
      ]);
      expect(
        r.pickTranslationPair(DeviceTier.t2,
            sourceLang: 'de', targetLang: 'en'),
        isNull,
      );
    });
  });

  group('translationPairsAt — the picker\'s data source (Campaign 8)', () {
    test('lists only translation-task specs runnable at the tier, in no '
        'particular guaranteed order beyond registration', () {
      final reg = ModelRegistry([
        spec('opus-mt-en-es', ModelTask.translation, DeviceTier.t2,
            langs: {'es'}, sourceLang: 'en'),
        spec('opus-mt-en-de', ModelTask.translation, DeviceTier.t2,
            langs: {'de'}, sourceLang: 'en'),
        spec('whisper-tiny', ModelTask.asr, DeviceTier.t1),
        spec('t3-only-pair', ModelTask.translation, DeviceTier.t3,
            langs: {'ja'}, sourceLang: 'en'),
      ]);
      final at2 = reg.translationPairsAt(DeviceTier.t2);
      expect(at2.map((s) => s.id),
          containsAll(['opus-mt-en-es', 'opus-mt-en-de']));
      expect(at2.map((s) => s.id), isNot(contains('whisper-tiny')));
      expect(at2.map((s) => s.id), isNot(contains('t3-only-pair')),
          reason: 't3-only-pair needs a higher tier than t2 can run');
      expect(reg.translationPairsAt(DeviceTier.t3).map((s) => s.id),
          contains('t3-only-pair'));
    });
  });

  group('the starter registry', () {
    final starter = ModelRegistry.starter();

    test(
        'carries the pinned v1 catalog: whisper tiny/base ggml, silero '
        'vad, qwen2.5 litert, the supertonic starter voice, the Babel '
        'starter translation pair, the Wiktionary StarDict dictionary',
        () {
      expect(
        starter.specs.map((s) => s.id),
        containsAll([
          'whisper-tiny-ggml',
          'whisper-base-ggml',
          'silero-vad',
          'qwen2.5-0.5b-instruct-litert',
          'supertonic-en-m1',
          'opus-mt-en-es',
          'wiktionary-en-en-stardict',
        ]),
      );
    });

    test(
        'the Babel starter pair carries its loose-file layout, its '
        'target-language hint, and CC-BY-4.0 (ADR-0008 — the license '
        'record is docs/reference/mt-models.md)', () {
      final mt = starter.byId('opus-mt-en-es')!;
      expect(mt.task, ModelTask.translation);
      // T1 since 1.5.6: the app runs every device at T1.
      expect(mt.minTier, DeviceTier.t1);
      expect(mt.langs, {'es'});
      expect(mt.licenses, ['CC-BY-4.0']);
      final layout = mt.marianLayout;
      expect(layout, isNotNull);
      expect(layout!.encoderFileName, 'encoder_model_quantized.onnx');
      expect(
          layout.decoderMergedFileName, 'decoder_model_merged_quantized.onnx');
      expect(layout.sourceSpmFileName, 'source.spm');
      expect(layout.vocabFileName, 'vocab.json');
    });

    test(
        'picking a translation model by target-language hint finds the '
        'Babel starter pair; a tier below it finds nothing (T0 by design '
        'gets nothing)', () {
      expect(
        starter
            .pickModel(ModelTask.translation, DeviceTier.t1, langHint: 'es')
            ?.id,
        'opus-mt-en-es',
      );
      expect(
        starter.pickModel(ModelTask.translation, DeviceTier.t0, langHint: 'es'),
        isNull,
      );
      expect(
        starter.pickModel(ModelTask.translation, DeviceTier.t2, langHint: 'ko'),
        isNull,
        reason: 'no trusted en-ko ONNX export exists (task-C pair table)',
      );
    });

    test('the dictionary carries its archive layout, its dual license, and '
        'the dictionary task (Campaign 4 Phase 3)', () {
      final dict = starter.byId('wiktionary-en-en-stardict')!;
      expect(dict.task, ModelTask.dictionary);
      expect(dict.licenses, ['CC-BY-SA-3.0', 'GFDL-1.3']);
      final layout = dict.dictionaryArchiveLayout;
      expect(layout, isNotNull);
      expect(layout!.topLevelDir,
          'English-English Wiktionary dictionary stardict');
      expect(layout.ifoFileName, 'English-English Wiktionary dictionary.ifo');
      expect(layout.idxFileName, 'English-English Wiktionary dictionary.idx');
      expect(layout.dictFileName,
          'English-English Wiktionary dictionary.dict.dz');
    });

    test(
        'the starter voice carries its loose-file layout and its ONE '
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

    test(
        'the tier ladder matches the proposal-2 ML plan: T1 = tiny+vad, T2 = base+llm',
        () {
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
      // ~246MB for the int8-quantized encoder+decoder pair (ADR-0008):
      // larger than the spec's original ~113MB guess — verified by
      // downloading both files directly, not assumed from a listing.
      expect(starter.byId('opus-mt-en-es')!.sizeBytes,
          closeTo(246000000, 5000000));
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
        // Campaign 4 Phase 3: verified 2026-08-15 by downloading directly
        // and hashing locally (docs/reference/dictionaries.md has the
        // dual CC-BY-SA/GFDL license text, verbatim, with fetch date and
        // a manual format/extension verification against a real StarDict
        // random-access dictzip).
        'wiktionary-en-en-stardict': [
          (
            'https://raw.githubusercontent.com/Vuizur/Wiktionary-Dictionaries/master/English-English%20Wiktionary%20dictionary%20stardict.tar.gz',
            '2800f630d2975ea29a7b5763e7d79ed71dab9abcc6157534d75c7cd721e8b64b',
            21839699,
          ),
        ],
      };
      // Translation pairs are pinned in translation_catalog.dart and
      // checked by their own group below: 25 pairs x 6 files would make
      // this double entry longer than the catalog it guards.
      final nonTranslation =
          starter.specs.where((s) => s.task != ModelTask.translation);
      expect(nonTranslation.map((s) => s.id).toSet(), verified.keys.toSet(),
          reason: 'the starter catalog and the verified-pins table must '
              'cover exactly the same models');
      for (final s in nonTranslation) {
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

  group('the translation catalog (Trellis 1.5.5)', () {
    final starter = ModelRegistry.starter();
    final pairs = starter.translationPairsAt(DeviceTier.t3);

    test('every pair has pinned https files, a license, a source and a '
        'target, and a layout whose every role names a registered file', () {
      expect(pairs, isNotEmpty);
      for (final s in pairs) {
        expect(s.licenses, isNotEmpty, reason: s.id);
        expect(s.sourceLang, isNotNull, reason: s.id);
        expect(s.langs, hasLength(1), reason: s.id);
        expect(s.langs!.single, isNot(s.sourceLang), reason: s.id);
        expect(s.sizeBytes, greaterThan(50000000), reason: s.id);
        for (final f in s.files) {
          expect(f.url, startsWith('https://huggingface.co/'), reason: s.id);
          expect(f.isPinned, isTrue, reason: '${s.id} ${f.url}');
          expect(f.bytes, greaterThan(0), reason: '${s.id} ${f.url}');
        }
        final layout = s.marianLayout;
        expect(layout, isNotNull, reason: s.id);
        final names = {
          for (final f in s.files) Uri.parse(f.url).pathSegments.last
        };
        expect(
          names,
          containsAll([
            layout!.encoderFileName,
            layout.decoderMergedFileName,
            layout.sourceSpmFileName,
            layout.vocabFileName,
            layout.configFileName,
            layout.tokenizerConfigFileName,
          ]),
          reason: s.id,
        );
        expect(s.files, hasLength(6), reason: s.id);
        for (final f in s.files) {
          expect(f.url, matches(RegExp(r'/resolve/[0-9a-f]{40}/')),
              reason: '${s.id}: pinned to a commit, never main');
        }
      }
    });

    test('hub and spoke: every pair has English on exactly one end', () {
      for (final s in pairs) {
        expect((s.sourceLang == 'en') != (s.langs!.single == 'en'), isTrue,
            reason: s.id);
      }
    });

    test('one pair per direction: no two specs claim the same route', () {
      final routes = [for (final s in pairs) '${s.sourceLang}>${s.langs!.single}'];
      expect(routes.toSet(), hasLength(routes.length));
    });

    test('the English-first set: both directions where a trusted export '
        'exists, one-way where only X->en does', () {
      String? route(String src, String tgt) => starter
          .pickTranslationPair(DeviceTier.t2, sourceLang: src, targetLang: tgt)
          ?.id;
      for (final lang in [
        'fr', 'de', 'es', 'it', 'pt', 'nl', 'ru', 'zh', 'ar', 'hi', 'uk'
      ]) {
        expect(route('en', lang), isNotNull, reason: 'en->$lang');
        expect(route(lang, 'en'), isNotNull, reason: '$lang->en');
      }
      for (final lang in ['ja', 'ko', 'pl']) {
        expect(route(lang, 'en'), isNotNull, reason: '$lang->en');
        expect(route('en', lang), isNull,
            reason: 'no trusted en->$lang ONNX export (en-jap is incoherent)');
      }
    });

    test('multi-target exports carry the >>xx<< token that selects the '
        'language; bilingual ones carry none', () {
      expect(starter.byId('opus-mt-en-ROMANCE')!.marianLayout!.targetToken,
          '>>pt<<');
      expect(starter.byId('opus-mt-en-zh')!.marianLayout!.targetToken,
          '>>cmn_Hans<<');
      expect(starter.byId('opus-mt-en-ar')!.marianLayout!.targetToken,
          '>>ara<<');
      expect(starter.byId('opus-mt-en-de')!.marianLayout!.targetToken, isNull);
    });

    test('spot pins: the shipped en-es files are unchanged (a phone that '
        'has them must not re-download 246 MB) and en-ROMANCE matches the '
        'files downloaded and hashed for this pass', () {
      final es = starter.byId('opus-mt-en-es')!;
      expect(es.files[0].sha256,
          '13ec84a3afebfe97cae004a5f39881ea38541308514ec26c18a0b807476d6fba');
      expect(es.files[1].sha256,
          '832c4e0c1630a401f3115f0fcb08922f473b7f4996a5371d02ff880dc55f9399');
      expect(
          es.files[0].url,
          matches(RegExp(r'^https://huggingface\.co/onnx-community/'
              r'opus-mt-en-es/resolve/[0-9a-f]{40}/onnx/'
              r'encoder_model_quantized\.onnx$')));
      final pt = starter.byId('opus-mt-en-ROMANCE')!;
      expect(pt.files[0].sha256,
          'b4ddfd9338ba3d7c6b9c2d1410ed94fb7e06741226918cef6148031101bbd019');
      expect(pt.files[0].bytes, 52899742);
      expect(pt.files[1].sha256,
          'b5f6d442da7fa69f9d500df90373d2fdca4f799c43696b41888353b5c3c8eb13');
      expect(pt.files[1].bytes, 60212804);
    });
  });
}
