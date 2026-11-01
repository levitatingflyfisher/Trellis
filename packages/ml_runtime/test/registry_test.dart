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
      expect(reg.pickModel(ModelTask.tts, DeviceTier.t3), isNull);
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

  group('voiceFor and voiceLangs — one voice per language (board-0211)', () {
    final reg = ModelRegistry([
      spec('pocket-de', ModelTask.tts, DeviceTier.t1, langs: {'de'}),
      spec('kokoro-zh', ModelTask.tts, DeviceTier.t1, langs: {'zh'}),
      spec('multi', ModelTask.tts, DeviceTier.t1, langs: {'es', 'fr'}),
      spec('t3-voice', ModelTask.tts, DeviceTier.t3, langs: {'it'}),
      spec('no-langs', ModelTask.tts, DeviceTier.t1),
      spec('opus-mt-en-ko', ModelTask.translation, DeviceTier.t1,
          langs: {'ko'}, sourceLang: 'en'),
    ]);

    test('a language has a voice only when a tts spec names it', () {
      expect(reg.voiceFor('de', DeviceTier.t1)?.id, 'pocket-de');
      expect(reg.voiceFor('fr', DeviceTier.t1)?.id, 'multi');
      expect(reg.voiceFor('ko', DeviceTier.t1), isNull,
          reason: 'a translator is not a voice');
      expect(reg.voiceFor('ru', DeviceTier.t1), isNull,
          reason: 'a spec with no langs claims no language');
    });

    test('a region tag names its base language', () {
      expect(reg.voiceFor('zh-CN', DeviceTier.t1)?.id, 'kokoro-zh');
      expect(reg.voiceFor('DE_at', DeviceTier.t1)?.id, 'pocket-de');
      expect(reg.voiceFor('', DeviceTier.t1), isNull);
    });

    test('the tier gates a voice like any model', () {
      expect(reg.voiceFor('it', DeviceTier.t1), isNull);
      expect(reg.voiceFor('it', DeviceTier.t3)?.id, 't3-voice');
    });

    test('voiceLangs is every language some voice speaks at the tier', () {
      expect(reg.voiceLangs(DeviceTier.t1), {'de', 'zh', 'es', 'fr'});
      expect(reg.voiceLangs(DeviceTier.t3), contains('it'));
    });
  });

  group('the starter registry', () {
    test('Chinese is spoken by Kokoro v1.1-zh, from files Trellis hosts '
        'or pinned at an upstream revision (board-0211)', () {
      final starter = ModelRegistry.starter();
      final zh = starter.voiceFor('zh', DeviceTier.t1)!;
      expect(zh.id, 'kokoro-zh-zf001');
      expect(zh.langs, {'zh'});
      expect(zh.licenses, containsAll(['Apache-2.0', 'MIT']));
      final layout = zh.kokoroLayout!;
      final names = zh.files.map((f) => Uri.parse(f.url).pathSegments.last);
      expect(names, contains(layout.modelFileName));
      expect(names, contains(layout.voiceFileName));
      expect(layout.frontEndFileNames.keys, {
        'jiebaDict', 'finalsegHmm', 'possegHmm', 'pinyinSingle',
        'pinyinPhrases', 'pinyinAux', 'misakiTables',
      });
      expect(names, containsAll(layout.frontEndFileNames.values));
      for (final f in zh.files) {
        expect(f.sha256, hasLength(64), reason: f.url);
        expect(
            f.url.startsWith('https://github.com/levitatingflyfisher/Trellis/'
                    'releases/download/models-voices-1/') ||
                f.url.startsWith('https://huggingface.co/onnx-community/'
                    'Kokoro-82M-v1.1-zh-ONNX/resolve/'
                    '6cc0f0d2ebe369a68b0df87c2b65c1af8c0ac3e3/'),
            isTrue,
            reason: f.url);
      }
      expect(zh.files.firstWhere((f) => f.url.endsWith(layout.modelFileName)).sha256,
          'a628ea5d6fbde96d1a85f691a6a00847829937f9e488021ba2c5359bc6ea08b5',
          reason: 'thewh1teagle fp16: onnx-community fp16 returns NaN past '
              '30 phonemes');
    });

    test('seven languages are spoken by Pocket TTS: its own files from '
        'the Trellis release, one shared Mimi decoder, the tokenizer and '
        'a clean-licensed voice from Kyutai\'s ungated repository at a '
        'pinned revision (board-0211)', () {
      final starter = ModelRegistry.starter();
      const voices = {
        'de': ('german', 'caro_davy', 'CC0'),
        'en': ('english', 'bill_boerst', 'CC0'),
        'es': ('spanish', 'lola', 'CC0'),
        'fr': ('french', 'estelle', 'CC0'),
        'it': ('italian', 'giovanni', 'CC0'),
        'nl': ('dutch', 'daan', 'CC-BY-4.0'),
        'pt': ('portuguese', 'mary', 'CC-BY-4.0'),
      };
      const kyutai = 'https://huggingface.co/kyutai/'
          'pocket-tts-without-voice-cloning/resolve/'
          'a7056f505a4a8ca72d8b5fb1440071d6f1a35739/languages/';
      const release = 'https://github.com/levitatingflyfisher/Trellis/'
          'releases/download/models-voices-1/';
      ModelFile? mimi;
      for (final MapEntry(key: tag, value: (language, voice, licence))
          in voices.entries) {
        final spec = starter.voiceFor(tag, DeviceTier.t1)!;
        expect(spec.id, 'pocket-$tag');
        expect(spec.langs, {tag});
        expect(spec.licenses, contains('CC-BY-4.0'));
        final layout = spec.pocketLayout!;
        expect(layout.language, language);
        expect(layout.voiceFileName, '$voice.safetensors');
        expect(layout.voiceCredit, contains(licence));
        final byName = {
          for (final f in spec.files) Uri.parse(f.url).pathSegments.last: f
        };
        expect(byName.keys, hasLength(spec.files.length),
            reason: 'file names are unique within a voice');
        for (final name in [
          layout.textConditionerFileName,
          layout.mainFileName,
          layout.flowFileName,
          layout.mimiFileName,
          layout.tokenizerFileName,
          layout.voiceFileName,
        ]) {
          expect(byName[name], isNotNull, reason: '$tag $name');
        }
        expect(byName[layout.tokenizerFileName]!.url,
            '$kyutai$language/tokenizer.json');
        expect(byName[layout.voiceFileName]!.url,
            '$kyutai$language/embeddings/$voice.safetensors');
        for (final f in spec.files) {
          expect(f.sha256, hasLength(64), reason: f.url);
          expect(f.url.startsWith(release) || f.url.startsWith(kyutai),
              isTrue,
              reason: f.url);
          expect(f.shared, f.url.endsWith('pocket-mimi_decoder.onnx'),
              reason: 'only the decoder is shared: ${f.url}');
        }
        final m = byName[layout.mimiFileName]!;
        if (mimi != null) {
          expect((m.url, m.sha256, m.bytes),
              (mimi.url, mimi.sha256, mimi.bytes),
              reason: 'one decoder for every language');
        }
        mimi = m;
      }
    });

    test('Supertonic is retired: every language it spoke passed the gate '
        'with Pocket TTS (ADR-0022)', () {
      final starter = ModelRegistry.starter();
      expect(
          starter.specs.where((s) => s.licenses.contains('OpenRAIL-M')),
          isEmpty);
      expect(starter.voiceLangs(DeviceTier.t1),
          {'de', 'en', 'es', 'fr', 'it', 'nl', 'pt', 'zh'});
    });

    test('one voice per language: no two voices claim the same language '
        '(owner, 13 Nov)', () {
      final starter = ModelRegistry.starter();
      final seen = <String, String>{};
      for (final s in starter.specs.where((s) => s.task == ModelTask.tts)) {
        expect(s.langs, isNotNull, reason: '${s.id} names its languages');
        for (final l in s.langs!) {
          expect(seen[l], isNull,
              reason: '$l is claimed by both ${seen[l]} and ${s.id}');
          seen[l] = s.id;
        }
      }
    });

    test('the downloaded voice names every language it speaks, so a '
        'Spanish lookup finds it', () {
      final starter = ModelRegistry.starter();
      for (final l in ['en', 'es', 'fr', 'pt']) {
        expect(starter.voiceFor(l, DeviceTier.t1), isNotNull, reason: l);
      }
    });

    final starter = ModelRegistry.starter();

    test(
        'carries the pinned v1 catalog: whisper tiny/base ggml, silero '
        'vad, the English voice, the Babel '
        'starter translation pair, the Wiktionary StarDict dictionary',
        () {
      expect(
        starter.specs.map((s) => s.id),
        containsAll([
          'whisper-tiny-ggml',
          'whisper-base-ggml',
          'silero-vad',
          'pocket-en',
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
        'the tier ladder matches the proposal-2 ML plan: T1 = tiny+vad, T2 = base',
        () {
      expect(starter.byId('whisper-tiny-ggml')!.minTier, DeviceTier.t1);
      expect(starter.byId('silero-vad')!.minTier, DeviceTier.t1);
      expect(starter.byId('whisper-base-ggml')!.minTier, DeviceTier.t2);
    });

    test('registry has no Qwen spec (1.5.9: unused, and no Chinese-vendor '
        'models; a small assistant returns with Gemma in 1.7)', () {
      expect(starter.specs.where((s) => s.id.toLowerCase().contains('qwen')),
          isEmpty);
      expect(
          starter.specs.where(
              (s) => s.files.any((f) => f.url.toLowerCase().contains('qwen'))),
          isEmpty);
    });

    test('selection over the starter catalog follows the ladder', () {
      expect(starter.pickModel(ModelTask.asr, DeviceTier.t1)?.id,
          'whisper-tiny-ggml');
      expect(starter.pickModel(ModelTask.asr, DeviceTier.t2)?.id,
          'whisper-base-ggml');
      expect(starter.pickModel(ModelTask.vad, DeviceTier.t1)?.id, 'silero-vad');
    });

    test('whisper small is on offer but is nobody’s default on a phone: it '
        'is registered above the phone tiers, so only a choice reaches it',
        () {
      expect(starter.byId('whisper-small-ggml')!.minTier, DeviceTier.t3);
      expect(starter.byId('whisper-small-ggml')!.licenses, ['MIT']);
      expect(starter.pickModel(ModelTask.asr, DeviceTier.t1)?.id,
          'whisper-tiny-ggml');
      expect(starter.pickModel(ModelTask.asr, DeviceTier.t2)?.id,
          'whisper-base-ggml');
    });

    test('the neural voice is picked at t1, the tier the app runs at '
        '(1.5.8: at t2 it downloaded and never played)', () {
      expect(starter.byId('pocket-en')!.minTier, DeviceTier.t1);
      expect(starter.pickModel(ModelTask.tts, DeviceTier.t1, langHint: 'en')?.id,
          'pocket-en');
      // Lowering the voice must not move transcription off tiny.
      expect(starter.pickModel(ModelTask.asr, DeviceTier.t1)?.id,
          'whisper-tiny-ggml');
    });

    test('sizes carry the research packet size classes', () {
      // ~41MB tiny / ~77MB base / ~2MB vad (research-ml.md).
      expect(starter.byId('whisper-tiny-ggml')!.sizeBytes,
          closeTo(41000000, 5000000));
      expect(starter.byId('whisper-base-ggml')!.sizeBytes,
          closeTo(77000000, 8000000));
      expect(starter.byId('silero-vad')!.sizeBytes, closeTo(2000000, 1000000));
      // ~151MB for a Pocket TTS language, the shared 41MB decoder
      // counted in (ADR-0022: int8 flow transformer and flow net).
      expect(starter.byId('pocket-en')!.sizeBytes,
          closeTo(151000000, 5000000));
      // ~116MB since 1.5.9: onnx-community's encoder with Xenova's int8
      // merged decoder (60MB, down from onnx-community's 193MB, which
      // was barely quantised); parity-checked before the swap.
      expect(starter.byId('opus-mt-en-es')!.sizeBytes,
          closeTo(116000000, 5000000));
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
        // Verified 2026-11-10: downloaded and hashed, and equal to the
        // hash Hugging Face publishes for the file.
        'whisper-small-ggml': [
          (
            'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q8_0.bin',
            '49c8fb02b65e6049d5fa6c04f81f53b867b5ec9540406812c643f177317f779f',
            264464607,
          ),
        ],
        'silero-vad': [
          (
            'https://github.com/snakers4/silero-vad/raw/master/src/silero_vad/data/silero_vad.onnx',
            '1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3',
            2327524,
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
      // Trellis's own voices are pinned in voice_catalog.dart and
      // checked in their own tests, for the same reason.
      final ownVoices = voiceCatalog().map((s) => s.id).toSet();
      final nonTranslation = starter.specs.where((s) =>
          s.task != ModelTask.translation && !ownVoices.contains(s.id));
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
        for (final (i, f) in s.files.indexed) {
          // A pair Trellis converted itself (ADR-0014's amendment) takes
          // its two graphs from a Trellis release; everything else, and
          // its own four small files, from Hugging Face.
          expect(
              f.url,
              startsWith(s.convertedFrom != null && i < 2
                  ? 'https://github.com/levitatingflyfisher/Trellis/releases/download/'
                  : 'https://huggingface.co/'),
              reason: s.id);
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
        for (final (i, f) in s.files.indexed) {
          // A release asset is pinned by its hash alone; ADR-0014's
          // amendment requires it be downloaded back and matched first.
          if (s.convertedFrom != null && i < 2) continue;
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
      for (final lang in ['ko', 'pl']) {
        expect(route(lang, 'en'), isNotNull, reason: '$lang->en');
        expect(route('en', lang), isNull,
            reason: 'no trusted en->$lang ONNX export');
      }
      expect(route('ja', 'en'), 'elanmt-bt-ja-en',
          reason: 'converted by Trellis; it replaced opus-mt-ja-en, which '
              'scored BLEU 13.32 against its 19.16 on 300 NTREX lines');
      expect(starter.byId('opus-mt-ja-en'), isNull,
          reason: 'one pair for Japanese to English');
      expect(route('en', 'ja'), 'elanmt-bt-en-ja',
          reason: 'converted by Trellis (ADR-0014 amendment)');
    });

    test('1.6.13 widens the set: each new pair is there, and a pair on a '
        'multi-language model names its language token', () {
      ModelSpec? pair(String src, String tgt) => starter
          .pickTranslationPair(DeviceTier.t1, sourceLang: src, targetLang: tgt);
      for (final lang in ['af', 'cs', 'da', 'fi', 'hu', 'id', 'sv', 'vi',
          'xh', 'ro', 'gl', 'tr', 'eo']) {
        expect(pair('en', lang), isNotNull, reason: 'en->$lang');
        expect(pair(lang, 'en'), isNotNull, reason: '$lang->en');
      }
      for (final lang in ['ca', 'et', 'lt', 'lv', 'th', 'hr', 'mk', 'ml',
          'sl']) {
        expect(pair(lang, 'en'), isNotNull, reason: '$lang->en');
        expect(pair('en', lang), isNull,
            reason: 'en->$lang failed its run or has no clean export');
      }
      expect(pair('en', 'ga'), isNotNull);
      expect(pair('ga', 'en'), isNull,
          reason: 'mul-en lost the meaning of Irish');
      const tokens = {
        'vi': '>>vie<<',
        'gl': '>>gl<<',
        'eo': '>>epo<<',
        'ga': '>>gle<<',
      };
      tokens.forEach((lang, token) {
        expect(pair('en', lang)!.marianLayout!.targetToken, token,
            reason: 'en->$lang');
      });
      expect(pair('en', 'sv')!.marianLayout!.targetToken, isNull);
      expect(pair('en', 'tr')!.licenses, ['CC-BY-4.0']);
    });

    test('English to Japanese is ElanMT-BT, converted by Trellis: its two '
        'graphs from the Trellis release, its small files from the upstream '
        'commit, each pinned as the conversion made it', () {
      final ja = starter.byId('elanmt-bt-en-ja')!;
      expect(ja.sourceLang, 'en');
      expect(ja.langs, {'ja'});
      expect(ja.licenses, ['CC-BY-SA-4.0']);
      expect(ja.convertedFrom, 'ElanMT-BT (Mitsua/elan-mt-bt-en-ja)');
      expect(ja.marianLayout!.targetToken, isNull);
      const hf = 'https://huggingface.co/Mitsua/elan-mt-bt-en-ja/resolve/'
          '02c48e7031386cd2d41974b0ff1aaf52f010c5fa/';
      const rel = 'https://github.com/levitatingflyfisher/Trellis/releases/download/models-enja-1/';
      expect([for (final f in ja.files) (f.url, f.sha256, f.bytes)], [
        (
          '${rel}encoder_model_quantized.onnx',
          'b8698e3dee264d0e71d4bdd7469933c33a0ca4e08fb377a10dee70e528d3a7cc',
          35890766
        ),
        (
          '${rel}decoder_model_merged_quantized.onnx',
          '5ae7b58e2bfb69f67f0183fbb612a2145f902b5bc47567d844738c99c75b2463',
          59457806
        ),
        (
          '${hf}source.spm',
          'a6824c2996a4877cae8a0240f11a112ab0e4ea1f22e54cd42179376fe558f4ff',
          792751
        ),
        (
          '${hf}vocab.json',
          'f508b75734ee21cf16b3816b7b29dea400f1f5998f47b7695cef1979ca49e106',
          881911
        ),
        (
          '${hf}config.json',
          '78298efb7b70a119900886b41de089e2543c1234bb7d767defa09ea494cb7ab7',
          1075
        ),
        (
          '${hf}tokenizer_config.json',
          '3c4a72a28f4db53dbf21d87b35d0ebee03ea76304f95940a809f9e18ab5220aa',
          854
        ),
      ]);
      expect(ja.sizeBytes, 97025163);
    });

    test('Japanese to English is ElanMT-BT, converted by Trellis: its two '
        'graphs from the Trellis release, its small files from the upstream '
        'commit, each pinned as the conversion made it', () {
      final en = starter.byId('elanmt-bt-ja-en')!;
      expect(en.sourceLang, 'ja');
      expect(en.langs, {'en'});
      expect(en.licenses, ['CC-BY-SA-4.0']);
      expect(en.convertedFrom, 'ElanMT-BT (Mitsua/elan-mt-bt-ja-en)');
      expect(en.marianLayout!.targetToken, isNull);
      const hf = 'https://huggingface.co/Mitsua/elan-mt-bt-ja-en/resolve/'
          '539f80eb05306e27a166b45e4264c7fa2eb4de97/';
      const rel = 'https://github.com/levitatingflyfisher/Trellis/releases/download/models-jaen-1/';
      expect([for (final f in en.files) (f.url, f.sha256, f.bytes)], [
        (
          '${rel}encoder_model_quantized.onnx',
          'cd4aba53f281351e20e708be365494f4c9f7cfcdbb64d4f498620b9c5cbb837f',
          35890766
        ),
        (
          '${rel}decoder_model_merged_quantized.onnx',
          '37f568860465ef6f164025640bbad3bf1af917df9ef617faa4056dba8719e189',
          59457806
        ),
        (
          '${hf}source.spm',
          'a6824c2996a4877cae8a0240f11a112ab0e4ea1f22e54cd42179376fe558f4ff',
          792751
        ),
        (
          '${hf}vocab.json',
          'f508b75734ee21cf16b3816b7b29dea400f1f5998f47b7695cef1979ca49e106',
          881911
        ),
        (
          '${hf}config.json',
          '78298efb7b70a119900886b41de089e2543c1234bb7d767defa09ea494cb7ab7',
          1075
        ),
        (
          '${hf}tokenizer_config.json',
          '93fc43bf001eae301e111352d2f993d1fb9ccb408dda2fa51644c0c3a34c5a66',
          854
        ),
      ]);
      expect(en.sizeBytes, 97025163);
    });

    test('only a converted pair names what it was converted from', () {
      for (final s in pairs) {
        if (s.id == 'elanmt-bt-en-ja' || s.id == 'elanmt-bt-ja-en') continue;
        expect(s.convertedFrom, isNull, reason: s.id);
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

    test('spot pins: the shipped en-es encoder is unchanged (a phone that '
        'has it fetches only the new 60 MB decoder, 1.5.9) and en-ROMANCE '
        'matches the files downloaded and hashed for this pass', () {
      final es = starter.byId('opus-mt-en-es')!;
      expect(es.files[0].sha256,
          '13ec84a3afebfe97cae004a5f39881ea38541308514ec26c18a0b807476d6fba');
      expect(es.files[1].sha256,
          '58ee5ddd6e22d1693d8722b90c1486afb93700a4376cf28fd74175052ad530ae');
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
