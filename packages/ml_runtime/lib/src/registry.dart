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

import 'translation_catalog.dart';
import 'voice_catalog.dart';

/// What a model does. [dictionary] is data, not inference (Campaign 4
/// Phase 3: a StarDict set) — it rides the same pinned-file/archive-
/// extraction/download-engine law as every other entry, so it earns a
/// task rather than a parallel registry.
enum ModelTask { asr, vad, tts, translation, dictionary }

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

  /// The same file serves several models (Pocket TTS's one Mimi decoder
  /// for every language): the store keeps one copy for all of them,
  /// named by the URL's last segment, which must then be unique to it.
  final bool shared;

  ModelFile(
      {required this.url,
      required this.sha256,
      required this.bytes,
      this.shared = false}) {
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

/// Which downloaded filename plays which role for a Pocket TTS voice
/// (board-0211): Trellis's own export of Kyutai's weights, one language
/// each, with Kyutai's ready voice state; the Mimi decoder is one file
/// shared by every language ([ModelFile.shared]).
class PocketVoiceLayout {
  /// Kyutai's name for the language's weights (`german`, `french`...).
  final String language;
  final String textConditionerFileName;
  final String mainFileName;
  final String flowFileName;
  final String mimiFileName;
  final String tokenizerFileName;
  final String voiceFileName;

  /// Who the voice is and its licence, shown with it: the credit a
  /// CC-BY voice asks for.
  final String voiceCredit;

  const PocketVoiceLayout({
    required this.language,
    required this.textConditionerFileName,
    required this.mainFileName,
    required this.flowFileName,
    required this.mimiFileName,
    required this.tokenizerFileName,
    required this.voiceFileName,
    required this.voiceCredit,
  });
}

/// Which downloaded filename plays which role for a Kokoro voice
/// (board-0211): the ONNX model, the voice's style rows, and the data
/// its Chinese text front end reads, by role (`jiebaDict`,
/// `finalsegHmm`, `possegHmm`, `pinyinSingle`, `pinyinPhrases`,
/// `pinyinAux`, `misakiTables`). Every file ships loose.
class KokoroVoiceLayout {
  final String modelFileName;
  final String voiceFileName;
  final Map<String, String> frontEndFileNames;

  const KokoroVoiceLayout({
    required this.modelFileName,
    required this.voiceFileName,
    required this.frontEndFileNames,
  });
}

/// Which downloaded filename plays which role for a Marian (opus-mt)
/// translation model (ADR-0008 "Babel") — the same "data, not code"
/// rule the voice layouts follow: a new [ModelSpec] with a new
/// [MarianModelLayout] is a complete translation pair, no engine change.
/// Every file ships loose, each downloaded and sha256-verified on its
/// own — nothing to extract. `target.spm` is deliberately absent: it
/// only tokenizes text for the OTHER direction, and this engine's decode
/// path reverses the joint `vocab.json` instead of running a second
/// SentencePiece model — see docs/reference/mt-models.md. The two config
/// files carry the numbers that differ per model (dims, decoder start,
/// pad, banned ids, whether the vocab is joint); the engine reads them
/// rather than assuming the first pair's values.
class MarianModelLayout {
  final String encoderFileName;
  final String decoderMergedFileName;
  final String sourceSpmFileName;
  final String vocabFileName;
  final String configFileName;
  final String tokenizerConfigFileName;

  /// A multi-target export's `>>xx<<` token (en-ROMANCE writes Portuguese
  /// only when told `>>pt<<`), prepended to the source ids. Null for a
  /// bilingual pair.
  final String? targetToken;

  const MarianModelLayout({
    required this.encoderFileName,
    required this.decoderMergedFileName,
    required this.sourceSpmFileName,
    required this.vocabFileName,
    required this.configFileName,
    required this.tokenizerConfigFileName,
    this.targetToken,
  });
}

/// Which extracted filename plays which role for a StarDict dictionary
/// archive (Campaign 4 Phase 3) — the "data, not code" surface for adding
/// a dictionary: the pinned file is a `.tar.gz`, and the usable artifact
/// is the `.ifo`/`.idx`/`.dict.dz` trio inside it.
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

/// [tag]'s base language, lower case: `zh-CN` and `ZH_tw` are `zh`.
String baseLangTag(String tag) =>
    tag.trim().toLowerCase().split(RegExp('[-_]')).first;

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

  /// Non-null for a Kokoro voice (board-0211).
  final KokoroVoiceLayout? kokoroLayout;

  /// Non-null for a Pocket TTS voice (board-0211).
  final PocketVoiceLayout? pocketLayout;

  /// Non-null for a Marian translation pair (ADR-0008) — see
  /// [MarianModelLayout].
  final MarianModelLayout? marianLayout;

  /// Non-null for a StarDict dictionary archive (Campaign 4 Phase 3) —
  /// see [DictionaryArchiveLayout]. The model store's completeness law
  /// for it is "the extracted directory exists" (an atomic rename, so
  /// existence IS completeness), not the pinned byte length.
  final DictionaryArchiveLayout? dictionaryArchiveLayout;

  /// Set only for a model Trellis converted itself (ADR-0014's amendment
  /// of 2026-11-11): the upstream model it was made from, by name and
  /// where it lives, for the Models screen's “Converted by Trellis from”
  /// line. Null for a model taken as its maker published it.
  final String? convertedFrom;

  ModelSpec({
    required this.id,
    required this.task,
    required List<ModelFile> files,
    required List<String> licenses,
    required this.minTier,
    Set<String>? langs,
    this.sourceLang,
    this.kokoroLayout,
    this.pocketLayout,
    this.marianLayout,
    this.dictionaryArchiveLayout,
    this.convertedFrom,
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

  /// The voice that speaks [lang] (a bare or region tag) at [tier]: the
  /// tts spec whose [ModelSpec.langs] names it, one per language (owner,
  /// 13 Nov, board-0211). Null when none does. Unlike [pickModel], a spec
  /// that names no languages never matches: a voice must say what it
  /// speaks.
  ModelSpec? voiceFor(String lang, DeviceTier tier) {
    final base = baseLangTag(lang);
    if (base.isEmpty) return null;
    for (final s in specs) {
      if (s.task != ModelTask.tts) continue;
      if (!tier.atLeast(s.minTier)) continue;
      if (s.langs?.contains(base) ?? false) return s;
    }
    return null;
  }

  /// Every language some voice speaks at [tier].
  Set<String> voiceLangs(DeviceTier tier) => {
        for (final s in specs)
          if (s.task == ModelTask.tts && tier.atLeast(s.minTier))
            ...?s.langs,
      };

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
        // By choice only (1.6.0): whisper small, for a phone that can
        // carry it. Registered at t3 so that no phone tier ever picks it
        // by itself; the app's "Transcription quality" choice reaches it
        // by id. Hash computed from a download on 2026-11-10 and equal to
        // the one Hugging Face publishes.
        ModelSpec(
          id: 'whisper-small-ggml',
          task: ModelTask.asr,
          files: [
            ModelFile(
              url:
                  'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q8_0.bin',
              sha256:
                  '49c8fb02b65e6049d5fa6c04f81f53b867b5ec9540406812c643f177317f779f',
              bytes: 264464607,
            ),
          ],
          licenses: const ['MIT'],
          minTier: DeviceTier.t3,
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
        // Trellis's own voices, one per language (board-0211;
        // voice_catalog.dart holds the pins and the provenance).
        ...voiceCatalog(),
        // T1 translation: every Marian pair, English on one end
        // (translation_catalog.dart holds the pins and the provenance).
        ...translationCatalog(),
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
