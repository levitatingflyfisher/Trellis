/// The P3 device stack, bundled for injection: where model/audio/PCM files
/// live, which download/decode/transcribe implementations run, and how the
/// whisper engine is named for the executor's isolate.
///
/// `DeviceServices.real` wires the platform truth (domovoi engine over dio,
/// ffmpeg on Android, the isolate executor, the Android foreground gate).
/// Tests build one from fakes — no test ever touches a socket, a platform
/// channel, or an isolate it didn't ask for.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:stardict_core/stardict_core.dart';

import '../features/models/model_store.dart';
import '../features/reader/speech/speech_engine.dart';
import '../features/reader/speech/supertonic_engine.dart';
import '../features/reader/speech/supertonic_voice_handle.dart';
import '../features/reader/speech/speech_temp_files.dart';
import '../features/dsp/dsp_encoder.dart';
import '../features/dsp/dsp_ffmpeg_encoder.dart';
import '../features/reader/translation/marian_engine.dart';
import '../features/transcribe/audio_fetcher.dart';
import '../features/transcribe/decoder.dart';
import '../features/transcribe/ffmpeg_decoder.dart';
import '../features/transcribe/foreground_gate.dart';
import '../features/transcribe/transcribe_executor.dart';

/// Reads text aloud — the seam over the platform TTS engine, so speak mode
/// stays testable off-device: tests inject a fake whose utterances complete
/// on fake-time beats, and no widget test ever touches the TTS channel.
///
/// [speak]'s future completes when the utterance FINISHES (or is stopped) —
/// the reader's speak loop paces itself on that completion, segment by
/// segment (ADR-0002: the cursor advances with speech).
abstract interface class TtsSpeaker {
  Future<void> speak(String text, {String? lang});
  Future<void> stop();
  Future<void> setRate(double r);
}

/// The platform truth: flutter_tts with utterance-completion awaited, so
/// [speak] resolves when the engine is done, matching the seam contract.
/// Construction is cheap (a MethodChannel handle); nothing reaches the
/// platform until the first call.
///
/// Chrome's speechSynthesis has a well-known >15s stall bug; the ADR-0006
/// research plan called for a periodic pause()/resume() keep-alive tick
/// here. Verified against the pinned flutter_tts (4.2.5, pubspec.lock):
/// its own web implementation (`flutter_tts_web.dart`) ALREADY runs this
/// exact workaround internally — a `Timer.periodic(Duration(seconds: 14))`
/// calling `synth.pause(); synth.resume();` for the duration of any
/// utterance spoken with a non-local voice. Adding a second one here would
/// duplicate — and could race — the plugin's own timer, which the fleet's
/// "no second copy" law rules out. The residual gap (a LOCAL voice, which
/// the plugin's guard skips) is closed by ADR-0006's sentence-level speak
/// loop instead: a single sentence essentially never approaches the 14s
/// threshold that only matters for an un-mitigated long utterance, so
/// there is nothing left here for this class to do.
class FlutterTtsSpeaker implements TtsSpeaker {
  FlutterTts? _tts;
  String? _lang;

  Future<FlutterTts> _engine() async {
    if (_tts != null) return _tts!;
    final tts = FlutterTts();
    await tts.awaitSpeakCompletion(true);
    return _tts = tts;
  }

  @override
  Future<void> speak(String text, {String? lang}) async {
    final tts = await _engine();
    if (lang != null && lang != _lang) {
      await tts.setLanguage(lang);
      _lang = lang;
    }
    await tts.speak(text);
  }

  @override
  Future<void> stop() async => (await _engine()).stop();

  @override
  Future<void> setRate(double r) async => (await _engine()).setSpeechRate(r);
}

/// Silence for surfaces that never speak (detached services, plain widget
/// tests): utterances complete immediately, nothing touches a channel.
class NoopTtsSpeaker implements TtsSpeaker {
  @override
  Future<void> speak(String text, {String? lang}) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> setRate(double r) async {}
}

/// The web tier's fetch-routing decision (the Skein household daemon).
/// Resolved once, at boot, by a same-origin probe (bootstrap_web.dart's
/// `probeWebFetchLane`) — never re-probed, so it can't flap mid-session.
/// Native tiers never probe and stay [direct] forever: Skein only exists
/// to solve the browser's CORS wall, and native apps fetch directly.
enum WebFetchLane {
  /// The plain browser fetch — most cross-site reads get refused by the
  /// target site (no proxy, by design).
  direct,

  /// A Skein daemon answered `/api/health` on this very origin: the page
  /// and the fetcher share one origin now, so CORS dissolves.
  skein,
}

class DeviceServices {
  final Directory supportDir;
  final ModelStore modelStore;
  final ModelRegistry registry;
  final Decoder decoder;
  final AudioFetcher audioFetcher;
  final TranscribeExecutor executor;
  final JobForegroundGate foregroundGate;
  final DeviceTier tier;

  /// The offline DSP preprocess's platform boundary (Campaign 6). Optional
  /// with an honest-refusal default ([UnavailableDspEncoder]) so every
  /// existing construction site stays additive — only `.real()`'s Android
  /// branch and tests that actually exercise DSP ever pass a real one.
  final DspEncoder dspEncoder;

  /// The speak-mode voice. Optional with a silent default so the fakes-only
  /// test constructor stays additive; the platform wiring passes the real
  /// engine.
  final TtsSpeaker tts;

  /// Names the engine the executor's far side should build for an
  /// installed model file. Tests substitute a scripted engine.
  final TranscribeEngineSpec Function(String modelPath) engineFor;

  /// Where drift keeps the database, when the platform knows (main.dart
  /// wires it; drift_flutter's default is documents-dir/trellis.sqlite).
  /// Null for memory databases — the storage panel skips its row.
  final File? databaseFile;

  /// Whether this tier can run local ML at all (model downloads, whisper
  /// transcription). False on the web tier — the PWA reads, studies,
  /// listens and backs up; local ML rides the installed app — and the UI
  /// doors consult this so they never offer what must fail (proposal-2
  /// §1: honest about the tier).
  final bool localMlAvailable;

  /// The web tier's fetch-routing decision — see [WebFetchLane]. Meaningless
  /// off the web tier; always [WebFetchLane.direct] there, since it's never
  /// consulted for anything but the two web-only intake doors.
  final WebFetchLane webFetchLane;

  DeviceServices({
    required this.supportDir,
    required this.modelStore,
    required this.registry,
    required this.decoder,
    required this.audioFetcher,
    required this.executor,
    required this.foregroundGate,
    required this.engineFor,
    TtsSpeaker? tts,
    DspEncoder? dspEncoder,
    this.databaseFile,
    this.localMlAvailable = true,
    this.tier = DeviceTier.t1,
    this.webFetchLane = WebFetchLane.direct,
  }) : tts = tts ?? NoopTtsSpeaker(),
       dspEncoder = dspEncoder ?? UnavailableDspEncoder();

  /// The platform wiring. [supportDir] is the app-support directory
  /// (path_provider), resolved by an async `main` before `runApp`.
  factory DeviceServices.real(Directory supportDir, {File? databaseFile}) =>
      DeviceServices(
        supportDir: supportDir,
        modelStore: DiskModelStore(
          baseDir: Directory('${supportDir.path}/models'),
        ),
        registry: ModelRegistry.starter(),
        decoder: _isAndroid ? FfmpegDecoder() : WavPassthroughDecoder(),
        audioFetcher: DioAudioFetcher(),
        executor: IsolateTranscribeExecutor(),
        foregroundGate: _isAndroid
            ? AndroidJobForegroundGate()
            : NoopJobForegroundGate(),
        tts: FlutterTtsSpeaker(),
        dspEncoder: _isAndroid ? FfmpegDspEncoder() : UnavailableDspEncoder(),
        databaseFile: databaseFile,
        engineFor: (modelPath) => WhisperEngineSpec(
          modelPath: modelPath,
          libraryPath: whisperLibraryPath(),
        ),
      );

  /// A placeholder for surfaces that never start a P3 flow (plain widget
  /// tests): everything is present, nothing touches a platform. The support
  /// dir points into systemTemp and is only created if actually used.
  factory DeviceServices.detached() {
    final dir = Directory(
      '${Directory.systemTemp.path}/trellis-detached-services',
    );
    return DeviceServices(
      supportDir: dir,
      modelStore: DiskModelStore(baseDir: Directory('${dir.path}/models')),
      registry: ModelRegistry.starter(),
      decoder: WavPassthroughDecoder(),
      audioFetcher: DioAudioFetcher(),
      executor: InlineTranscribeExecutor(),
      foregroundGate: NoopJobForegroundGate(),
      engineFor: (modelPath) => WhisperEngineSpec(
        modelPath: modelPath,
        libraryPath: whisperLibraryPath(),
      ),
    );
  }

  static bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  /// Where the whisper shim lives per platform: the APK's jniLibs resolve
  /// a bare soname; desktops may point `TRELLIS_WHISPER_LIB` at a build
  /// (`natives/out/linux/libwhisper.so`), falling back to the loader path.
  static String whisperLibraryPath() {
    if (_isAndroid) return 'libwhisper.so';
    final env = Platform.environment['TRELLIS_WHISPER_LIB'];
    if (env != null && env.isNotEmpty) return env;
    return 'libwhisper.so';
  }

  /// The neural voice for [voiceSpec], if it's actually usable right now —
  /// the localMlAvailable honesty gate, one layer deeper: even on a tier
  /// that CAN run local ML, a specific voice must be DOWNLOADED before
  /// speak mode may offer it. Returns null (never throws) when it isn't —
  /// the reader's own door falls back to the system voice and, on a tier
  /// that could have one, names what's missing (ADR-0006).
  ///
  /// The engine is constructed but NOT resident yet —
  /// [SupertonicSpeechEngine] opens its ONNX Runtime sessions lazily on
  /// first `synthesize()` — so this call is cheap even when nothing ends
  /// up being spoken.
  Future<SynthesisSpeechEngine?> speechEngineFor(ModelSpec voiceSpec) async {
    if (!localMlAvailable) return null;
    if (!tier.atLeast(voiceSpec.minTier)) return null;
    final layout = voiceSpec.supertonicLayout;
    if (layout == null) return null; // a mis-registered spec; refuse quietly
    if (!await modelStore.isDownloaded(voiceSpec)) return null;
    return SupertonicSpeechEngine(
      files: SupertonicVoiceFiles(
        durationPredictorPath: _pathForNamedFile(
          voiceSpec,
          layout.durationPredictorFileName,
        ),
        textEncoderPath: _pathForNamedFile(
          voiceSpec,
          layout.textEncoderFileName,
        ),
        vectorEstimatorPath: _pathForNamedFile(
          voiceSpec,
          layout.vectorEstimatorFileName,
        ),
        vocoderPath: _pathForNamedFile(voiceSpec, layout.vocoderFileName),
        unicodeIndexerPath: _pathForNamedFile(
          voiceSpec,
          layout.unicodeIndexerFileName,
        ),
        ttsConfigPath: _pathForNamedFile(voiceSpec, layout.ttsConfigFileName),
        voiceStylePath: _pathForNamedFile(voiceSpec, layout.voiceStyleFileName),
      ),
    );
  }

  /// Resolves [fileName]'s on-disk path within [spec]'s own model
  /// directory — every Supertonic file downloads and verifies on its
  /// own (no archive to extract), so [ModelStore.pathOf] already knows
  /// where it landed; this just finds WHICH registered [ModelFile] the
  /// layout's filename refers to.
  String _pathForNamedFile(ModelSpec spec, String fileName) {
    final file = spec.files.firstWhere(
      (f) => Uri.parse(f.url).pathSegments.last == fileName,
      orElse: () => throw StateError(
        'model "${spec.id}": no registered file named "$fileName"',
      ),
    );
    return modelStore.pathOf(spec, file);
  }

  /// Where per-sentence WAV temp files live during neural speech playback
  /// (ADR-0006) — swept clean at app start (`bootstrap_io.dart`'s
  /// `createServices`) and by `SpeechPlaybackPipeline` itself on stop/
  /// dispose. Meaningless on the web tier ([localMlAvailable] is always
  /// false there, so a `ReaderScreen` never resolves a synthesis engine to
  /// begin with), but safe to construct there too — the same "construct,
  /// never touch" rule as [supportDir] itself.
  Directory get speechTempDir => Directory('${supportDir.path}/speech-temp');

  /// Builds a FRESH [DiskSpeechTempFiles] for one speaking run — a factory,
  /// not a shared instance, since each run needs its own run id (the "two
  /// runs' files never collide" law). `ReaderScreen.createSpeechTempFiles`
  /// takes exactly this shape.
  SpeechTempFiles Function() get createSpeechTempFiles =>
      () => DiskSpeechTempFiles(dir: speechTempDir);

  /// The ONE call a `ReaderScreen` closes over (ADR-0006): the registry's
  /// selection law ([ModelRegistry.pickModel]) picks the best TTS voice for
  /// [lang] at this device's [tier], then [speechEngineFor] applies the
  /// download-honesty gate. Null either way means the system voice — this
  /// never throws.
  Future<SynthesisSpeechEngine?> resolveSpeechEngine({String? lang}) async {
    final spec = registry.pickModel(ModelTask.tts, tier, langHint: lang);
    if (spec == null) return null;
    return speechEngineFor(spec);
  }

  /// The Marian translator (ADR-0008 "Babel" Phase 3) for [modelSpec], if
  /// it's actually usable right now — [speechEngineFor]'s same
  /// download-honesty gate, one layer deeper: even on a tier that CAN run
  /// local ML, the model must be DOWNLOADED before the reader's "Translate
  /// to Spanish" action may offer itself. Returns null (never throws) when
  /// it isn't. Cheap: [MarianTranslator] opens its ONNX Runtime sessions
  /// lazily on first `translate()`, so this call never touches a file.
  Future<MarianTranslator?> translatorFor(ModelSpec modelSpec) async {
    if (!localMlAvailable) return null;
    if (!tier.atLeast(modelSpec.minTier)) return null;
    final layout = modelSpec.marianLayout;
    if (layout == null) return null; // a mis-registered spec; refuse quietly
    if (!await modelStore.isDownloaded(modelSpec)) return null;
    return MarianTranslator(
      files: MarianTranslatorFiles(
        encoderPath: _pathForNamedFile(modelSpec, layout.encoderFileName),
        decoderMergedPath:
            _pathForNamedFile(modelSpec, layout.decoderMergedFileName),
        sourceSpmPath: _pathForNamedFile(modelSpec, layout.sourceSpmFileName),
        vocabPath: _pathForNamedFile(modelSpec, layout.vocabFileName),
      ),
    );
  }

  /// The ONE call a `ReaderScreen` closes over for translation (mirrors
  /// [resolveSpeechEngine]): the registry's (source, target) selection law
  /// ([ModelRegistry.pickTranslationPair] — Campaign 8 "Babel widens",
  /// since [ModelRegistry.pickModel]'s single `langHint` cannot
  /// disambiguate `de-en`/`ru-en`/`zh-en`, which all produce `en`) picks
  /// the pair at this device's tier, then [translatorFor] applies the
  /// download-honesty gate. Null either way means the reader's translate
  /// action stays hidden — this never throws. [sourceLang] defaults to
  /// `'en'`, matching the spec's declared-source-language default for a
  /// work with none set.
  Future<MarianTranslator?> resolveTranslator({
    String sourceLang = 'en',
    String targetLang = 'es',
  }) async {
    final spec = registry.pickTranslationPair(tier,
        sourceLang: sourceLang, targetLang: targetLang);
    if (spec == null) return null;
    return translatorFor(spec);
  }

  /// Every target language this device can ACTUALLY translate [sourceLang]
  /// into right now — a downloaded pair, not merely a registered one
  /// (Campaign 8 "Babel widens" Phase 1: "list ONLY downloaded+openable
  /// pairs"). [sourceLang] itself is never included even if a pair
  /// somehow claims it (X->X is never offered). This is the "Translate…"
  /// picker's data source.
  Future<List<String>> availableTranslationTargets({
    required String sourceLang,
  }) async {
    final targets = <String>[];
    for (final spec in registry.translationPairsAt(tier)) {
      if (spec.sourceLang != sourceLang) continue;
      final langs = spec.langs;
      if (langs == null) continue;
      if (!await modelStore.isDownloaded(spec)) continue;
      for (final lang in langs) {
        if (lang == sourceLang) continue;
        if (!targets.contains(lang)) targets.add(lang);
      }
    }
    return targets;
  }

  /// Campaign 4 Phase 3's own version of [resolveSpeechEngine]: the ONE
  /// call `ReaderScreen` closes over for the definition sheet. Parses the
  /// on-disk dictionary at most once per [DeviceServices] instance
  /// (the residency law — [_dictionary] caches the built
  /// [StarDictDictionary], not just the file paths, since building it
  /// means reading the whole `.idx` and sorting it) and reuses it for
  /// every later lookup this session. Null covers every honest "nothing
  /// to show" case alike (no dictionary registered for this tier, none
  /// downloaded yet, or the word truly isn't in it) — the sheet shows one
  /// calm empty state regardless of which.
  StarDictDictionary? _dictionary;
  bool _dictionaryLoadAttempted = false;

  Future<String?> lookupDefinition(String word) async {
    final dict = await _openDictionary();
    if (dict == null) return null;
    final match = dict.lookup(word);
    if (match == null) return null;
    return _stripHtml(dict.definitionOf(match.entry));
  }

  Future<StarDictDictionary?> _openDictionary() async {
    if (_dictionary != null) return _dictionary;
    if (_dictionaryLoadAttempted) return null; // tried once, nothing there
    _dictionaryLoadAttempted = true;
    if (!localMlAvailable) return null;
    final spec = registry.pickModel(ModelTask.dictionary, tier);
    if (spec == null) return null;
    final layout = spec.dictionaryArchiveLayout;
    if (layout == null) return null;
    if (!await modelStore.isDownloaded(spec)) return null;
    final dir = modelStore.dictionaryDirOf(spec);
    try {
      final ifoRaw = await File('$dir/${layout.ifoFileName}').readAsString();
      final idxBytes = await File('$dir/${layout.idxFileName}').readAsBytes();
      final dictBytes =
          await File('$dir/${layout.dictFileName}').readAsBytes();
      StarDictIfo.parse(ifoRaw); // validated, but only entries/body matter
      final entries = parseIdx32(idxBytes);
      _dictionary =
          StarDictDictionary(entries: entries, body: DictzipBody(dictBytes));
      return _dictionary;
    } on FormatException {
      return null; // a corrupt/partial dictionary reads as "none available"
    } on FileSystemException {
      return null;
    }
  }

  static final _tagRe = RegExp('<[^>]*>');
  static final _wsRe = RegExp(r'[ \t]+');
  static final _blankLinesRe = RegExp(r'\n{3,}');

  /// A calm, plain-text rendering of a `sametypesequence=h` (HTML) entry
  /// body — good enough for a dismissible sheet without pulling in a full
  /// HTML renderer this pass: block-level tags become line breaks, then
  /// every remaining tag is dropped and a small set of entities decoded.
  static String _stripHtml(String html) {
    var s = html
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</(p|li|div|h[1-6])>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '• ');
    s = s.replaceAll(_tagRe, '');
    s = s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ');
    s = s.replaceAll(_wsRe, ' ');
    s = s.replaceAll(_blankLinesRe, '\n\n');
    return s.trim();
  }

  File audioFileFor(int workId, String url) {
    final path = Uri.parse(url).path;
    final dot = path.lastIndexOf('.');
    final ext = dot < 0 || path.length - dot > 6 ? '' : path.substring(dot);
    return File('${supportDir.path}/audio/$workId$ext');
  }

  File pcmFileFor(int workId) => File('${supportDir.path}/pcm/$workId.f32');

  /// Where a feed's downloaded channel artwork lives (Campaign 9 Phase 5,
  /// "the river gets faces") — deterministic on the feed id alone, so
  /// nothing needs to persist a local path: the river checks this exact
  /// file's existence and never fetches at render (see
  /// `FeedsRepository`'s fetch-once law).
  File artworkFileFor(int feedId) =>
      File('${supportDir.path}/artwork/$feedId.img');

  /// Campaign 7 (ADR-0013): where an audiobook's own copied files live —
  /// one directory per book, so removing a book is deleting one directory
  /// rather than hunting down N files by row.
  Directory audiobookDirFor(int workId) =>
      Directory('${supportDir.path}/audiobooks/$workId');

  /// The copied destination for file [fileIdx] of audiobook [workId],
  /// preserving [sourceName]'s own extension (chapter parsing and
  /// playback both key off the extension, e.g. distinguishing an m4b's
  /// chpl atom from an mp3 with no chapters of its own).
  File audiobookFileFor(int workId, int fileIdx, String sourceName) {
    final dot = sourceName.lastIndexOf('.');
    final ext =
        dot < 0 || sourceName.length - dot > 6 ? '' : sourceName.substring(dot);
    return File('${audiobookDirFor(workId).path}/$fileIdx$ext');
  }
}
