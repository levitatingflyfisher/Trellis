/// The model registry — the fleet's model-trust laws made local.
///
/// Every downloadable model is a [ModelSpec]: an id, its task, its files
/// (each `url + sha256 + bytes`), its licenses, and the lowest device tier
/// that should run it. Selection ([ModelRegistry.pickModel]) is a pure
/// function of (task, tier, language hint).
///
/// Download code lives in the app on domovoi's `ResumableTransfer` and MUST
/// fail closed: a file whose [ModelFile.isPinned] is false is not
/// downloadable — no hash, no bytes. The starter catalog ships fully pinned
/// to verified upstream facts (see [ModelRegistry.starter]).
library;

/// What a model does. [dictionary] is data, not inference (Campaign 4
/// Phase 3: a StarDict set) — it rides the same pinned-file/archive-
/// extraction/download-engine law as every other entry, so it earns a
/// task rather than a parallel registry.
enum ModelTask { asr, vad, tts, llm, translation, dictionary }

/// The device-capability ladder (proposal-2 "ML plan"):
///
///  * [t0] — zero models. System TTS, keyword-coverage grading. Every
///    surface, honest baseline.
///  * [t1] — any Android including potato phones: whisper-tiny + silero VAD.
///  * [t2] — good phone / any desktop: whisper-base class, Piper/Kokoro
///    voices, a small local LLM.
///  * [t3] — the household tier: a paired desktop over the stove does the
///    heavy lifting; no bigger *local* model is implied on this device.
enum DeviceTier {
  t0,
  t1,
  t2,
  t3;

  bool atLeast(DeviceTier other) => index >= other.index;
}

final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

/// One downloadable file of a model: where it lives, what it must hash to,
/// and how big it is.
class ModelFile {
  final String url;

  /// Lowercase-hex SHA-256 of the file, or the empty string while unpinned.
  final String sha256;

  final int bytes;

  ModelFile({required this.url, required this.sha256, required this.bytes}) {
    if (url.isEmpty) throw ArgumentError('ModelFile: url must not be empty');
    if (bytes <= 0) throw ArgumentError('ModelFile: bytes must be positive');
    if (sha256.isNotEmpty && !_sha256Pattern.hasMatch(sha256)) {
      throw ArgumentError(
          'ModelFile: sha256 must be empty (unpinned) or 64 lowercase hex chars');
    }
  }

  /// A file with no hash yet: registered, sized, but not yet verified.
  /// Fail-closed download code refuses these.
  ModelFile.unverified({required String url, required int bytes})
      : this(url: url, sha256: '', bytes: bytes);

  /// True when a real content hash is pinned; only pinned files may be
  /// downloaded.
  bool get isPinned => sha256.isNotEmpty;

  @override
  String toString() =>
      'ModelFile($url, $bytes bytes, ${isPinned ? 'pinned' : 'UNPINNED'})';
}

/// Where a downloaded archive's usable files live once extracted — the
/// "data, not code" surface for adding a TTS voice (ADR-0006): a new
/// [ModelSpec] with a new [VoiceArchiveLayout] is a complete voice; no
/// engine code changes. Every sherpa-onnx release tarball unpacks to
/// exactly one top-level directory, which extraction strips so the
/// voice's own directory is flat.
class VoiceArchiveLayout {
  final String topLevelDir;
  final String modelFileName;
  final String tokensFileName;
  final String dataDirName;

  const VoiceArchiveLayout({
    required this.topLevelDir,
    required this.modelFileName,
    required this.tokensFileName,
    required this.dataDirName,
  });
}

/// Which downloaded filename plays which role for a Supertonic voice
/// (ADR-0007) — the "data, not code" surface for adding a voice, one
/// level over from [VoiceArchiveLayout]: these files ship LOOSE, each
/// downloaded and sha256-verified on its own under `<baseDir>/<id>/`
/// (the existing per-file promotion law every plain [ModelSpec] already
/// follows — the same one whisper's single file uses), so there is
/// nothing to extract and no directory to promote. This layout exists
/// only so the engine never has to guess which loose file is which.
class SupertonicVoiceLayout {
  final String durationPredictorFileName;
  final String textEncoderFileName;
  final String vectorEstimatorFileName;
  final String vocoderFileName;
  final String unicodeIndexerFileName;
  final String ttsConfigFileName;
  final String voiceStyleFileName;

  const SupertonicVoiceLayout({
    required this.durationPredictorFileName,
    required this.textEncoderFileName,
    required this.vectorEstimatorFileName,
    required this.vocoderFileName,
    required this.unicodeIndexerFileName,
    required this.ttsConfigFileName,
    required this.voiceStyleFileName,
  });
}

/// Which downloaded filename plays which role for a Marian (opus-mt)
/// translation model (ADR-0008 "Babel") — the same "data, not code"
/// precedent [SupertonicVoiceLayout] set: a new [ModelSpec] with a new
/// [MarianModelLayout] is a complete translation pair, no engine change.
/// All four files ship loose, each downloaded and sha256-verified on its
/// own — nothing to extract. `target.spm` is deliberately absent: it
/// only tokenizes text for the OTHER direction (es->en), and this
/// engine's decode path reverses the joint `vocab.json` instead of
/// running a second SentencePiece model — see docs/reference/mt-models.md.
class MarianModelLayout {
  final String encoderFileName;
  final String decoderMergedFileName;
  final String sourceSpmFileName;
  final String vocabFileName;

  const MarianModelLayout({
    required this.encoderFileName,
    required this.decoderMergedFileName,
    required this.sourceSpmFileName,
    required this.vocabFileName,
  });
}

/// Which extracted filename plays which role for a StarDict dictionary
/// archive (Campaign 4 Phase 3) — the "data, not code" surface for adding
/// a dictionary, one level over from [VoiceArchiveLayout]: the pinned
/// file is a `.tar.gz` (not `.tar.bz2` — a separate extraction path from
/// the voice one, since the two archive formats differ), and the usable
/// artifact is the `.ifo`/`.idx`/`.dict.dz` trio inside it.
class DictionaryArchiveLayout {
  final String topLevelDir;
  final String ifoFileName;
  final String idxFileName;
  final String dictFileName;

  const DictionaryArchiveLayout({
    required this.topLevelDir,
    required this.ifoFileName,
    required this.idxFileName,
    required this.dictFileName,
  });
}

/// One model in the catalog.
class ModelSpec {
  final String id;
  final ModelTask task;
  final List<ModelFile> files;

  /// SPDX-style license names covering weights and (where relevant) engine.
  final List<String> licenses;

  /// The lowest [DeviceTier] this model is the right pick for.
  final DeviceTier minTier;

  /// Languages this model serves, or `null` for language-agnostic /
  /// multilingual models. For [ModelTask.translation] this names the
  /// TARGET language a pair PRODUCES (ADR-0008) — [sourceLang] is the
  /// other half.
  final Set<String>? langs;

  /// [ModelTask.translation] ONLY: the language a pair translates FROM.
  /// `null` for every other task (meaningless there) and for a
  /// translation spec that hasn't named one — [ModelRegistry
  /// .pickTranslationPair] treats an unset [sourceLang] as never
  /// matching a real source language (fails closed on half-populated
  /// data, never guesses). Exists because [langs] alone cannot
  /// disambiguate multiple pairs that share a target language — `de-en`,
  /// `ru-en`, and `zh-en` all produce `en` (Campaign 8 "Babel widens";
  /// see docs/reference/mt-models.md). Deliberately NOT read by
  /// [pickModel]/[supportsLang] — those stay exactly as ASR/TTS need
  /// them; only [pickTranslationPair] looks at this field.
  final String? sourceLang;

  /// Non-null for a downloaded file that is an ARCHIVE needing extraction
  /// before use (a TTS voice bundle, currently the only case) — the
  /// model store's completeness law changes from "exact pinned byte
  /// length" to "the extracted directory exists" (an atomic rename, so
  /// existence IS completeness).
  final VoiceArchiveLayout? archiveLayout;

  /// Non-null for a Supertonic voice (ADR-0007) whose files ship loose —
  /// see [SupertonicVoiceLayout]. Mutually meaningful alongside
  /// [archiveLayout] only in the sense that a real spec picks at most one
  /// shape; nothing enforces that here, the same way nothing enforces it
  /// for [archiveLayout] today.
  final SupertonicVoiceLayout? supertonicLayout;

  /// Non-null for a Marian translation pair (ADR-0008) — see
  /// [MarianModelLayout].
  final MarianModelLayout? marianLayout;

  /// Non-null for a StarDict dictionary archive (Campaign 4 Phase 3) —
  /// see [DictionaryArchiveLayout]. A different extraction path from
  /// [archiveLayout] (that one is a `.tar.bz2` voice bundle; this is a
  /// `.tar.gz` dictionary set), so the two stay separate fields rather
  /// than one generalized "any archive" shape — the model store's own
  /// extraction code branches on which of these is set.
  final DictionaryArchiveLayout? dictionaryArchiveLayout;

  ModelSpec({
    required this.id,
    required this.task,
    required List<ModelFile> files,
    required List<String> licenses,
    required this.minTier,
    Set<String>? langs,
    this.sourceLang,
    this.archiveLayout,
    this.supertonicLayout,
    this.marianLayout,
    this.dictionaryArchiveLayout,
  })  : files = List.unmodifiable(files),
        licenses = List.unmodifiable(licenses),
        langs = langs == null ? null : Set.unmodifiable(langs) {
    if (id.isEmpty) throw ArgumentError('ModelSpec: id must not be empty');
    if (this.files.isEmpty) {
      throw ArgumentError('ModelSpec $id: at least one file required');
    }
    if (this.licenses.isEmpty) {
      throw ArgumentError('ModelSpec $id: licenses must be named');
    }
  }

  /// Total download size — derived from the files, never a second copy.
  int get sizeBytes => files.fold(0, (sum, f) => sum + f.bytes);

  /// Whether this model can serve [lang] (`null` hint constrains nothing).
  bool supportsLang(String? lang) =>
      lang == null || langs == null || langs!.contains(lang);

  @override
  String toString() => 'ModelSpec($id, $task, min $minTier, $sizeBytes bytes)';
}

/// An immutable model catalog plus the selection law.
class ModelRegistry {
  final List<ModelSpec> specs;
  final Map<String, ModelSpec> _byId;

  ModelRegistry(List<ModelSpec> specs)
      : specs = List.unmodifiable(specs),
        _byId = {} {
    for (final s in this.specs) {
      if (_byId.containsKey(s.id)) {
        throw ArgumentError('ModelRegistry: duplicate model id "${s.id}"');
      }
      _byId[s.id] = s;
    }
  }

  ModelSpec? byId(String id) => _byId[id];

  /// The selection law: among specs matching [task], runnable at [tier]
  /// (`minTier <= tier`) and serving [langHint], pick the most capable —
  /// highest [ModelSpec.minTier] first, then largest [ModelSpec.sizeBytes],
  /// then registration order. Returns `null` when nothing qualifies (T0 by
  /// design gets nothing).
  ModelSpec? pickModel(ModelTask task, DeviceTier tier, {String? langHint}) {
    ModelSpec? best;
    for (final s in specs) {
      if (s.task != task) continue;
      if (!tier.atLeast(s.minTier)) continue;
      if (!s.supportsLang(langHint)) continue;
      if (best == null) {
        best = s;
        continue;
      }
      final tierCmp = s.minTier.index.compareTo(best.minTier.index);
      if (tierCmp > 0 || (tierCmp == 0 && s.sizeBytes > best.sizeBytes)) {
        best = s;
      }
      // Full tie: `best` (registered earlier) stands — deterministic.
    }
    return best;
  }

  /// The (source, target) selection law for translation pairs (Campaign 8
  /// "Babel widens"): [pickModel]'s single `langHint` cannot disambiguate
  /// two pairs that produce the same target language (`de-en`/`ru-en`/
  /// `zh-en` all carry `langs: {'en'}`) — this method matches BOTH
  /// [ModelSpec.sourceLang] and [ModelSpec.langs] and leaves [pickModel]
  /// itself untouched for ASR/TTS. Same tie-break as [pickModel]: highest
  /// [ModelSpec.minTier] first, then largest [ModelSpec.sizeBytes], then
  /// registration order. A spec with `sourceLang == null` never matches —
  /// half-populated data fails closed.
  ModelSpec? pickTranslationPair(
    DeviceTier tier, {
    required String sourceLang,
    required String targetLang,
  }) {
    ModelSpec? best;
    for (final s in specs) {
      if (s.task != ModelTask.translation) continue;
      if (!tier.atLeast(s.minTier)) continue;
      if (s.sourceLang != sourceLang) continue;
      if (!s.supportsLang(targetLang)) continue;
      if (best == null) {
        best = s;
        continue;
      }
      final tierCmp = s.minTier.index.compareTo(best.minTier.index);
      if (tierCmp > 0 || (tierCmp == 0 && s.sizeBytes > best.sizeBytes)) {
        best = s;
      }
    }
    return best;
  }

  /// Every translation pair runnable at [tier] — the target-language
  /// picker's data source (Campaign 8 "Babel widens" Phase 1): "list
  /// ONLY downloaded+openable pairs" is a caller-side concern (an
  /// `isDownloaded` check per spec), this just enumerates what the
  /// registry itself knows how to run at all.
  List<ModelSpec> translationPairsAt(DeviceTier tier) => specs
      .where((s) =>
          s.task == ModelTask.translation && tier.atLeast(s.minTier))
      .toList(growable: false);

  /// The pinned v1 starter catalog (proposal-2 "ML plan").
  ///
  /// Every file is PINNED: url verified live, sha256 computed locally from a
  /// real download, byte size exact (verified 2026-08-06). Any upstream
  /// change breaks the hash and download code fails closed — re-verify and
  /// re-pin deliberately, never loosen.
  factory ModelRegistry.starter() => ModelRegistry([
        // T1 ASR — whisper.cpp multilingual ggml, q8_0 ("int8/q8 is the
        // right pick below small": the q4 decoder anomaly, research-ml).
        ModelSpec(
          id: 'whisper-tiny-ggml',
          task: ModelTask.asr,
          files: [
            ModelFile(
              url:
                  'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny-q8_0.bin',
              sha256:
                  'c2085835d3f50733e2ff6e4b41ae8a2b8d8110461e18821b09a15c40c42d1cca',
              bytes: 43537433,
            ),
          ],
          licenses: const ['MIT'],
          minTier: DeviceTier.t1,
        ),
        // T2 ASR — the better multilingual pick on a good phone / desktop.
        ModelSpec(
          id: 'whisper-base-ggml',
          task: ModelTask.asr,
          files: [
            ModelFile(
              url:
                  'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q8_0.bin',
              sha256:
                  'c577b9a86e7e048a0b7eada054f4dd79a56bbfa911fbdacf900ac5b567cbb7d9',
              bytes: 81768585,
            ),
          ],
          licenses: const ['MIT'],
          minTier: DeviceTier.t2,
        ),
        // T1 VAD — gates silent windows ahead of whisper (the "Careless
        // Whisper" hallucination mitigation). Language-agnostic.
        ModelSpec(
          id: 'silero-vad',
          task: ModelTask.vad,
          files: [
            ModelFile(
              url:
                  'https://github.com/snakers4/silero-vad/raw/master/src/silero_vad/data/silero_vad.onnx',
              sha256:
                  '1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3',
              bytes: 2327524,
            ),
          ],
          licenses: const ['MIT'],
          minTier: DeviceTier.t1,
        ),
        // T2 LLM — the fleet's clean-license pick: Apache-2.0, ungated
        // (research-ml: Qwen is "the only friction-free family" for a
        // no-account product). The 1.5B variant for 4GB+ phones is the
        // integrator's to add alongside its verified size.
        //
        // The only q8 .task bundle the repo ships is the multi-prefill-seq
        // variant — the canonical-looking seq128 .task URL 404s (only a
        // .tflite exists at seq128). Verified against the live file tree.
        ModelSpec(
          id: 'qwen2.5-0.5b-instruct-litert',
          task: ModelTask.llm,
          files: [
            ModelFile(
              url:
                  'https://huggingface.co/litert-community/Qwen2.5-0.5B-Instruct/resolve/main/Qwen2.5-0.5B-Instruct_multi-prefill-seq_q8_ekv1280.task',
              sha256:
                  'e608953f169aeb1bd7b9155fec2559825e08453fc209b84eda3a781ed0452fd2',
              bytes: 546660344,
            ),
          ],
          licenses: const ['Apache-2.0'],
          minTier: DeviceTier.t2,
        ),
        // T2 TTS — the Supertonic rung's starter voice (ADR-0007): the
        // official Supertone/supertonic-2 weights (v2: 66M params,
        // en/ko/es/pt/fr — this entry claims only English, the one
        // speaker embedding shipped and reviewed here), fp32 ONNX
        // (~263MB). No official quantized build exists, and the one
        // unofficial int8 repack found (csukuangfj2) carries no license
        // at all and ships its support files (unicode indexer, voice
        // embedding) in a binary format this engine's ported inference
        // code cannot read — both disqualifying on their own; the ADR
        // records the full accounting. Voice: M1 (the official Flutter
        // example's own default). Verified 2026-08-14 by downloading
        // every file directly and hashing it locally; full verbatim
        // OpenRAIL-M text + fetch date: docs/reference/tts-voices.md.
        //
        // Needs NO phonemizer — the model consumes raw character indices
        // (unicode_indexer.json below) — so there is nothing for a GPL
        // dependency to hide in, unlike the sherpa/Piper rung this
        // replaces. `licenses` carries exactly one name now: OpenRAIL-M
        // for the weights: there is no second, engine-side license to
        // co-list, because flutter_onnxruntime and Supertonic's engine
        // code are both MIT — the APK stays MIT-clean end to end.
        ModelSpec(
          id: 'supertonic-en-m1',
          task: ModelTask.tts,
          files: [
            ModelFile(
              url:
                  'https://huggingface.co/Supertone/supertonic-2/resolve/main/onnx/duration_predictor.onnx',
              sha256:
                  '6d556b3691165c364be91dc0bd894656b5949f5acd2750d8ec2f954010845011',
              bytes: 1521526,
            ),
            ModelFile(
              url:
                  'https://huggingface.co/Supertone/supertonic-2/resolve/main/onnx/text_encoder.onnx',
              sha256:
                  'dd5f535ed629f7df86071043e15f541ce1b2ab7f1bdbce4c7892b307bca79fa3',
              bytes: 27431318,
            ),
            ModelFile(
              url:
                  'https://huggingface.co/Supertone/supertonic-2/resolve/main/onnx/vector_estimator.onnx',
              sha256:
                  '105e9d66fd8756876b210a6b4aa03fc393b1eaca3a8dadcc8d9a3bc785c86a35',
              bytes: 132471364,
            ),
            ModelFile(
              url:
                  'https://huggingface.co/Supertone/supertonic-2/resolve/main/onnx/vocoder.onnx',
              sha256:
                  '19bd51f47a186069c752403518a40f7ea4c647455056d2511f7249691ecddf7c',
              bytes: 101405066,
            ),
            ModelFile(
              url:
                  'https://huggingface.co/Supertone/supertonic-2/resolve/main/onnx/unicode_indexer.json',
              sha256:
                  'b7662a73a0703f43b97c0f2e089f8e8325e26f5d841aca393b5a54c509c92df1',
              bytes: 262196,
            ),
            ModelFile(
              url:
                  'https://huggingface.co/Supertone/supertonic-2/resolve/main/onnx/tts.json',
              sha256:
                  'ee531d9af9b80438a2ed703e22155ee6c83b12595ab22fd3bb6de94c7502fe96',
              bytes: 8699,
            ),
            ModelFile(
              url:
                  'https://huggingface.co/Supertone/supertonic-2/resolve/main/voice_styles/M1.json',
              sha256:
                  'a04c823cbda6dd1c7de131ec68fea83bbb70d7f29d61623304eb871e3b83b5a1',
              bytes: 420510,
            ),
          ],
          licenses: const ['OpenRAIL-M'],
          minTier: DeviceTier.t2,
          langs: const {'en'},
          supertonicLayout: const SupertonicVoiceLayout(
            durationPredictorFileName: 'duration_predictor.onnx',
            textEncoderFileName: 'text_encoder.onnx',
            vectorEstimatorFileName: 'vector_estimator.onnx',
            vocoderFileName: 'vocoder.onnx',
            unicodeIndexerFileName: 'unicode_indexer.json',
            ttsConfigFileName: 'tts.json',
            voiceStyleFileName: 'M1.json',
          ),
        ),
        // T2 translation — Babel's starter pair (ADR-0008): opus-mt-en-es,
        // int8-quantized ONNX (onnx-community's conversion of
        // Helsinki-NLP/opus-mt-en-es). `langs` names the TARGET language
        // this entry produces ('es') — the only interpretation that lets
        // `pickModel(ModelTask.translation, tier, langHint: 'es')` mean
        // "give me something that can produce Spanish", which is the
        // question the reader screen actually asks (a work's source
        // language is a property of the work, not the model catalog).
        // Verified 2026-08-14 by downloading every file directly and
        // hashing it locally; full verbatim license text + fetch date:
        // docs/reference/mt-models.md (the spec's own note that the HF
        // card reads Apache-2.0 was backwards from what was actually
        // found there — CC-BY-4.0 is what onnx-community's card carries;
        // upstream Helsinki-NLP's own card is the one that says
        // Apache-2.0. Both are recorded verbatim in that file).
        ModelSpec(
          id: 'opus-mt-en-es',
          task: ModelTask.translation,
          files: [
            ModelFile(
              url: 'https://huggingface.co/onnx-community/opus-mt-en-es/'
                  'resolve/main/onnx/encoder_model_quantized.onnx',
              sha256:
                  '13ec84a3afebfe97cae004a5f39881ea38541308514ec26c18a0b807476d6fba',
              bytes: 52875078,
            ),
            ModelFile(
              url: 'https://huggingface.co/onnx-community/opus-mt-en-es/'
                  'resolve/main/onnx/decoder_model_merged_quantized.onnx',
              sha256:
                  '832c4e0c1630a401f3115f0fcb08922f473b7f4996a5371d02ff880dc55f9399',
              bytes: 193290224,
            ),
            ModelFile(
              url: 'https://huggingface.co/onnx-community/opus-mt-en-es/'
                  'resolve/main/source.spm',
              sha256:
                  '4dd547c24816a335e7b0b2e63376a8f1b3cbfc671eda5ab808dd44fdadaa8791',
              bytes: 801636,
            ),
            ModelFile(
              url: 'https://huggingface.co/onnx-community/opus-mt-en-es/'
                  'resolve/main/vocab.json',
              sha256:
                  'b074b4cca0036ade5a39ea97faabd534e1015482c480fc2cb02c6481983eb163',
              bytes: 1720044,
            ),
          ],
          licenses: const ['CC-BY-4.0'],
          minTier: DeviceTier.t2,
          langs: const {'es'},
          // Campaign 8 "Babel widens" Phase 1: added so this field is
          // never half-populated now that pickTranslationPair exists —
          // additive, changes no prior behavior (pickModel never reads
          // it).
          sourceLang: 'en',
          marianLayout: const MarianModelLayout(
            encoderFileName: 'encoder_model_quantized.onnx',
            decoderMergedFileName: 'decoder_model_merged_quantized.onnx',
            sourceSpmFileName: 'source.spm',
            vocabFileName: 'vocab.json',
          ),
        ),
        // Campaign 8 "Babel widens" Phase 0/1 — de/ru/zh, both
        // directions each: verified 2026-08-15 by downloading every
        // ONNX/tokenizer file directly and hashing it locally (plus
        // cross-checked against Hugging Face's tree API `lfs.oid`/`size`
        // fields, themselves validated against this exact es entry's own
        // pinned hashes above — see docs/reference/mt-models.md for the
        // full record, the real-inference quality check per pair, and
        // why `en-pt`/`pt-en` (no trusted-org bilingual ONNX conversion)
        // and `en-jap`/`jap-en` (Japanese — real inference produces
        // incoherent output even after fixing a pad-token decode
        // collapse the model's own config admits to) are NOT registered
        // here despite being in the spec's priority list — both are
        // Phase 5 Brain-lane languages instead, not silently dropped.
        ModelSpec(
          id: 'opus-mt-en-de',
          task: ModelTask.translation,
          files: [
            ModelFile(
              url: 'https://huggingface.co/onnx-community/opus-mt-en-de/'
                  'resolve/main/onnx/encoder_model_quantized.onnx',
              sha256:
                  '94ae6a9149aca29ef31a58bb8ccc1c3df3720840caef890ccc6cde73c94cb0f4',
              bytes: 49342278,
            ),
            ModelFile(
              url: 'https://huggingface.co/onnx-community/opus-mt-en-de/'
                  'resolve/main/onnx/decoder_model_merged_quantized.onnx',
              sha256:
                  '492004d70327f4552fbddba033f8d8ce946edb87b66cbf8f9a7b41d14fe683cc',
              bytes: 175598624,
            ),
            ModelFile(
              url: 'https://huggingface.co/onnx-community/opus-mt-en-de/'
                  'resolve/main/source.spm',
              sha256:
                  '678f2a1177d8389f67b66299762dcc4fc567e89b07e212ba91b0c56daecf47ce',
              bytes: 768489,
            ),
            ModelFile(
              url: 'https://huggingface.co/onnx-community/opus-mt-en-de/'
                  'resolve/main/vocab.json',
              sha256:
                  'd5acea957b265a78554999144459c5e391e0df525864edc8287bc090290baa44',
              bytes: 1389436,
            ),
          ],
          licenses: const ['CC-BY-4.0'],
          minTier: DeviceTier.t2,
          langs: const {'de'},
          sourceLang: 'en',
          marianLayout: const MarianModelLayout(
            encoderFileName: 'encoder_model_quantized.onnx',
            decoderMergedFileName: 'decoder_model_merged_quantized.onnx',
            sourceSpmFileName: 'source.spm',
            vocabFileName: 'vocab.json',
          ),
        ),
        ModelSpec(
          id: 'opus-mt-de-en',
          task: ModelTask.translation,
          files: [
            ModelFile(
              url: 'https://huggingface.co/onnx-community/opus-mt-de-en/'
                  'resolve/main/onnx/encoder_model_quantized.onnx',
              sha256:
                  '3e7b95246cf1885b5c6c123a36818a417c3ef6f500d4c17e030fef427fff7a74',
              bytes: 49342278,
            ),
            ModelFile(
              url: 'https://huggingface.co/onnx-community/opus-mt-de-en/'
                  'resolve/main/onnx/decoder_model_merged_quantized.onnx',
              sha256:
                  'd789d6a132d540fa40d6fa5901c3ba1e6209c69bf201ffef54f73833fa9b5a6c',
              bytes: 175598624,
            ),
            ModelFile(
              url: 'https://huggingface.co/onnx-community/opus-mt-de-en/'
                  'resolve/main/source.spm',
              sha256:
                  'bbd1f495eea99c8e21ae086d9146e0fa7b096c3dfdd9ba07ab8b631889df5c9b',
              bytes: 796845,
            ),
            ModelFile(
              url: 'https://huggingface.co/onnx-community/opus-mt-de-en/'
                  'resolve/main/vocab.json',
              sha256:
                  'd5acea957b265a78554999144459c5e391e0df525864edc8287bc090290baa44',
              bytes: 1389436,
            ),
          ],
          licenses: const ['CC-BY-4.0'],
          minTier: DeviceTier.t2,
          langs: const {'en'},
          sourceLang: 'de',
          marianLayout: const MarianModelLayout(
            encoderFileName: 'encoder_model_quantized.onnx',
            decoderMergedFileName: 'decoder_model_merged_quantized.onnx',
            sourceSpmFileName: 'source.spm',
            vocabFileName: 'vocab.json',
          ),
        ),
        ModelSpec(
          id: 'opus-mt-en-ru',
          task: ModelTask.translation,
          files: [
            ModelFile(
              url: 'https://huggingface.co/onnx-community/opus-mt-en-ru/'
                  'resolve/main/onnx/encoder_model_quantized.onnx',
              sha256:
                  'b8b4f72528c0da92e579af8a739f97fa2f792d73527ba2fee786fa7286c4055b',
              bytes: 51603782,
            ),
            ModelFile(
              url: 'https://huggingface.co/onnx-community/opus-mt-en-ru/'
                  'resolve/main/onnx/decoder_model_merged_quantized.onnx',
              sha256:
                  '5d15c48566e60dcaa5af7422bcceca24ccc8f3eaa8f1b3aedc5d6170e6c232f3',
              bytes: 186923812,
            ),
            ModelFile(
              url: 'https://huggingface.co/onnx-community/opus-mt-en-ru/'
                  'resolve/main/source.spm',
              sha256:
                  '16bebef1389a0b8ab452772c4e35b9e605e5713f8ac7baa71ca701394eaa086d',
              bytes: 802781,
            ),
            ModelFile(
              url: 'https://huggingface.co/onnx-community/opus-mt-en-ru/'
                  'resolve/main/vocab.json',
              sha256:
                  '5cf0d95d930d8d3e783c9e2f46a72f08b43a18060dab4ddefbcb66a733efedcb',
              bytes: 2726796,
            ),
          ],
          licenses: const ['CC-BY-4.0'],
          minTier: DeviceTier.t2,
          langs: const {'ru'},
          sourceLang: 'en',
          marianLayout: const MarianModelLayout(
            encoderFileName: 'encoder_model_quantized.onnx',
            decoderMergedFileName: 'decoder_model_merged_quantized.onnx',
            sourceSpmFileName: 'source.spm',
            vocabFileName: 'vocab.json',
          ),
        ),
        ModelSpec(
          id: 'opus-mt-ru-en',
          task: ModelTask.translation,
          files: [
            ModelFile(
              url: 'https://huggingface.co/onnx-community/opus-mt-ru-en/'
                  'resolve/main/onnx/encoder_model_quantized.onnx',
              sha256:
                  'fdd4d1de9cb02feaae8bc892e0e21b1bfd1741fa43a2895d471ee5f53ae260c4',
              bytes: 51603782,
            ),
            ModelFile(
              url: 'https://huggingface.co/onnx-community/opus-mt-ru-en/'
                  'resolve/main/onnx/decoder_model_merged_quantized.onnx',
              sha256:
                  '0fef11505dc0564d0d6d54e37529d7ba949826fe19fd7193052610989fccbf28',
              bytes: 186923812,
            ),
            ModelFile(
              url: 'https://huggingface.co/onnx-community/opus-mt-ru-en/'
                  'resolve/main/source.spm',
              sha256:
                  '745998e51ba5b058e38b7ac7765c25c43ed5c1c39cc92b27163b9b2e323c9d7c',
              bytes: 1080169,
            ),
            ModelFile(
              url: 'https://huggingface.co/onnx-community/opus-mt-ru-en/'
                  'resolve/main/vocab.json',
              sha256:
                  '5cf0d95d930d8d3e783c9e2f46a72f08b43a18060dab4ddefbcb66a733efedcb',
              bytes: 2726796,
            ),
          ],
          licenses: const ['CC-BY-4.0'],
          minTier: DeviceTier.t2,
          langs: const {'en'},
          sourceLang: 'ru',
          marianLayout: const MarianModelLayout(
            encoderFileName: 'encoder_model_quantized.onnx',
            decoderMergedFileName: 'decoder_model_merged_quantized.onnx',
            sourceSpmFileName: 'source.spm',
            vocabFileName: 'vocab.json',
          ),
        ),
        // en-zh (English source -> Chinese output) is NOT registered —
        // evaluated, not shipped, same "record what doesn't ship" law
        // Phase 0 already applied to ja/pt, but for a DIFFERENT reason:
        // translation quality is real (usable, if less fluent than es/
        // de/ru), but the app has no verified way to DISPLAY the Chinese
        // output. A golden-test render of the scroll-mode dual display
        // (app/test/visual/cjk_font_golden_test.dart) showed tofu boxes;
        // the app's bundled fonts (Lora/Nunito) carry zero CJK glyphs,
        // and this app's own C7 conformance law (`fleet_conformance_test
        // .dart`) already establishes the fleet's answer to a missing
        // glyph as "never depend on an unverified system font" — Lora/
        // Nunito are BUNDLED for exactly this reason. Bundling a CJK
        // font to close the gap the honest way was costed, not assumed:
        // Noto Sans SC's own single-weight, single-region subset OTF is
        // 8,331,336 bytes (verified by downloading and measuring
        // notofonts/noto-cjk's Sans2.004 release,
        // SubsetOTF/SC/NotoSansSC-Regular.otf, OFL-1.1) against
        // `app/budgets.json`'s ~3.3MB of remaining C3 APK headroom
        // (71,888,630 max vs. 68,465,362 measured) — it does not fit.
        // See docs/reference/mt-models.md for the full writeup.
        // zh-en: excellent quality, on par with es/de/ru (verified with
        // real inference — see docs/reference/mt-models.md).
        ModelSpec(
          id: 'opus-mt-zh-en',
          task: ModelTask.translation,
          files: [
            ModelFile(
              url: 'https://huggingface.co/onnx-community/opus-mt-zh-en/'
                  'resolve/main/onnx/encoder_model_quantized.onnx',
              sha256:
                  '86b0dc5a1d5d8062583800654864aae1311fce2172bba80910d02020d3693577',
              bytes: 52875078,
            ),
            ModelFile(
              url: 'https://huggingface.co/onnx-community/opus-mt-zh-en/'
                  'resolve/main/onnx/decoder_model_merged_quantized.onnx',
              sha256:
                  '714881fafd326c8cb56bc6e3e542d1d106a5acf90e6abb71e20423ebf1b47875',
              bytes: 193290224,
            ),
            ModelFile(
              url: 'https://huggingface.co/onnx-community/opus-mt-zh-en/'
                  'resolve/main/source.spm',
              sha256:
                  'e27a3a1b539f4959ec72ea60e453f49156289f95d4e6000b29332efc45616203',
              bytes: 804677,
            ),
            ModelFile(
              url: 'https://huggingface.co/onnx-community/opus-mt-zh-en/'
                  'resolve/main/vocab.json',
              sha256:
                  '08a119a1defd522fa047cb5e3bfe3e89633e96caa38ced0dc9cee7ef1021a011',
              bytes: 1747906,
            ),
          ],
          licenses: const ['CC-BY-4.0'],
          minTier: DeviceTier.t2,
          langs: const {'en'},
          sourceLang: 'zh',
          marianLayout: const MarianModelLayout(
            encoderFileName: 'encoder_model_quantized.onnx',
            decoderMergedFileName: 'decoder_model_merged_quantized.onnx',
            sourceSpmFileName: 'source.spm',
            vocabFileName: 'vocab.json',
          ),
        ),
        // Campaign 4 Phase 3 — the StarDict door: an English-English
        // Wiktionary dictionary (real StarDict .ifo/.idx/.dict.dz, a
        // genuine random-access dictzip — verified, not assumed; see
        // docs/reference/dictionaries.md). Not gated by [langs]: the
        // dictionary itself only serves English headwords, but nothing in
        // this door's own selection needs a langHint the way TTS/ASR do,
        // so it's left unset rather than encoding a constraint nothing
        // reads yet.
        ModelSpec(
          id: 'wiktionary-en-en-stardict',
          task: ModelTask.dictionary,
          files: [
            ModelFile(
              url:
                  'https://raw.githubusercontent.com/Vuizur/Wiktionary-Dictionaries/master/English-English%20Wiktionary%20dictionary%20stardict.tar.gz',
              sha256:
                  '2800f630d2975ea29a7b5763e7d79ed71dab9abcc6157534d75c7cd721e8b64b',
              bytes: 21839699,
            ),
          ],
          licenses: const ['CC-BY-SA-3.0', 'GFDL-1.3'],
          minTier: DeviceTier.t0,
          dictionaryArchiveLayout: const DictionaryArchiveLayout(
            topLevelDir: 'English-English Wiktionary dictionary stardict',
            ifoFileName: 'English-English Wiktionary dictionary.ifo',
            idxFileName: 'English-English Wiktionary dictionary.idx',
            dictFileName: 'English-English Wiktionary dictionary.dict.dz',
          ),
        ),
      ]);
}
