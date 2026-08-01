import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:loom_core/loom_core.dart' as core;
import 'package:openhearth_design/openhearth_design.dart';

import '../../db/database.dart';
import '../../services/device_services.dart';
import '../brain/brain_store.dart';
import '../brain/distill_screen.dart';
import 'ledger_screen.dart';
import 'reader_logic.dart';
import 'speech/just_audio_speech_queue.dart';
import 'speech/speech_audio_queue.dart';
import 'speech/speech_engine.dart';
import 'speech/speech_playback_pipeline.dart';
import 'speech/speech_temp_files.dart';

/// The hearth red — the heritage ORP pivot color carried from both donors,
/// which is the fleet's own hearth500 (C1: from the tokens, not retyped).
const Color kPivotColor = OhColors.hearth500;

enum ReaderMode { rsvp, scroll }

/// The alpha reader: RSVP (donor pacing + ORP pivot) and Scroll (flowing
/// text, tap a word to move the cursor). Both modes project ONE cursor — a
/// global word index whose persisted form is (segmentIdx, wordIdx) and
/// nothing else (the cursor law, ADR-0002). Saved on pause, on back, on
/// app-background; restored on open.
class ReaderScreen extends StatefulWidget {
  final AppDatabase db;
  final int profileId;
  final Work work;

  /// The speak-mode voice. Tests inject a fake; null means the platform
  /// speaker, created only if speak mode is actually used — so the call
  /// sites that predate the seam keep a working voice and widget tests that
  /// never speak never touch the TTS channel.
  final TtsSpeaker? tts;

  /// The distill flow's Brain settings (overflow menu). Tests inject
  /// in-memory secrets + a FakeBrain; null means the production store,
  /// built only if the menu item is actually used.
  final BrainStore? brain;

  /// Speak-mode door honesty (ADR-0006): true only when this tier CAN run
  /// local ML and no neural voice is downloaded yet — resolved by the
  /// caller from `DeviceServices.speechEngineFor` so this widget's own
  /// test surface stays a plain bool, never a device-services mock. When
  /// true, starting speech shows ONE quiet line naming Models, once per
  /// screen session — never a repeated nag (ADR-0003 law 5).
  final bool offerNeuralVoice;

  /// Resolves the neural voice for this work's language, if one is
  /// on-device and usable (ADR-0006) — the caller closes over
  /// `DeviceServices.speechEngineFor` so ReaderScreen's own tests never
  /// reach it; null keeps every existing call site on the system voice,
  /// unchanged. Called once, in [_load], and cached for this screen's
  /// session (the residency law: lazy create, dispose on teardown, no
  /// re-resolve churn on every toggle).
  final Future<SynthesisSpeechEngine?> Function({String? lang})?
      resolveSpeechEngine;

  /// Builds the gapless audio queue behind [SpeechPlaybackPipeline]
  /// (just_audio, kept off this seam so tests inject a fake); null
  /// defaults to [JustAudioSpeechQueue.new]. A factory, not an instance,
  /// so the underlying player is only ever constructed if speech actually
  /// needs it.
  final SpeechAudioQueue Function()? createSpeechAudioQueue;

  /// Builds this screen's one [SpeechTempFiles] writer; null falls back to
  /// a plain system-temp directory (production always supplies the real
  /// one, rooted at `DeviceServices.speechTempDir` — the location app
  /// start sweeps clean).
  final SpeechTempFiles Function()? createSpeechTempFiles;

  const ReaderScreen(
      {super.key,
      required this.db,
      required this.profileId,
      required this.work,
      this.tts,
      this.brain,
      this.offerNeuralVoice = false,
      this.resolveSpeechEngine,
      this.createSpeechAudioQueue,
      this.createSpeechTempFiles});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with WidgetsBindingObserver {
  List<core.Segment>? _blocks;
  core.TokenizedDocument? _doc;
  int _wordIdx = 0;
  ReaderMode _mode = ReaderMode.rsvp;
  int _scrollAnchor = 0; // segment the scroll view opens around
  bool _playing = false;
  double _wpm = 300;
  Timer? _timer;

  /// Speak mode: [_speaking] is the run flag, [_speakGen] fences stale
  /// loops (each start/stop bumps it, so an utterance completing after a
  /// stop cannot advance the cursor). The speaker is created on first use
  /// only — see [ReaderScreen.tts].
  bool _speaking = false;
  int _speakGen = 0;
  TtsSpeaker? _ttsHolder;
  TtsSpeaker get _tts => _ttsHolder ??= widget.tts ?? FlutterTtsSpeaker();

  /// Whether the neural-voice hint has already shown this screen session
  /// (ADR-0006) — a quiet ONE-TIME line, not a nag.
  bool _offeredNeuralVoice = false;

  /// The resolved neural engine, primed once in [_load] and cached for the
  /// rest of this screen's session (the residency law). Null means either
  /// no [ReaderScreen.resolveSpeechEngine] was supplied, or it resolved to
  /// nothing — the system voice either way.
  SynthesisSpeechEngine? _synthEngineHolder;

  /// The settings escape (ADR-0006): loaded from the profile row in
  /// [_load]; true pins this profile to the system voice on purpose even
  /// when a neural voice is on-device.
  bool _preferSystemVoice = false;

  SpeechAudioQueue? _queueHolder;
  SpeechAudioQueue get _queue =>
      _queueHolder ??= (widget.createSpeechAudioQueue ?? JustAudioSpeechQueue.new)();

  SpeechPlaybackPipeline? _pipelineHolder;

  /// The current synthesis run's flat unit list and the `_speakGen` it
  /// belongs to — [SpeechPlaybackPipeline]'s callbacks are bound ONCE (the
  /// pipeline itself is reused across runs), so they read these MUTABLE
  /// fields rather than closing over a single run's locals; the `_synthGen`
  /// check is `_speakGen`'s own fencing law, carried one level lower
  /// (mirrors the utterance path's `gen == _speakGen` check in `live()`,
  /// on top of — not instead of — the pipeline's own internal fencing).
  List<({int seg, int wordIdx, String text})> _synthUnits = const [];
  int _synthGen = 0;

  /// The language toggle (ADR-0002: layers project onto the SAME cursor).
  /// [_original] holds the canonical segments; [_mtLangs] the mt layers on
  /// offer; [_activeLang] which one currently projects (null = original).
  List<core.Segment> _original = const [];
  List<String> _mtLangs = const [];
  Map<String, Map<int, String>> _mtTexts = const {};
  String? _activeLang;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    // Silence the voice without creating one: only an already-used speaker
    // needs stopping (fake-async law 1: fire-and-forget, never await here).
    _speakGen++;
    _speaking = false;
    final tts = _ttsHolder;
    if (tts != null) unawaited(tts.stop().catchError((_) {}));
    // The synthesis-path trio, torn down in the same fire-and-forget spirit
    // — never awaited here, but every native/platform handle this screen
    // ever opened gets a dispose() call on its way out.
    final pipeline = _pipelineHolder;
    if (pipeline != null) unawaited(pipeline.dispose().catchError((_) {}));
    final queue = _queueHolder;
    if (queue != null) unawaited(queue.dispose().catchError((_) {}));
    final synthEngine = _synthEngineHolder;
    if (synthEngine != null) unawaited(synthEngine.dispose().catchError((_) {}));
    // Backstop save; the deterministic paths are pause/back/background. The
    // app may already be tearing this db down (tests do), hence best-effort.
    unawaited(_savePosition().catchError((_) {}));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _pause();
      unawaited(_stopSpeak());
      unawaited(_savePosition().catchError((_) {}));
    }
  }

  Future<void> _load() async {
    final rows = await widget.db.spineDao.segmentsOf(widget.work.id);
    final kinds = core.SegmentKind.values.asNameMap();
    final blocks = [
      for (final r in rows)
        core.Segment(
            idx: r.idx,
            kind: kinds[r.kind] ?? core.SegmentKind.prose,
            text: r.body)
    ];
    // Translation layers on offer, if any (ADR-0002).
    final mtLangs =
        await widget.db.spineDao.layerLangsOf(widget.work.id, kind: 'mt');
    final mtTexts = <String, Map<int, String>>{
      for (final lang in mtLangs)
        lang: {
          for (final l
              in await widget.db.spineDao.layersOf(widget.work.id, lang: lang))
            if (l.kind == 'mt') l.segmentIdx: l.body
        }
    };
    final doc = core.tokenizeDocument(blocks);
    final saved = await widget.db.spineDao
        .position(profileId: widget.profileId, workId: widget.work.id);
    var wordIdx = 0;
    if (saved != null && doc.words.isNotEmpty) {
      var blockPos = blocks.indexWhere((b) => b.idx == saved.segmentIdx);
      if (blockPos < 0) blockPos = 0;
      wordIdx = globalWordIndex(doc, blockPos, saved.wordIdx);
    }
    // The settings escape's stored value, and the neural voice itself
    // (ADR-0006) — resolved once, here, rather than at every speak-start:
    // the menu control that lets a listener escape TO the system voice
    // must already know whether there's a neural voice to escape FROM
    // before the user ever presses speak-toggle. Resolution is cheap
    // (SupertonicSpeechEngine opens its ONNX Runtime sessions lazily on
    // first use, ADR-0007).
    final preferSystemVoice =
        await widget.db.profilesDao.preferSystemVoice(widget.profileId);
    final resolver = widget.resolveSpeechEngine;
    final synthEngine =
        resolver == null ? null : await resolver(lang: widget.work.lang);
    if (!mounted) return;
    setState(() {
      _original = blocks;
      _mtLangs = mtLangs;
      _mtTexts = mtTexts;
      _activeLang = null;
      _blocks = blocks;
      _doc = doc;
      _wordIdx = wordIdx;
      _scrollAnchor = doc.words.isEmpty ? 0 : cursorAt(doc, wordIdx).segment;
      _preferSystemVoice = preferSystemVoice;
      _synthEngineHolder = synthEngine;
    });
  }

  /// Projects [_original] through the [lang] mt layer — same segment, other
  /// language; segments without a layer keep their canonical text (partial
  /// translation is natural, ADR-0002).
  List<core.Segment> _projectedBlocks(String? lang) {
    if (lang == null) return _original;
    final texts = _mtTexts[lang] ?? const {};
    return [
      for (final b in _original)
        core.Segment(idx: b.idx, kind: b.kind, text: texts[b.idx] ?? b.text)
    ];
  }

  /// The cursor law under a language switch: the persisted Position knows
  /// no language, so the toggle re-projects the SAME segment and the word
  /// cursor re-enters it at its start.
  void _toggleLanguage() {
    final doc = _doc;
    if (doc == null || _mtLangs.isEmpty) return;
    _pause();
    // The projection under the voice is about to change; a running speak
    // loop holds the old blocks, so it must not advance past the switch.
    unawaited(_stopSpeak());
    final currentSegment =
        doc.words.isEmpty ? 0 : cursorAt(doc, _wordIdx).segment;
    final order = <String?>[null, ..._mtLangs];
    final next = order[(order.indexOf(_activeLang) + 1) % order.length];
    final blocks = _projectedBlocks(next);
    final newDoc = core.tokenizeDocument(blocks);
    setState(() {
      _activeLang = next;
      _blocks = blocks;
      _doc = newDoc;
      _wordIdx = newDoc.words.isEmpty
          ? 0
          : globalWordIndex(newDoc, currentSegment, 0);
      _scrollAnchor = currentSegment;
    });
  }

  Future<void> _savePosition({String modality = 'read'}) async {
    final doc = _doc;
    final blocks = _blocks;
    if (doc == null || blocks == null || doc.words.isEmpty) return;
    final c = cursorAt(doc, _wordIdx);
    await widget.db.spineDao.savePosition(
        profileId: widget.profileId,
        workId: widget.work.id,
        segmentIdx: blocks[c.segment].idx,
        wordIdx: c.word,
        lastModality: modality);
  }

  // ───── speak mode (the TtsSpeaker seam; cursor law ADR-0002) ─────

  void _toggleSpeak() {
    if (_speaking) {
      unawaited(_stopSpeak());
    } else {
      _startSpeak();
    }
  }

  /// Reads the CURRENT segment aloud and advances segment-by-segment. The
  /// ticker and speech are both cursor-advancers, so starting one pauses
  /// the other — one hand on the cursor at a time.
  void _startSpeak() {
    final doc = _doc;
    if (doc == null || doc.words.isEmpty) return;
    _pause();
    setState(() => _speaking = true);
    if (widget.offerNeuralVoice && !_offeredNeuralVoice) {
      _offeredNeuralVoice = true;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
            content: Text('A downloaded voice reads more smoothly — get '
                'one in Models.')));
    }
    unawaited(_speakLoop());
  }

  Future<void> _stopSpeak() async {
    if (!_speaking) return;
    _speakGen++;
    setState(() => _speaking = false);
    await _tts.stop();
    // Only touch the pipeline if speech ever actually created one — never
    // spin up the queue's platform player just to stop it.
    final pipeline = _pipelineHolder;
    if (pipeline != null) await pipeline.stop();
    unawaited(_savePosition(modality: 'speak').catchError((_) {}));
  }

  /// Which engine THIS run speaks through (ADR-0006): the neural voice
  /// primed in [_load], unless the settings escape has pinned this profile
  /// to the system voice — the system voice either way when nothing
  /// resolved. A profile with no neural voice ever downloaded is
  /// unaffected by [_preferSystemVoice]'s value: there is nothing to
  /// prefer away from.
  SpeechEngine _resolveEngine() {
    final synth = _synthEngineHolder;
    if (!_preferSystemVoice && synth != null) return synth;
    return UtteranceSpeechEngine(_tts);
  }

  /// One speaking run, forked over which kind of voice this run has (the
  /// two [SpeechEngine] shapes): an utterance engine keeps the reader's
  /// original per-sentence awaited loop; a synthesis engine hands the rest
  /// of the document's sentences to [SpeechPlaybackPipeline], which
  /// synthesizes and plays them gaplessly, ahead of playback — the reader
  /// only reacts to its callbacks. Both paths advance the SAME cursor under
  /// the SAME law (ADR-0002): stopping anywhere leaves Position at that
  /// sentence's start.
  Future<void> _speakLoop() async {
    final gen = ++_speakGen;
    final doc = _doc!;
    final blocks = _blocks!;
    bool live() => mounted && _speaking && gen == _speakGen;
    final seg = cursorAt(doc, _wordIdx).segment;

    switch (_resolveEngine()) {
      case UtteranceSpeechEngine u:
        await _speakWithUtterance(u, doc, blocks, seg, live);
      case SynthesisSpeechEngine s:
        await _speakWithSynthesis(s, blocks, seg, gen, live);
    }
  }

  /// The system voice's path — unchanged from before this pass: whatever
  /// layer the reader is showing ([_blocks] IS the projection), starting at
  /// the cursor's segment; each advance moves the cursor to the next
  /// SENTENCE's first word and saves the Position row BEFORE speaking on.
  /// Sentinel segments (code/table/figure) have no sensible reading — the
  /// voice passes over them the way an eye does, in one silent beat. A
  /// heading IS spoken (it's prose-shaped, just styled differently).
  Future<void> _speakWithUtterance(UtteranceSpeechEngine engine,
      core.TokenizedDocument doc, List<core.Segment> blocks, int startSeg,
      bool Function() live) async {
    var seg = startSeg;
    var first = true;
    while (live() && seg < blocks.length) {
      final block = blocks[seg];
      final speakable = block.kind == core.SegmentKind.prose ||
          block.kind == core.SegmentKind.heading;
      final sentences = speakable && block.text.trim().isNotEmpty
          ? core.splitSentences(block.text)
          : const <core.Sentence>[];
      // A block with no sentence boundaries (a sentinel, or nothing
      // speakable in it) is still one stop for the cursor — the
      // whole-block unit the reader always understood, now expressed as a
      // single-sentence list so the loop below stays uniform.
      final units = sentences.isEmpty
          ? [core.Sentence(text: block.text, firstWordIdx: 0)]
          : sentences;
      for (final sentence in units) {
        if (!live()) return;
        if (!first) {
          setState(() => _wordIdx =
              globalWordIndex(doc, seg, sentence.firstWordIdx));
          await _savePosition(modality: 'speak');
          if (!live()) return;
        }
        first = false;
        if (speakable && sentence.text.trim().isNotEmpty) {
          await engine.speak(sentence.text,
              lang: _activeLang ?? widget.work.lang);
          if (!live()) return;
        }
      }
      seg++;
    }
    _finishSpeaking(live);
  }

  /// The remaining speakable units from [fromSeg] to the end of the
  /// document — the flat list [SpeechPlaybackPipeline] needs up front to
  /// synthesize ahead of playback (unlike the utterance path, which only
  /// ever needs ONE sentence at a time). Sentinel segments (code/table/
  /// figure) carry nothing to synthesize and are skipped outright here —
  /// the utterance path's silent "blip" through them has no analogue in a
  /// flat gapless list, so the neural voice simply passes over them
  /// without a cursor stop. A deliberate, tested behavior difference
  /// between the two engines (`reader_speak_synthesis_test.dart`), not a
  /// bug: synthesizing "[code]" aloud would be worse than skipping it.
  List<({int seg, int wordIdx, String text})> _remainingSpeechUnits(
      List<core.Segment> blocks, int fromSeg) {
    final units = <({int seg, int wordIdx, String text})>[];
    for (var seg = fromSeg; seg < blocks.length; seg++) {
      final block = blocks[seg];
      final speakable = block.kind == core.SegmentKind.prose ||
          block.kind == core.SegmentKind.heading;
      if (!speakable || block.text.trim().isEmpty) continue;
      for (final sentence in core.splitSentences(block.text)) {
        if (sentence.text.trim().isEmpty) continue;
        units.add(
            (seg: seg, wordIdx: sentence.firstWordIdx, text: sentence.text));
      }
    }
    return units;
  }

  /// The neural voice's path: hands every remaining sentence to a
  /// long-lived [SpeechPlaybackPipeline] (reused across runs — its own
  /// generation counter, bumped on every `start()`, is what makes reuse
  /// safe) and returns immediately — like the utterance path, this run is
  /// fire-and-forget from the caller's perspective; [_onSynthSentenceStart]
  /// and [_onSynthDone] carry it the rest of the way via the pipeline's
  /// callbacks.
  Future<void> _speakWithSynthesis(SynthesisSpeechEngine engine,
      List<core.Segment> blocks, int fromSeg, int gen,
      bool Function() live) async {
    final units = _remainingSpeechUnits(blocks, fromSeg);
    if (units.isEmpty) {
      _finishSpeaking(live);
      return;
    }
    _synthUnits = units;
    _synthGen = gen;

    final pipeline = _pipelineHolder ??= SpeechPlaybackPipeline(
      engine: engine,
      queue: _queue,
      tempFiles:
          (widget.createSpeechTempFiles ?? _fallbackSpeechTempFiles)(),
      onSentenceStart: _onSynthSentenceStart,
      onDone: _onSynthDone,
    );
    await pipeline.start([for (final u in units) u.text],
        lang: _activeLang ?? widget.work.lang);
  }

  /// The synthesis path's cursor advance: index 0 is the sentence the
  /// cursor already sat on when this run started (mirrors the utterance
  /// path's `first` flag — no move, no save), every later index moves and
  /// saves BEFORE the next sentence is heard, the same cursor law either
  /// engine obeys.
  void _onSynthSentenceStart(int index) {
    if (!mounted || !_speaking || _synthGen != _speakGen) return;
    if (index == 0 || index >= _synthUnits.length) return;
    final doc = _doc;
    if (doc == null) return;
    final unit = _synthUnits[index];
    setState(
        () => _wordIdx = globalWordIndex(doc, unit.seg, unit.wordIdx));
    unawaited(_savePosition(modality: 'speak').catchError((_) {}));
  }

  /// The synthesis path's natural end — fired only once every sentence has
  /// genuinely finished playing (the pipeline's own `onDone` contract) —
  /// restores the non-speaking state through the exact same call the
  /// utterance path uses.
  void _onSynthDone() {
    if (!mounted || !_speaking || _synthGen != _speakGen) return;
    _finishSpeaking(() => mounted && _speaking && _synthGen == _speakGen);
  }

  void _finishSpeaking(bool Function() live) {
    if (live()) {
      setState(() => _speaking = false);
      unawaited(_savePosition(modality: 'speak').catchError((_) {}));
    }
  }

  static SpeechTempFiles _fallbackSpeechTempFiles() => DiskSpeechTempFiles(
      dir: Directory('${Directory.systemTemp.path}/trellis-speech-temp'));

  /// The settings escape (ADR-0006): flips the persisted preference and
  /// takes effect on the NEXT speak run — a run already under way keeps
  /// speaking with whatever engine it started with (no engine hot-swap
  /// mid-sentence).
  Future<void> _toggleVoicePreference() async {
    final next = !_preferSystemVoice;
    setState(() => _preferSystemVoice = next);
    await widget.db.profilesDao.setPreferSystemVoice(widget.profileId, next);
  }

  // ───── playback (donor step: 60000/wpm × pacing, then advance) ─────

  void _step() {
    _timer?.cancel();
    final doc = _doc;
    if (!_playing || doc == null || doc.words.isEmpty) return;
    final pacing =
        _wordIdx < doc.pacing.length ? doc.pacing[_wordIdx] : 1.0;
    _timer = Timer(Duration(milliseconds: msPerWord(_wpm, pacing)), () {
      if (!_playing || !mounted) return;
      if (_wordIdx >= doc.words.length - 1) {
        setState(() => _playing = false);
        unawaited(_savePosition().catchError((_) {}));
        return;
      }
      setState(() => _wordIdx++);
      _step();
    });
  }

  void _play() {
    final doc = _doc;
    if (doc == null || doc.words.isEmpty) return;
    unawaited(_stopSpeak()); // one cursor-advancer at a time
    setState(() {
      if (_wordIdx >= doc.words.length - 1) _wordIdx = 0; // donor toggle
      _playing = true;
    });
    _step();
  }

  void _pause() {
    _timer?.cancel();
    if (!_playing) return;
    setState(() => _playing = false);
    unawaited(_savePosition().catchError((_) {}));
  }

  void _seekBy(int delta) {
    final doc = _doc;
    if (doc == null || doc.words.isEmpty) return;
    _timer?.cancel();
    unawaited(_stopSpeak()); // a manual seek takes the cursor back by hand
    setState(() =>
        _wordIdx = (_wordIdx + delta).clamp(0, doc.words.length - 1));
    if (_playing) _step();
  }

  void _seekToWord(int globalIdx) {
    final doc = _doc;
    if (doc == null || doc.words.isEmpty) return;
    _timer?.cancel();
    unawaited(_stopSpeak());
    setState(() => _wordIdx = globalIdx.clamp(0, doc.words.length - 1));
    if (_playing) _step();
  }

  void _toggleMode() {
    _pause();
    setState(() {
      // The cursor itself is untouched — that is the law under test.
      _mode = _mode == ReaderMode.rsvp ? ReaderMode.scroll : ReaderMode.rsvp;
      final doc = _doc;
      if (_mode == ReaderMode.scroll && doc != null && doc.words.isNotEmpty) {
        _scrollAnchor = cursorAt(doc, _wordIdx).segment;
      }
    });
  }

  Future<void> _back() async {
    _pause();
    await _savePosition();
    if (mounted) Navigator.of(context).pop();
  }

  // ───── the word ledger (ADR-0003 law 2: the user's hand collects) ─────

  /// Keeps a long-pressed display token in the ledger — the ONE dao path,
  /// so dedupe stays in the schema — and names the catch in a calm
  /// snackbar. Tokens with nothing wordy in them add nothing.
  Future<void> _keepWord(String token) async {
    final word = ledgerWord(token);
    if (word == null) return;
    await widget.db.ledgerDao.add(
        profileId: widget.profileId,
        word: word,
        lang: _activeLang ?? widget.work.lang,
        sourceWorkId: widget.work.id,
        nowMs: DateTime.now().millisecondsSinceEpoch);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
          SnackBar(content: Text('“$word” is in your word ledger.')));
  }

  void _openLedger() {
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) =>
            LedgerScreen(db: widget.db, profileId: widget.profileId)));
  }

  // ───── the overflow menu (distill, proposal-2 §7) ─────

  /// The menu tap is the user gesture the distill flow rides on; both
  /// cursor-advancers stop first — leaving for the distill surface is
  /// leaving the page.
  Future<void> _distill() async {
    _pause();
    unawaited(_stopSpeak());
    await openDistillFlow(context,
        db: widget.db,
        profileId: widget.profileId,
        work: widget.work,
        store: widget.brain ?? BrainStore.production());
  }

  // ───── build ─────

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: _back),
        title: Text(widget.work.title,
            overflow: TextOverflow.ellipsis, maxLines: 1),
        actions: [
          if (_mtLangs.isNotEmpty)
            IconButton(
              key: const Key('lang-toggle'),
              tooltip: _activeLang == null
                  ? 'Show translation'
                  : 'Showing $_activeLang — tap to switch',
              isSelected: _activeLang != null,
              icon: const Icon(Icons.translate),
              onPressed: doc == null ? null : _toggleLanguage,
            ),
          IconButton(
            key: const Key('speak-toggle'),
            tooltip: _speaking ? 'Stop reading aloud' : 'Read aloud',
            isSelected: _speaking,
            icon: Icon(_speaking ? Icons.stop_circle_outlined
                : Icons.volume_up_outlined),
            onPressed: doc == null ? null : _toggleSpeak,
          ),
          IconButton(
            key: const Key('mode-toggle'),
            tooltip: _mode == ReaderMode.rsvp ? 'Scroll mode' : 'RSVP mode',
            icon: Icon(_mode == ReaderMode.rsvp
                ? Icons.notes
                : Icons.center_focus_strong),
            onPressed: doc == null ? null : _toggleMode,
          ),
          IconButton(
            key: const Key('open-ledger'),
            tooltip: 'Word ledger',
            icon: const Icon(Icons.bookmark_border),
            onPressed: _openLedger,
          ),
          PopupMenuButton<String>(
            key: const Key('reader-overflow'),
            tooltip: 'More',
            onSelected: (value) {
              if (value == 'distill') unawaited(_distill());
              if (value == 'system-voice') unawaited(_toggleVoicePreference());
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                  value: 'distill',
                  child: Text('Distill into a course')),
              // The settings escape (ADR-0006): only visible when there is
              // a neural voice to escape FROM — no dead settings.
              if (_synthEngineHolder != null)
                CheckedPopupMenuItem<String>(
                  key: const Key('voice-preference-toggle'),
                  value: 'system-voice',
                  checked: _preferSystemVoice,
                  child: const Text('Use the system voice'),
                ),
            ],
          ),
        ],
      ),
      body: switch (doc) {
        null => const Center(child: CircularProgressIndicator()),
        core.TokenizedDocument(words: []) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Nothing to read in this one yet.',
                  style: Theme.of(context).textTheme.bodyLarge,
                  textAlign: TextAlign.center),
            ),
          ),
        _ => _mode == ReaderMode.rsvp ? _rsvpBody(doc) : _scrollBody(doc),
      },
    );
  }

  // ───── RSVP ─────

  Widget _rsvpBody(core.TokenizedDocument doc) {
    return SafeArea(
      child: Column(
        children: [
          Expanded(
            child: GestureDetector(
              key: const Key('reader-tapzone'),
              behavior: HitTestBehavior.opaque,
              // Holding the shown word keeps it (sentinels stand for whole
              // segments — nothing wordy to collect there).
              onLongPress: doc.segments.containsKey(_wordIdx)
                  ? null
                  : () => _keepWord(doc.words[_wordIdx]),
              onTapUp: (details) {
                final width = context.size?.width ?? 1;
                final dx = details.localPosition.dx;
                if (dx < width / 3) {
                  _seekBy(-1);
                } else if (dx > width * 2 / 3) {
                  _seekBy(1);
                } else {
                  _playing ? _pause() : _play();
                }
              },
              child: Center(child: _rsvpWord(doc)),
            ),
          ),
          _rsvpControls(doc),
        ],
      ),
    );
  }

  Widget _rsvpWord(core.TokenizedDocument doc) {
    final word = doc.words[_wordIdx];
    final style = Theme.of(context)
        .textTheme
        .displaySmall
        ?.copyWith(fontWeight: FontWeight.w600);
    if (doc.segments.containsKey(_wordIdx)) {
      // A sentinel ([code]/[table]/[figure]) stands in for its segment.
      return Text(word,
          key: const Key('rsvp-sentinel'),
          style: style?.copyWith(
              fontStyle: FontStyle.italic,
              color: Theme.of(context).colorScheme.secondary));
    }
    final orp = orpIndex(word);
    final pivot = orp < word.length ? word[orp] : '';
    // A roomy stage (proposal-2 §12): the word floats in generous
    // whitespace. The face is the theme's display Lora; the pivot keeps the
    // heritage hearth red (kPivotColor) — both pinned by reader_print_test.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(word.substring(0, orp),
                key: const Key('rsvp-bef'), style: style),
            Text(pivot,
                key: const Key('rsvp-piv'),
                style: style?.copyWith(color: kPivotColor)),
            Text(orp < word.length ? word.substring(orp + 1) : '',
                key: const Key('rsvp-aft'), style: style),
          ],
        ),
      ),
    );
  }

  Widget _rsvpControls(core.TokenizedDocument doc) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Slider(
            key: const Key('wpm-slider'),
            min: 100,
            max: 1500,
            divisions: 28,
            value: _wpm,
            label: '${_wpm.round()} wpm',
            onChanged: (v) => setState(() => _wpm = v),
          ),
          Text('${_wpm.round()} wpm',
              style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          IconButton.filled(
            key: const Key('play-toggle'),
            iconSize: 36,
            tooltip: _playing ? 'Pause' : 'Play',
            onPressed: _playing ? _pause : _play,
            icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
          ),
        ],
      ),
    );
  }

  // ───── Scroll ─────

  Widget _scrollBody(core.TokenizedDocument doc) {
    const centerKey = ValueKey('scroll-center');
    final blocks = _blocks!;
    final anchor = _scrollAnchor.clamp(0, blocks.length - 1);
    // The print measure (proposal-2 §12): on wide screens the page sets as
    // a centered ~680dp column rather than sprawling wall to wall.
    return Center(
      child: ConstrainedBox(
        key: const Key('print-column'),
        constraints: const BoxConstraints(maxWidth: 680),
        child: CustomScrollView(
          center: centerKey,
          anchor: 0.15,
          slivers: [
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (_, i) => _segmentTile(doc, anchor - 1 - i),
                childCount: anchor,
              ),
            ),
            SliverList(
              key: centerKey,
              delegate: SliverChildBuilderDelegate(
                (_, i) => _segmentTile(doc, anchor + i),
                childCount: blocks.length - anchor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _segmentTile(core.TokenizedDocument doc, int blockPos) {
    final blocks = _blocks!;
    final block = blocks[blockPos];
    final cursor = cursorAt(doc, _wordIdx);
    final isCurrent = cursor.segment == blockPos;
    final theme = Theme.of(context);

    final Widget child;
    switch (block.kind) {
      case core.SegmentKind.heading:
        child = Text(block.text,
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w700));
      case core.SegmentKind.prose:
        child = _proseWrap(doc, blockPos);
      case core.SegmentKind.code:
      case core.SegmentKind.table:
      case core.SegmentKind.figure:
        final sentinelIdx = doc.blockStartWordIdx[blockPos];
        child = GestureDetector(
          onTap: () => _seekToWord(sentinelIdx),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8)),
            child: Text(block.text,
                style: block.kind == core.SegmentKind.figure
                    ? theme.textTheme.bodyMedium
                        ?.copyWith(fontStyle: FontStyle.italic)
                    : theme.textTheme.bodyMedium
                        ?.copyWith(fontFamily: 'monospace')),
          ),
        );
    }

    return Container(
      // Generous print margins (proposal-2 §12).
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      color: isCurrent ? theme.colorScheme.surfaceContainerHighest : null,
      child: child,
    );
  }

  Widget _proseWrap(core.TokenizedDocument doc, int blockPos) {
    final start = doc.blockStartWordIdx[blockPos];
    final end = blockPos + 1 < doc.blockStartWordIdx.length
        ? doc.blockStartWordIdx[blockPos + 1]
        : doc.words.length;
    final theme = Theme.of(context);
    // The print body (proposal-2 §12): Lora at a book line height.
    final base =
        theme.textTheme.bodyLarge?.copyWith(fontFamily: 'Lora', height: 1.6);
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      // The drop-cap word stands taller than its run; bottom-aligning keeps
      // the rest of the line sitting on (near) its baseline.
      crossAxisAlignment: WrapCrossAlignment.end,
      children: [
        for (var w = start; w < end; w++)
          GestureDetector(
            onTap: () => _seekToWord(w),
            onLongPress: () => _keepWord(doc.words[w]),
            child: _flowWord(doc, w, base, theme),
          ),
      ],
    );
  }

  /// One word of flowing text. The work's opening word (global index 0 — a
  /// heading emits no words, so this is the first prose word) carries the
  /// drop cap; the cursor word carries the highlight; both behaviors stack
  /// because the drop cap sits inside the same gesture detector and
  /// highlight box as any other word.
  Widget _flowWord(core.TokenizedDocument doc, int w, TextStyle? base,
      ThemeData theme) {
    final current = w == _wordIdx;
    final style = current ? base?.copyWith(fontWeight: FontWeight.w700) : base;
    final Widget child = w == 0
        ? DropCap(word: doc.words[w], bodyStyle: style)
        : Text(doc.words[w],
            key: current ? const Key('cursor-word') : null, style: style);
    if (!current) return child;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
          color: theme.colorScheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(4)),
      child: child,
    );
  }
}

/// The print signature (proposal-2 §12): the work's opening word sets its
/// first letter as a drop cap — outsized in Lora against the body face —
/// while staying ONE word to the reader's hand: the whole widget lives
/// inside the same tap/long-press detector as any other flowing word, so
/// seeking and the word ledger keep working on it.
class DropCap extends StatelessWidget {
  final String word;
  final TextStyle? bodyStyle;
  const DropCap({super.key, required this.word, this.bodyStyle});

  @override
  Widget build(BuildContext context) {
    final chars = word.characters;
    final cap = chars.take(1).toString();
    final rest = chars.skip(1).toString();
    final capStyle = Theme.of(context).textTheme.displayMedium?.copyWith(
        fontFamily: 'Lora', fontWeight: FontWeight.w600, height: 1.0);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(cap, key: const Key('drop-cap'), style: capStyle),
        // Flexible, not bare: a long opening word at large text scale must
        // soft-overflow like any other flowing word — a rigid Row here is
        // the fleet's recurring 320dp accessibility wound (RenderFlex).
        if (rest.isNotEmpty) Flexible(child: Text(rest, style: bodyStyle)),
      ],
    );
  }
}
