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

/// What a model does.
enum ModelTask { asr, vad, tts, llm, translation }

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
  /// multilingual models.
  final Set<String>? langs;

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

  ModelSpec({
    required this.id,
    required this.task,
    required List<ModelFile> files,
    required List<String> licenses,
    required this.minTier,
    Set<String>? langs,
    this.archiveLayout,
    this.supertonicLayout,
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
      ]);
}
