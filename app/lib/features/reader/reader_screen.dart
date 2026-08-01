import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:loom_core/loom_core.dart' as core;
import 'package:openhearth_design/openhearth_design.dart';

// `Alignment` here is drift's generated row class for the Alignments
// table, which collides with Flutter's own painting Alignment used by
// Campaign 4's parafoveal grid layout — hidden since this file never
// references the row type by name (only through inferred DAO returns).
import '../../db/database.dart' hide Alignment;
import '../../services/device_services.dart';
import '../brain/brain_store.dart';
import '../brain/distill_screen.dart';
import '../intake/paste_intake.dart' show epochDayUtcNow;
import '../player/player_controller.dart';
import 'dictionary_sheet.dart';
import 'ledger_screen.dart';
import 'line_paced_view.dart';
import 'reader_logic.dart';
import 'reader_prefs.dart';
import 'reader_typography_settings_screen.dart';
import 'recap_sheet.dart';
import 'speech/just_audio_speech_queue.dart';
import 'speech/speech_audio_queue.dart';
import 'speech/speech_engine.dart';
import 'speech/speech_playback_pipeline.dart';
import 'speech/speech_temp_files.dart';
import 'speech/supertonic_voice_handle.dart' show supertonicSupportedLangs;
import 'translation/language_names.dart';
import 'translation/marian_engine.dart';
import 'translation/sentence_units.dart';
import 'translation/translation_job.dart';

/// The hearth red — the heritage ORP pivot color carried from both donors,
/// which is the fleet's own hearth500 (C1: from the tokens, not retyped).
const Color kPivotColor = OhColors.hearth500;

/// Campaign 9 Phase 6 ("a third way to read") adds [lines] as a genuine
/// third top-level mode alongside the original two — a scroll-family view
/// (see [_linesBody]) highlighting one VISUAL LINE at a time rather than
/// one word ([rsvp]) or nothing beyond the current segment ([scroll]).
enum ReaderMode { rsvp, scroll, lines }

/// The mode picker's own public label — distinct from the internal
/// [ReaderMode] names the same way "Parafoveal" is the public name for
/// what this file's own tests call "ticker" (see [_parafoveal]'s doc
/// comment): [ReaderMode.rsvp] reads "Words" to a reader, never "RSVP".
String readerModeLabel(ReaderMode m) => switch (m) {
      ReaderMode.rsvp => 'Words',
      ReaderMode.scroll => 'Scroll',
      ReaderMode.lines => 'Lines',
    };

IconData readerModeIcon(ReaderMode m) => switch (m) {
      ReaderMode.rsvp => Icons.center_focus_strong,
      ReaderMode.scroll => Icons.notes,
      ReaderMode.lines => Icons.view_stream_outlined,
    };

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

  /// Campaign 4 Phase 3: the tap-hold definition sheet's on-device
  /// dictionary lookup — the caller closes over
  /// `DeviceServices.lookupDefinition` so this widget's own tests never
  /// reach a device-services mock, the same shape [resolveSpeechEngine]
  /// already uses. Null means the sheet always shows its honest empty
  /// state (no dictionary door wired at this call site).
  final Future<String?> Function(String word)? lookupDefinition;

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

  /// The study crown's other half of the read<->listen handoff (the karaoke
  /// screen's "Read from here" is the other): when this work has aligned
  /// audio, "Listen from here" hands the reading cursor to this controller.
  /// Null (the default at most call sites today) simply hides the button —
  /// never a dead one dangled where playback can't actually start.
  final PlayerController? player;

  /// Resolves a translator for a specific (source, target) pair (Campaign
  /// 8 "Babel widens" Phase 1, generalizing ADR-0008 "Babel" Phase 3's
  /// fixed-Spanish version) — the shell closes over
  /// `DeviceServices.resolveTranslator`. Null (or a call that resolves to
  /// null, meaning that pair isn't downloaded) keeps the "Translate…"
  /// action hidden for a work whose declared language has NO downloaded
  /// pair, and keeps the specific target refused if picked anyway. Called
  /// once per target chosen, not once per screen session — unlike
  /// [resolveSpeechEngine], a work can pick a NEW target at any time, so
  /// there is nothing to cache until a target is actually chosen (see
  /// [ReaderScreen.availableTranslationTargets] for the picker's own,
  /// once-per-session resolution).
  final Future<MarianTranslator?> Function(
      {required String sourceLang, required String targetLang})?
      resolveTranslator;

  /// Every target language this device can actually translate a work's
  /// declared source language into RIGHT NOW — a downloaded pair, never
  /// merely a registered one (Campaign 8 "Babel widens" Phase 1). Null
  /// (or an empty list) keeps the "Translate…" action hidden entirely.
  /// Resolved once, in [_load], the same residency law
  /// [resolveSpeechEngine] follows — the picker's OPTIONS don't change
  /// mid-session even though which one is ACTIVE can.
  final Future<List<String>> Function({required String sourceLang})?
      availableTranslationTargets;

  /// Campaign 4 Phase 4: true when this work was reopened untouched for
  /// more than 3 UTC days with real progress already made
  /// ([shouldOfferRecap], resolved by the caller from [Positions]/segment
  /// count — the same "resolved before the push" shape [offerNeuralVoice]
  /// already uses, so this widget's own tests stay a plain bool). Shows a
  /// dismissible "Catch me up?" chip; false (every existing call site)
  /// shows nothing.
  final bool offerRecap;

  const ReaderScreen(
      {super.key,
      required this.db,
      required this.profileId,
      required this.work,
      this.tts,
      this.brain,
      this.offerNeuralVoice = false,
      this.resolveSpeechEngine,
      this.lookupDefinition,
      this.createSpeechAudioQueue,
      this.createSpeechTempFiles,
      this.player,
      this.resolveTranslator,
      this.availableTranslationTargets,
      this.offerRecap = false});

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

  /// Campaign 4 Phase 2 follow-along: one [GlobalKey] per built segment
  /// tile, the same shape `karaoke_screen.dart`'s `_keys` map uses for its
  /// own `_followPlayback` -- lazily populated by [_segmentTile] (only
  /// tiles the sliver has actually built get an entry, same as karaoke).
  final Map<int, GlobalKey> _segKeys = {};

  /// Dedupes [_followAlongScroll] so it only calls `ensureVisible` once
  /// per segment the cursor enters, not once per rebuild.
  int _lastFollowedSegment = -1;
  bool _playing = false;
  double _wpm = 300;
  Timer? _timer;

  /// Campaign 4 Phase 2: Parafoveal is an RSVP sub-toggle, not a
  /// [ReaderMode] of its own -- a sub-toggle restores the donor's third
  /// display (index.html mode "ticker", but this app's own "ticker"
  /// vocabulary already names the existing classic RSVP mode -- the
  /// public name here is always Parafoveal) without adding a fourth
  /// top-level mode, and it shares the RSVP timer/cursor (`_step`,
  /// `_wordIdx`) wholesale, so punctuation-pause lengthening comes free
  /// with no separate dwell path. (Campaign 9 Phase 6 later gives the
  /// reader a genuine third [ReaderMode], Lines -- [_setMode] now opens a
  /// labeled three-way picker rather than cycling a binary toggle; see
  /// `reader_test.dart`'s and `reader_ticker_test.dart`'s cursor-law
  /// tests for the mode-switch invariant Parafoveal never touches.)
  bool _parafoveal = false;

  /// The neighbor-fade sigma (donor default 2.0, slider 0.8-4.0 step 0.2).
  /// Session-scoped like [_wpm], not persisted -- Campaign 4's playback
  /// controls follow the reader's existing wpm precedent ("holds for the
  /// session"), not the typography prefs' cross-session precedent.
  double _sigma = 2.0;

  /// Donor default window: 5 neighbors either side of the focus word.
  /// Not exposed as a control this pass -- the spec only asks for a sigma
  /// slider.
  static const int _parafovealWinSize = 5;

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

  /// Campaign 4 Phase 4: whether the "Catch me up?" chip has been
  /// dismissed (tapped or closed with the X) THIS screen session — same
  /// once-per-session shape as [_offeredNeuralVoice], session state, not
  /// persisted (matches Phase 2's Parafoveal/follow-along precedent: this
  /// reader has never carried playback-adjacent UI state across sessions).
  bool _recapOfferDismissed = false;

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
  List<({int seg, int wordIdx, String text, String? lang})> _synthUnits =
      const [];
  int _synthGen = 0;

  /// The language toggle (ADR-0002: layers project onto the SAME cursor).
  /// [_original] holds the canonical segments; [_mtLangs] the mt layers on
  /// offer; [_activeLang] which one currently projects (null = original).
  List<core.Segment> _original = const [];
  List<String> _mtLangs = const [];
  Map<String, Map<int, String>> _mtTexts = const {};
  String? _activeLang;

  /// The study crown: true only when this work has BOTH an audio source
  /// and alignments over it — the "Listen from here" button's honesty
  /// check (see [ReaderScreen.player]'s doc comment on never dangling one).
  bool _hasAlignedAudio = false;

  /// Campaign 9 Phase 7 ("the reader follows the player"): this work's own
  /// alignments, wrapped the same way [KaraokeScreen] wraps them, resolved
  /// once in [_load] alongside [_hasAlignedAudio] rather than re-fetched
  /// per tick. Null exactly when [_hasAlignedAudio] is false — there is
  /// nothing to project audio time through.
  core.Spine? _spine;

  /// True while [widget.player]'s position ticks are moving this reader's
  /// own cursor — set by [_attachAudioFollow], cleared by
  /// [_detachAudioFollow] (a manual seek, a manual scroll, or playback
  /// moving to a different work). This is independent of
  /// [PlayerController.playing]: a listener stays attached across a pause
  /// (a paused player's position ticks stop arriving, not the attachment
  /// itself — the chip should still read "Following audio" through a
  /// pause, the same way a paused karaoke view stays lit on its segment).
  bool _followingAudio = false;

  /// The translation store overlay (Campaign 8 "Babel widens" Phase 1,
  /// generalizing ADR-0008 "Babel" Phase 3's fixed-Spanish version) —
  /// deliberately separate from [_activeLang]'s whole-segment mt swap:
  /// this pairs each original sentence with its translation rather than
  /// replacing the text the cursor and every existing test key off. Both
  /// the Translate action and the Show ⟨language⟩ toggle are offered
  /// only while [_activeLang] is null (guards against numbering under a
  /// language-swapped projection, whose own `splitSentences` boundaries
  /// can differ from the English original's).
  MarianTranslator? _translatorHolder;
  TranslationJobController? _translationJob;

  /// Every target this work's declared source language can actually
  /// translate into right now (a downloaded pair) — the "Translate…"
  /// picker's own options, resolved once in [_load]. Empty hides the
  /// action entirely.
  List<String> _availableTargets = const [];

  /// The one active translation target for this work (`null` = none
  /// chosen yet), mirroring [Works.activeTranslationLang] — "one active
  /// translation layer per work at a time" made literal: picking a new
  /// target REPLACES this, never adds to a set. A LEGACY fallback: a work
  /// translated before this campaign has `showTranslationLayer=true` and
  /// `activeTranslationLang=null` (the column didn't exist yet) — 'es'
  /// was the only language that could have written it, so [_load] reads
  /// that case as an implicit 'es' rather than showing nothing for data
  /// that was genuinely there.
  String? _activeTranslationLang;
  bool _showTranslation = false;
  Map<(int, int), TranslationSentence> _translatedSentences = const {};

  /// A target has been chosen AND there is at least one row behind it —
  /// the two are not the same moment. [_startTranslation] sets the active
  /// lang before its batch has produced a single sentence (so the
  /// progress card can appear immediately); a batch cancelled at zero
  /// rows leaves the lang set with nothing to show or speak. Gate the
  /// Show/Speak controls on this, not on [_activeTranslationLang] alone.
  bool get _hasStoredTranslation =>
      _activeTranslationLang != null && _translatedSentences.isNotEmpty;

  /// Speak-in-⟨language⟩ (ADR-0008 "Babel" Phase 4, generalized): offered
  /// only while [_showTranslation] is on, session-only (never persisted —
  /// unlike [_showTranslation], there is no natural "was this on last
  /// time" question for a run-time speech choice). Reset to false
  /// whenever Show ⟨language⟩ itself is turned off, so a hidden menu item
  /// can never silently keep affecting a later run.
  bool _speakTranslation = false;

  /// Campaign 4 Phase 1: this profile's print-reader typography, loaded
  /// once in [_load] (the residency law — no re-fetch per rebuild). RSVP
  /// and the ticker keep their own tuned displays; only the scroll body
  /// reads this.
  ReaderTypography _typography = const ReaderTypography();

  /// The work's declared source language, re-read from the DB by [_load]
  /// rather than trusted from [ReaderScreen.work] (which the PARENT set
  /// once and never updates) — [_openWorkLanguagePicker] writes through
  /// [SpineDao.setWorkLang] then calls [_load] again, and only a fresh DB
  /// read picks that up. `null` until the first [_load] completes.
  String? _workLang;

  /// The work's declared source language (Campaign 8 "Babel widens" Phase
  /// 1) — defaults to 'en' when nothing was declared at intake time
  /// (most intake paths never populate [Work.lang]; see
  /// docs/reference/mt-models.md). A UI-layer convention, not a DB-layer
  /// one: the row itself stays honestly null until a reader corrects it
  /// through the calm per-work selector.
  String get _sourceLang => _workLang ?? widget.work.lang ?? 'en';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Campaign 9 Phase 7: safe even if never attached (removeListener
    // no-ops on an unheld listener) — every listener this screen ever
    // adds gets exactly one matching removal on its way out.
    widget.player?.removeListener(_onPlayerTick);
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
    final translator = _translatorHolder;
    if (translator != null) unawaited(translator.dispose().catchError((_) {}));
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
    // Re-read the work row's OWN lang rather than trusting
    // [ReaderScreen.work] (set once by the parent, never updated) —
    // [_openWorkLanguagePicker] calls [_load] again after writing a new
    // one through the DAO, and only a fresh read picks that up.
    final freshWork = await widget.db.spineDao.workById(widget.work.id);
    final workLang = freshWork?.lang ?? widget.work.lang;
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
        resolver == null ? null : await resolver(lang: workLang);
    // The study crown: only offer "Listen from here" where it can actually
    // start something (an audio source) AND land somewhere meaningful (an
    // alignment to project the cursor through). The same rows also feed
    // Phase 7's [_spine] — [KaraokeScreen]'s own construction, wrapped
    // here so [_onPlayerTick] never re-fetches per tick.
    final alignmentRows =
        await widget.db.spineDao.alignmentsOf(widget.work.id);
    final hasAlignedAudio =
        widget.work.sourceUrl != null && alignmentRows.isNotEmpty;
    final spine = alignmentRows.isEmpty
        ? null
        : core.Spine(segments: const [], layers: const [], alignments: [
            for (final a in alignmentRows)
              core.Alignment(
                  segmentIdx: a.segmentIdx,
                  tStartMs: a.tStartMs,
                  tEndMs: a.tEndMs),
          ]);
    // The translation store (Campaign 8 "Babel widens" Phase 1,
    // generalizing ADR-0008 "Babel" Phase 3): the picker's OPTIONS,
    // resolved once, the same residency law the neural voice follows
    // above; WHICH ONE is active, and its translator/stored sentences.
    final sourceLang = workLang ?? 'en';
    final targetsResolver = widget.availableTranslationTargets;
    final availableTargets = targetsResolver == null
        ? const <String>[]
        : await targetsResolver(sourceLang: sourceLang);
    var activeLang =
        await widget.db.spineDao.activeTranslationLang(widget.work.id);
    final showTranslation =
        await widget.db.spineDao.showTranslationLayer(widget.work.id);
    // Legacy fallback: a work translated before this campaign has
    // activeTranslationLang=null (the column didn't exist yet) — 'es' was
    // the only language that could have written it. This probe is
    // independent of showTranslation's current value: a 1.3.0 user who
    // had stored Spanish but had toggled the display OFF must still see
    // the "Show Spanish" control on reopen, not lose it because the bool
    // that gates DISPLAY got conflated with the probe for EXISTENCE.
    if (activeLang == null) {
      final hasEs = await widget.db.spineDao
          .hasTranslationSentences(widget.work.id, lang: 'es');
      if (hasEs) activeLang = 'es';
    }
    final translatorResolver = widget.resolveTranslator;
    final translator = translatorResolver == null || activeLang == null
        ? null
        : await translatorResolver(
            sourceLang: sourceLang, targetLang: activeLang);
    final translatedSentences = activeLang == null
        ? const <(int, int), TranslationSentence>{}
        : await widget.db.spineDao
            .translationSentencesOf(widget.work.id, lang: activeLang);
    final readerPrefs = await widget.db.profilesDao.readerPrefs(widget.profileId);
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
      _hasAlignedAudio = hasAlignedAudio;
      _workLang = workLang;
      _availableTargets = availableTargets;
      _spine = spine;
      _translatorHolder = translator;
      _activeTranslationLang = activeLang;
      _showTranslation = showTranslation;
      _translatedSentences = translatedSentences;
      _typography = readerPrefs.typography;
    });
    // Campaign 9 Phase 7: audio for THIS work already playing when the
    // reader opens is one of the two attach triggers (the other is
    // [_listenFromHere] itself, below) — a listener already mid-episode
    // should not have to re-trigger playback just to be followed.
    final player = widget.player;
    if (player != null &&
        player.current?.id == widget.work.id &&
        player.playing) {
      _attachAudioFollow();
    }
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
    // Campaign 4 Phase 5's write side: every position save is proof the
    // cursor actually advanced today, so this is the one honest place to
    // mark a reading day (idempotent — see ReadingDays' own doc comment).
    await widget.db.profilesDao
        .recordReadingDay(widget.profileId, epochDayUtcNow());
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
  ///
  /// Campaign 8 "Babel widens" discovery: the neural voice's own language
  /// gate (`supertonicSupportedLangs`, currently `{'en', 'es'}`) throws
  /// `SupertonicUnsupportedLangException` — UNCAUGHT — the instant a
  /// per-utterance `lang` tag it doesn't cover reaches it
  /// (`_preprocessText`, called from every `synthesize`/`speak`). The
  /// neural engine is primed for the WORK's source language (always
  /// covered, since it primed successfully), but Speak-in-⟨language⟩
  /// substitutes a DIFFERENT tag per translated sentence — so a target
  /// this campaign ships (de/ru/zh: none in `supertonicSupportedLangs`)
  /// would crash the run the instant a translated sentence's turn came
  /// up. This is engine-SELECTION-level, not per-utterance: forcing the
  /// system voice for the WHOLE run when Speak-in-⟨language⟩ is on for
  /// an uncovered target sidesteps ever needing to catch the exception
  /// mid-run.
  SpeechEngine _resolveEngine() {
    final synth = _synthEngineHolder;
    final speakingUncoveredTarget = _speakTranslation &&
        _activeTranslationLang != null &&
        !supertonicSupportedLangs.contains(_activeTranslationLang);
    if (!_preferSystemVoice && synth != null && !speakingUncoveredTarget) {
      return synth;
    }
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
      for (var i = 0; i < units.length; i++) {
        final sentence = units[i];
        if (!live()) return;
        if (!first) {
          setState(() => _wordIdx =
              globalWordIndex(doc, seg, sentence.firstWordIdx));
          await _savePosition(modality: 'speak');
          if (!live()) return;
        }
        first = false;
        if (speakable && sentence.text.trim().isNotEmpty) {
          // Speak-in-⟨language⟩ (ADR-0008 Phase 4, generalized Campaign
          // 8): `i` here is the RAW core.splitSentences index (this loop
          // only reaches `units[i]` through the real `sentences` list —
          // the empty-sentences whole-block fallback never has non-blank
          // speakable text, so `i` never collides with a real
          // sentenceIdx from a different numbering). A sentence with no
          // stored translation falls back to English, spoken in its
          // original language — no gap.
          final translated = _speakTranslation && _activeTranslationLang != null
              ? translatedTextFor(
                  stored: _translatedSentences,
                  segIdx: block.idx,
                  sentenceIdx: i,
                  currentSourceText: sentence.text)
              : null;
          await engine.speak(translated ?? sentence.text,
              lang: translated != null
                  ? _activeTranslationLang
                  : (_activeLang ?? _workLang ?? widget.work.lang));
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
  ///
  /// Speak-in-⟨language⟩ (ADR-0008 Phase 4, generalized Campaign 8):
  /// [text] carries the STORED translation in place of the original
  /// wherever one exists and [_speakTranslation] is on — [lang] is that
  /// substitution's own tag ([_activeTranslationLang]), null otherwise,
  /// so [SpeechPlaybackPipeline.start]'s `langOverrides` can tag each
  /// sentence in the language it's ACTUALLY written in rather than one
  /// language for the whole batch. [seg]/[wordIdx] always point at the
  /// ORIGINAL sentence's position — the cursor never moves to reflect
  /// which language is playing.
  List<({int seg, int wordIdx, String text, String? lang})>
      _remainingSpeechUnits(List<core.Segment> blocks, int fromSeg) {
    final units = <({int seg, int wordIdx, String text, String? lang})>[];
    for (var seg = fromSeg; seg < blocks.length; seg++) {
      final block = blocks[seg];
      final speakable = block.kind == core.SegmentKind.prose ||
          block.kind == core.SegmentKind.heading;
      if (!speakable || block.text.trim().isEmpty) continue;
      final sentences = core.splitSentences(block.text);
      for (var i = 0; i < sentences.length; i++) {
        final sentence = sentences[i];
        if (sentence.text.trim().isEmpty) continue;
        final translated = _speakTranslation && _activeTranslationLang != null
            ? translatedTextFor(
                stored: _translatedSentences,
                segIdx: block.idx,
                sentenceIdx: i,
                currentSourceText: sentence.text)
            : null;
        units.add((
          seg: seg,
          wordIdx: sentence.firstWordIdx,
          text: translated ?? sentence.text,
          lang: translated != null ? _activeTranslationLang : null,
        ));
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
        lang: _activeLang ?? _workLang ?? widget.work.lang,
        langOverrides: [for (final u in units) u.lang]);
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

  // ───── translation (ADR-0008 "Babel" Phase 3; Campaign 8 "Babel
  // widens" Phase 1 generalizes it to any registered, downloaded pair) ─────

  /// Opens the "Translate…" picker and, if the reader picks a target,
  /// starts translating into it. A no-op if there is nothing to offer —
  /// the menu item itself is hidden in that case (see the overflow menu's
  /// `itemBuilder`), so this is a second, defensive gate, not the only
  /// one.
  /// The calm per-work source-language selector (Campaign 8 "Babel
  /// widens" Phase 1) — most intake paths never populate [Work.lang] at
  /// import time (see docs/reference/mt-models.md), so a reader who knows
  /// better corrects it here. No auto-detection — a curated list, never a
  /// guess. Reloads the whole screen afterward: a language change can
  /// change [_availableTargets], which voice [_synthEngineHolder] should
  /// even be, and whether an already-active translation still makes
  /// sense — simplest and safest to re-derive all of it through the same
  /// [_load] every other state field already trusts, rather than
  /// hand-patching each one here.
  Future<void> _openWorkLanguagePicker() async {
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        key: const Key('work-language-picker'),
        title: const Text('This work is in…'),
        children: [
          for (final lang in selectableWorkLanguages)
            SimpleDialogOption(
              key: Key('work-language-$lang'),
              onPressed: () => Navigator.of(ctx).pop(lang),
              child: Text(languageDisplayName(lang)),
            ),
        ],
      ),
    );
    if (chosen == null || chosen == _sourceLang) return;
    await widget.db.spineDao.setWorkLang(widget.work.id, chosen);
    if (!mounted) return;
    await _load();
  }

  Future<void> _openTranslatePicker() async {
    if (_availableTargets.isEmpty || _activeLang != null) return;
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        key: const Key('translate-picker'),
        title: const Text('Translate to…'),
        children: [
          for (final lang in _availableTargets)
            SimpleDialogOption(
              key: Key('translate-target-$lang'),
              onPressed: () => Navigator.of(ctx).pop(lang),
              child: Text(languageDisplayName(lang)),
            ),
        ],
      ),
    );
    if (chosen != null) await _startTranslation(chosen);
  }

  /// Runs the cancellable, resumable Translate-to-[targetLang] batch over
  /// [_original] — never [_blocks], which under [_activeLang] is a
  /// language-swapped projection whose own `splitSentences` boundaries
  /// would disagree with the store's numbering. Already-stored sentences
  /// are skipped inside [TranslationJobController] itself; this method
  /// resolves the translator for [targetLang] (never cached across
  /// targets — a work can pick a NEW one at any time), starts the batch,
  /// listens for the progress card, and reloads this screen's translation
  /// state once the run lands (done or cancelled). Refuses [targetLang]
  /// == the work's own declared source language even if somehow reached
  /// (the picker itself never offers it — [DeviceServices
  /// .availableTranslationTargets] excludes it at the source) — a second,
  /// defensive gate, the same "never trust a single chokepoint" shape
  /// [_openTranslatePicker]'s own emptiness check follows.
  Future<void> _startTranslation(String targetLang) async {
    if (targetLang == _sourceLang) return;
    if (_activeLang != null || _translationJob != null) return;
    final resolver = widget.resolveTranslator;
    if (resolver == null) return;
    final translator = await resolver(
        sourceLang: _sourceLang, targetLang: targetLang);
    if (translator == null || !mounted) return;
    await widget.db.spineDao
        .setActiveTranslationLang(widget.work.id, targetLang);
    setState(() {
      _translatorHolder = translator;
      _activeTranslationLang = targetLang;
      _showTranslation = true;
    });
    final controller = TranslationJobController(
      dao: widget.db.spineDao,
      workId: widget.work.id,
      units: sentenceUnitsOf(_original),
      translate: translator.translate,
      lang: targetLang,
    );
    controller.addListener(_onTranslationProgress);
    setState(() => _translationJob = controller);
    await controller.start();
    controller.removeListener(_onTranslationProgress);
    if (!mounted) return;
    final translatedSentences = await widget.db.spineDao
        .translationSentencesOf(widget.work.id, lang: targetLang);
    if (!mounted) return;
    setState(() {
      _translatedSentences = translatedSentences;
      _translationJob = null;
    });
  }

  void _onTranslationProgress() {
    if (!mounted) return;
    setState(() {}); // the card reads _translationJob!.state directly
  }

  void _cancelTranslation() => _translationJob?.cancel();

  /// The scroll-mode dual-display toggle: persisted through the DAO (not
  /// local-only state), same law [_toggleVoicePreference] follows. Turning
  /// it off also turns [_speakTranslation] off — its own menu item is
  /// about to disappear, and a stale `true` behind a hidden control would
  /// keep substituting the translation into a run the user has no way to
  /// see, let alone turn off again.
  Future<void> _toggleShowTranslation() async {
    final next = !_showTranslation;
    setState(() {
      _showTranslation = next;
      if (!next) _speakTranslation = false;
    });
    await widget.db.spineDao.setShowTranslationLayer(widget.work.id, next);
  }

  /// Speak-in-⟨language⟩ (ADR-0008 "Babel" Phase 4, generalized): takes
  /// effect on the NEXT speak run, the same law [_toggleVoicePreference]
  /// follows — a run already under way keeps speaking whatever it
  /// started with.
  void _toggleSpeakTranslation() =>
      setState(() => _speakTranslation = !_speakTranslation);

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
    // Every fresh play starts follow-along's own dedupe clean, so the
    // segment the cursor is already on gets its ensureVisible call even
    // if a previous follow-along session already visited it once.
    _lastFollowedSegment = -1;
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
    _detachAudioFollow(); // Campaign 9 Phase 7: the user's hand always wins
    setState(() =>
        _wordIdx = (_wordIdx + delta).clamp(0, doc.words.length - 1));
    if (_playing) _step();
  }

  void _seekToWord(int globalIdx) {
    final doc = _doc;
    if (doc == null || doc.words.isEmpty) return;
    _timer?.cancel();
    unawaited(_stopSpeak());
    _detachAudioFollow(); // Campaign 9 Phase 7: the user's hand always wins
    setState(() => _wordIdx = globalIdx.clamp(0, doc.words.length - 1));
    if (_playing) _step();
  }

  /// Campaign 9 Phase 6: the mode picker's own handler, replacing the old
  /// binary [_toggleMode] now that there are three named choices, not
  /// two. The cursor itself (`_wordIdx`) is untouched by a mode switch in
  /// EITHER direction — that is ADR-0002's cursor law and the whole point
  /// of every mode reading the same word stream — only the scroll-family
  /// modes' own viewport anchor needs re-deriving from it, so a switch
  /// INTO Scroll or Lines from anywhere opens on the segment the cursor
  /// is actually in rather than the top of the document.
  void _setMode(ReaderMode next) {
    if (next == _mode) return;
    _pause();
    setState(() {
      _mode = next;
      final doc = _doc;
      if (_mode != ReaderMode.rsvp && doc != null && doc.words.isNotEmpty) {
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
        lang: _activeLang ?? _workLang ?? widget.work.lang,
        sourceWorkId: widget.work.id,
        nowMs: DateTime.now().millisecondsSinceEpoch);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
          SnackBar(content: Text('“$word” is in your word ledger.')));
  }

  /// Campaign 4 Phase 3: what a long-pressed word does now — the
  /// definition sheet ABSORBS the keep action (its own "Add to word
  /// ledger" button calls [_keepWord] under the hood) rather than
  /// stacking a second long-press on top of the reader's existing one.
  /// Nothing wordy in [token] (edge punctuation only) opens nothing, the
  /// same silent no-op [_keepWord] already had.
  ///
  /// Pauses first, matching [_openTypographySettings] and [_setMode]:
  /// Phase 2's follow-along made scroll mode playable, which means a held
  /// word can now be on a document that's still advancing underneath the
  /// modal — an un-paused cursor would keep calling `_followAlongScroll`'s
  /// `Scrollable.ensureVisible` on a scrollable sitting under the sheet's
  /// route, racing the sheet for the user's attention.
  void _openDefinitionSheet(String token) {
    final cleaned = ledgerWord(token);
    if (cleaned == null) return;
    _pause();
    unawaited(showDefinitionSheet(
      context,
      word: cleaned,
      lookupDefinition: widget.lookupDefinition ?? (_) async => null,
      onKeep: () => _keepWord(token),
    ));
  }

  void _openLedger() {
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) =>
            LedgerScreen(db: widget.db, profileId: widget.profileId)));
  }

  // ───── the study crown: read -> listen handoff ─────

  /// "Listen from here": hands the reading cursor's own segment/word to
  /// [ReaderScreen.player], which projects it to an audio time via the SAME
  /// alignments the karaoke view already reads (Spine.projectAudioTime) —
  /// no second cursor, no new persisted state. `blocks[c.segment].idx` is
  /// the translation `_savePosition` already does: [cursorAt] returns a
  /// position in the `_blocks` LIST, not the database's `Segment.idx`.
  Future<void> _listenFromHere() async {
    final doc = _doc;
    final blocks = _blocks;
    final player = widget.player;
    if (doc == null || blocks == null || player == null || doc.words.isEmpty) {
      return;
    }
    final c = cursorAt(doc, _wordIdx);
    await player.listenFrom(
        widget.work,
        core.Position(
            segmentIdx: blocks[c.segment].idx,
            wordIdx: c.word,
            lastModality: core.Modality.read));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Listening from here.')));
    // Campaign 9 Phase 7: the second of the two attach triggers — the
    // first is [_load] finding audio for this work already under way.
    _attachAudioFollow();
  }

  // ───── Campaign 9 Phase 7: the reader follows the player ─────

  /// True whenever there is ANYTHING to follow, whether or not this
  /// screen is currently doing so — gates the chip's very presence
  /// (never shown for a work with no player, no aligned audio, or where
  /// playback has moved on to something else entirely).
  bool get _audioFollowable =>
      widget.player != null &&
      _spine != null &&
      widget.player!.current?.id == widget.work.id;

  /// Subscribes [_onPlayerTick] to [ReaderScreen.player] — a no-op if
  /// there is nothing to follow ([_audioFollowable] false) or a listener
  /// is already attached (`ChangeNotifier.addListener` would otherwise
  /// register the same callback twice, double-firing every tick).
  void _attachAudioFollow() {
    if (_followingAudio || !_audioFollowable) return;
    widget.player!.addListener(_onPlayerTick);
    setState(() => _followingAudio = true);
  }

  /// The user's hand always wins (house law): a manual seek, a manual
  /// scroll, or playback moving on to a different work all call this.
  /// Safe to call when nothing is attached — `ChangeNotifier
  /// .removeListener` no-ops on a listener it never held.
  void _detachAudioFollow() {
    widget.player?.removeListener(_onPlayerTick);
    if (_followingAudio && mounted) setState(() => _followingAudio = false);
  }

  /// The listener itself — [PlayerController] notifies on every position
  /// tick (house stream-lifecycle laws: this is added exactly once, in
  /// [_attachAudioFollow], and removed in [_detachAudioFollow]/[dispose],
  /// never left dangling). Detaches quietly, without altering the reader
  /// otherwise, the moment playback is no longer THIS work's — following
  /// a different work's audio through this screen would be a silent lie.
  void _onPlayerTick() {
    final player = widget.player;
    final spine = _spine;
    final doc = _doc;
    final blocks = _blocks;
    if (player == null || player.current?.id != widget.work.id) {
      _detachAudioFollow();
      return;
    }
    if (spine == null || doc == null || blocks == null) return;
    final newIdx = wordIndexAtAudioTime(
        spine: spine,
        doc: doc,
        blocks: blocks,
        audioTimeMs: player.position.inMilliseconds);
    if (newIdx == null || newIdx == _wordIdx || !mounted) return;
    setState(() => _wordIdx = newIdx);
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

  /// Campaign 4 Phase 1: the print-reader typography settings, reached the
  /// same way distill is — an overflow-menu gesture, both cursor-advancers
  /// stopped first.
  Future<void> _openTypographySettings() async {
    _pause();
    unawaited(_stopSpeak());
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ReaderTypographySettingsScreen(
            db: widget.db, profileId: widget.profileId)));
    // Prefs may have changed while the settings screen was open; reload
    // rather than re-derive so the scroll body picks up the new values on
    // return.
    if (!mounted) return;
    final prefs = await widget.db.profilesDao.readerPrefs(widget.profileId);
    if (!mounted) return;
    setState(() => _typography = prefs.typography);
  }

  // ───── Campaign 4 Phase 4: the "Catch me up?" recap ─────

  /// The chip's tap handler — same order [_distill] already established:
  /// both cursor-advancers stop first (this is a hand leaving the reading
  /// surface for a moment, same as any other overflow action), then
  /// [openRecapFlow] walks consent before any Brain call.
  Future<void> _openRecap() async {
    setState(() => _recapOfferDismissed = true);
    _pause();
    unawaited(_stopSpeak());
    final doc = _doc;
    final blocks = _blocks;
    if (doc == null || blocks == null) return;
    final c = cursorAt(doc, _wordIdx);
    await openRecapFlow(context,
        db: widget.db,
        work: widget.work,
        currentSegmentIdx: blocks[c.segment].idx,
        store: widget.brain ?? BrainStore.production());
  }

  /// A quiet, dismissible offer — never re-shown once the reader decides
  /// either way (tap it or close it), matching the once-per-session shape
  /// [_offeredNeuralVoice] already uses for a different hint.
  ///
  /// Deliberately NOT an `AppBar.bottom` `PreferredSize` slot: that shape
  /// needs a fixed height picked in advance, and a `Row`'s children
  /// overflowing that height vertically clip silently rather than
  /// throwing — a real regression a widget test could not catch by
  /// watching for exceptions (found while writing the 320dp/2x sweep
  /// below). Living as the body `Column`'s first child instead sizes
  /// itself to whatever the chip and its label actually need at any text
  /// scale, no magic constant to keep in sync with anything.
  Widget _recapOfferBar(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: ActionChip(
                  key: const Key('recap-offer-chip'),
                  avatar: const Icon(Icons.history_edu_outlined, size: 18),
                  label: const Text('Catch me up?'),
                  onPressed: () => unawaited(_openRecap()),
                ),
              ),
            ),
            IconButton(
              key: const Key('recap-offer-dismiss'),
              tooltip: 'Not now',
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => setState(() => _recapOfferDismissed = true),
            ),
          ],
        ),
      ),
    );
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
          // Campaign 9 Phase 6: a labeled three-way choice (Scroll / Words
          // / Lines), not a binary cycle — [readerModeLabel] names the
          // CURRENT mode rather than "what tapping does" (a menu shows
          // every destination by name, so there is no next-state to
          // hint at the way the old two-state toggle's icon/tooltip did).
          PopupMenuButton<ReaderMode>(
            key: const Key('mode-toggle'),
            tooltip: 'Reading mode: ${readerModeLabel(_mode)}',
            enabled: doc != null,
            icon: Icon(readerModeIcon(_mode)),
            onSelected: _setMode,
            itemBuilder: (_) => [
              for (final m in ReaderMode.values)
                CheckedPopupMenuItem<ReaderMode>(
                  key: Key('mode-item-${readerModeLabel(m).toLowerCase()}'),
                  value: m,
                  checked: m == _mode,
                  child: Text(readerModeLabel(m)),
                ),
            ],
          ),
          IconButton(
            key: const Key('open-ledger'),
            tooltip: 'Word ledger',
            icon: const Icon(Icons.bookmark_border),
            onPressed: _openLedger,
          ),
          if (_hasAlignedAudio && widget.player != null)
            IconButton(
              key: const Key('listen-from-here'),
              tooltip: 'Listen from here',
              icon: const Icon(Icons.headphones_outlined),
              onPressed: doc == null ? null : _listenFromHere,
            ),
          PopupMenuButton<String>(
            key: const Key('reader-overflow'),
            tooltip: 'More',
            onSelected: (value) {
              if (value == 'distill') unawaited(_distill());
              if (value == 'system-voice') unawaited(_toggleVoicePreference());
              if (value == 'translate') unawaited(_openTranslatePicker());
              if (value == 'show-translation') {
                unawaited(_toggleShowTranslation());
              }
              if (value == 'speak-translation') _toggleSpeakTranslation();
              if (value == 'reading-style') unawaited(_openTypographySettings());
              if (value == 'work-language') unawaited(_openWorkLanguagePicker());
              if (value == 'follow-along') _playing ? _pause() : _play();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                  value: 'distill',
                  child: Text('Distill into a course')),
              const PopupMenuItem(
                  value: 'reading-style',
                  child: Text('Reading style')),
              // Campaign 8 "Babel widens" Phase 1: the calm per-work
              // source-language selector — always offered (unlike the
              // translate/show/speak items below, which gate on there
              // being something to offer), since correcting a work's
              // declared language is meaningful even with nothing
              // downloaded to translate it with yet.
              PopupMenuItem(
                  key: const Key('work-language-action'),
                  value: 'work-language',
                  child: Text('Language: ${languageDisplayName(_sourceLang)}')),
              // Campaign 4 Phase 2: scroll-family modes only (Scroll, and
              // Lines as of Campaign 9 Phase 6) — RSVP already has its own
              // dedicated play-toggle button; this shares the same
              // _playing/_play/_pause the RSVP button drives, so switching
              // modes (which already _pause()s first) can never leave a
              // stray follow-along timer running behind RSVP.
              if (_mode != ReaderMode.rsvp)
                PopupMenuItem(
                  key: const Key('follow-along-toggle'),
                  value: 'follow-along',
                  child: Text(
                      _playing ? 'Stop following along' : 'Follow along'),
                ),
              // The settings escape (ADR-0006): only visible when there is
              // a neural voice to escape FROM — no dead settings.
              if (_synthEngineHolder != null)
                CheckedPopupMenuItem<String>(
                  key: const Key('voice-preference-toggle'),
                  value: 'system-voice',
                  checked: _preferSystemVoice,
                  child: const Text('Use the system voice'),
                ),
              // The model gate (ADR-0008; generalized to any pair,
              // Campaign 8 "Babel widens"): offered only once at least
              // one target pair for this work's source language is
              // actually downloaded, and only over the canonical
              // English text — hidden under the existing mt language
              // swap. "Translate…" opens a picker (there is no longer a
              // SINGLE fixed target — see [_openTranslatePicker]).
              if (_availableTargets.isNotEmpty &&
                  _activeLang == null &&
                  _translationJob == null)
                const PopupMenuItem(
                    key: Key('translate-action'),
                    value: 'translate',
                    child: Text('Translate…')),
              // Gated on stored rows actually existing, not just on a
              // target having been chosen: setActiveTranslationLang runs
              // BEFORE the batch completes (so the progress card can show
              // immediately), so an active lang with zero translated rows
              // — a fresh pick mid-run, or a batch cancelled at zero — must
              // not offer a control with nothing behind it (no dead
              // settings).
              if (_hasStoredTranslation && _activeLang == null)
                CheckedPopupMenuItem<String>(
                  key: const Key('show-translation-toggle'),
                  value: 'show-translation',
                  checked: _showTranslation,
                  child: Text(
                      'Show ${languageDisplayName(_activeTranslationLang!)}'),
                ),
              // Speak-in-⟨language⟩ (ADR-0008 Phase 4, generalized): only
              // meaningful once Show ⟨language⟩ is already on — the same
              // stored sentences it displays are what this speaks.
              if (_showTranslation &&
                  _hasStoredTranslation &&
                  _activeLang == null)
                CheckedPopupMenuItem<String>(
                  key: const Key('speak-translation-toggle'),
                  value: 'speak-translation',
                  checked: _speakTranslation,
                  child: Text(
                      'Speak in ${languageDisplayName(_activeTranslationLang!)}'),
                ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (_translationJob != null) _translationProgressCard(),
          // Natural-height, not an AppBar.bottom fixed slot — see
          // _recapOfferBar's own doc comment for why. Only once there is
          // real content to catch up on, matching the switch's own
          // content branch below.
          if (widget.offerRecap &&
              !_recapOfferDismissed &&
              doc != null &&
              doc.words.isNotEmpty)
            _recapOfferBar(context),
          if (_audioFollowable) _followAudioChip(),
          Expanded(
            // Campaign 9 Phase 7: a user-DRAG scroll detaches following —
            // `dragDetails` is non-null only on an update the user's own
            // finger produced, never on a programmatic call (this
            // screen's own `ensureVisible`, or the sliver settling after
            // a mode switch), so [_followAlongScroll]'s own scrolling
            // never fights this listener.
            child: NotificationListener<ScrollUpdateNotification>(
              onNotification: (n) {
                if (n.dragDetails != null) _detachAudioFollow();
                return false;
              },
              child: switch (doc) {
                null => const Center(child: CircularProgressIndicator()),
                core.TokenizedDocument(words: []) => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('Nothing to read in this one yet.',
                          style: Theme.of(context).textTheme.bodyLarge,
                          textAlign: TextAlign.center),
                    ),
                  ),
                _ => switch (_mode) {
                    ReaderMode.rsvp => _rsvpBody(doc),
                    ReaderMode.scroll => _scrollBody(doc),
                    ReaderMode.lines => _linesBody(doc),
                  },
              },
            ),
          ),
        ],
      ),
    );
  }

  /// "Following audio" / "Resume following" — visible exactly while there
  /// is something to follow ([_audioFollowable]), tappable in both
  /// states: on, it detaches by the same hand a manual seek would; off
  /// (a manual interaction already won), it reattaches.
  Widget _followAudioChip() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Align(
          alignment: Alignment.centerLeft,
          child: ActionChip(
            key: const Key('follow-audio-chip'),
            avatar: Icon(_followingAudio
                ? Icons.graphic_eq
                : Icons.headphones_outlined),
            label:
                Text(_followingAudio ? 'Following audio' : 'Resume following'),
            onPressed:
                _followingAudio ? _detachAudioFollow : _attachAudioFollow,
          ),
        ),
      );

  /// The batch's own calm progress banner (ADR-0008 "Babel" Phase 3) — one
  /// card while translating, mirroring `job_cards.dart`'s status/progress/
  /// button shape without pulling in its river-level coordinator, since
  /// this run is scoped to one work already open in front of the reader.
  Widget _translationProgressCard() {
    final s = _translationJob!.state;
    final total = s.totalUnits;
    return Card(
      key: const Key('translation-progress'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                (() {
                  final label = languageDisplayName(
                      _activeTranslationLang ?? '');
                  return total == 0
                      ? 'Translating to $label…'
                      : 'Translating to $label — ${s.doneUnits} of $total sentences';
                })(),
                key: const Key('translation-status'),
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            LinearProgressIndicator(
                value: total == 0 ? null : s.doneUnits / total),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  key: const Key('translation-cancel'),
                  onPressed: _cancelTranslation,
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        ),
      ),
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
              // Holding the shown word opens the definition sheet, which
              // is also how it reaches the word ledger now (sentinels
              // stand for whole segments — nothing wordy to look up
              // there).
              onLongPress: doc.segments.containsKey(_wordIdx)
                  ? null
                  : () => _openDefinitionSheet(doc.words[_wordIdx]),
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
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // The guide + ticks are classic mode only (donor
                  // index.html: `guide.style.display=isC?"":"none"`).
                  if (!_parafoveal) ..._rsvpGuide(),
                  Center(
                      child: _parafoveal
                          ? _parafovealRow(doc)
                          : _rsvpWord(doc)),
                ],
              ),
            ),
          ),
          _rsvpControls(doc),
        ],
      ),
    );
  }

  /// The classic-mode guide line + tick marks (donor index.html:177-179,
  /// 811-812): a quiet vertical affordance at the display's horizontal
  /// center, independent of the pivot's own (reserved, not perfectly
  /// pinned — see [orpBeforeReserve]) position. Theme-aware via the
  /// fleet's own hearth tokens, matching the donor's `--oh-hearth-300` /
  /// `--oh-interactive` custom properties.
  List<Widget> _rsvpGuide() => [
        Positioned.fill(
          child: IgnorePointer(
            child: Center(
              child: Container(
                key: const Key('rsvp-guide'),
                width: 1,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      OhColors.hearth300.withValues(alpha: 0.5),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 12,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: Center(
              child: Container(
                key: const Key('rsvp-tick-top'),
                width: 10,
                height: 1.5,
                decoration: BoxDecoration(
                    color: kPivotColor,
                    borderRadius: BorderRadius.circular(1)),
              ),
            ),
          ),
        ),
        Positioned(
          bottom: 12,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: Center(
              child: Container(
                key: const Key('rsvp-tick-bottom'),
                width: 10,
                height: 1.5,
                decoration: BoxDecoration(
                    color: kPivotColor,
                    borderRadius: BorderRadius.circular(1)),
              ),
            ),
          ),
        ),
      ];

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
    final before = word.substring(0, orp);
    final after = orp < word.length ? word.substring(orp + 1) : '';
    // The ORP anchor fix (Campaign 4 Phase 2, donor index.html:2662-2666):
    // the before-pivot span reserves a MINIMUM width (orpBeforeReserve) so
    // two words sharing an ORP bucket (see orpIndex) render with the same
    // before-span width regardless of their actual glyphs — the jitter
    // fix [orpBeforeReserve]'s own doc comment is honest about, no more.
    final fontSize = style?.fontSize ?? 34;
    final charWidth = fontSize * 0.6;
    final reserve = orpBeforeReserve(word, charWidth);
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
            ConstrainedBox(
              constraints: BoxConstraints(minWidth: reserve),
              child: Text(before,
                  key: const Key('rsvp-bef'),
                  textAlign: TextAlign.right,
                  style: style),
            ),
            SizedBox(
              width: charWidth,
              child: Text(pivot,
                  key: const Key('rsvp-piv'),
                  textAlign: TextAlign.center,
                  style: style?.copyWith(color: kPivotColor)),
            ),
            Text(after, key: const Key('rsvp-aft'), style: style),
          ],
        ),
      ),
    );
  }

  /// Parafoveal mode (Campaign 4 Phase 2, donor "ticker" — renamed to
  /// avoid colliding with this app's own RSVP test vocabulary): the focus
  /// word's neighbors stay visible, faded by a Gaussian opacity falloff
  /// (donor index.html:2674-2699). Reuses `_wordIdx`/`_step()` wholesale —
  /// no separate cursor or dwell logic, so punctuation-pause lengthening
  /// comes free.
  Widget _parafovealRow(core.TokenizedDocument doc) {
    final theme = Theme.of(context);
    final style =
        theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w600);
    final focusSize = style?.fontSize ?? 34;

    Widget side(List<Widget> children) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          child: Row(mainAxisSize: MainAxisSize.min, children: children),
        );

    Widget neighbor(int d) {
      final wi = _wordIdx + d;
      if (wi < 0 || wi >= doc.words.length) {
        return const SizedBox.shrink();
      }
      final text = doc.words[wi];
      final dist = d.abs();
      final opacity = gaussianOpacity(dist, _sigma);
      final scale = gaussianScale(dist, _sigma);
      final blur = gaussianBlurRadius(dist, _sigma);
      Widget word =
          Text(text, style: style?.copyWith(fontSize: focusSize * 0.82));
      if (blur > 0) {
        word = ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: word);
      }
      return Opacity(
        key: Key('parafoveal-neighbor-$d'),
        opacity: opacity,
        child: Transform.scale(
          scale: scale,
          child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7),
              child: word),
        ),
      );
    }

    final left = [
      for (var d = -_parafovealWinSize; d < 0; d++) neighbor(d)
    ];
    final right = [
      for (var d = 1; d <= _parafovealWinSize; d++) neighbor(d)
    ];

    final word = doc.words[_wordIdx];
    Widget center;
    if (doc.segments.containsKey(_wordIdx)) {
      center = Text(word,
          key: const Key('parafoveal-center'),
          style: style?.copyWith(
              fontStyle: FontStyle.italic, color: theme.colorScheme.secondary));
    } else {
      final orp = orpIndex(word);
      final before = word.substring(0, orp);
      final pivot = orp < word.length ? word[orp] : '';
      final after = orp < word.length ? word.substring(orp + 1) : '';
      center = Text.rich(
        TextSpan(children: [
          TextSpan(text: before, style: style),
          TextSpan(text: pivot, style: style?.copyWith(color: kPivotColor)),
          TextSpan(text: after, style: style),
        ]),
        key: const Key('parafoveal-center'),
      );
    }

    // The donor's 1fr-auto-1fr grid (index.html:186): both sides get equal
    // flexible space, right/left-aligned respectively, so the center
    // word's position stays fixed regardless of how many neighbors fit.
    return Row(
      children: [
        Expanded(child: Align(alignment: Alignment.centerRight, child: side(left))),
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10), child: center),
        Expanded(child: Align(alignment: Alignment.centerLeft, child: side(right))),
      ],
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
          if (_parafoveal) ...[
            const SizedBox(height: 4),
            Slider(
              key: const Key('sigma-slider'),
              min: 0.8,
              max: 4.0,
              divisions: 16,
              value: _sigma,
              label: 'sigma ${_sigma.toStringAsFixed(1)}',
              onChanged: (v) => setState(() => _sigma = v),
            ),
            // C7 (fleet_conformance_test.dart): the bundled Lora/Nunito
            // cmaps don't cover σ, so this stays spelled out rather than
            // tofu on a device without a system fallback for it.
            Text('Focus sigma — higher = neighbors stay brighter',
                style: Theme.of(context).textTheme.labelSmall),
          ],
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton.filled(
                key: const Key('play-toggle'),
                iconSize: 36,
                tooltip: _playing ? 'Pause' : 'Play',
                // Campaign 9 Phase 0: OhTheme's app-wide
                // `ThemeData.iconTheme` sets color: primary — the same
                // color this button fills its own background with — so
                // an unstyled IconButton.filled paints its glyph
                // invisibly on top of itself (the device report's "blank
                // circles"). Pin the high-contrast onPrimary token
                // explicitly rather than let it fall through to the
                // ambient theme.
                style: IconButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.onPrimary),
                onPressed: _playing ? _pause : _play,
                icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
              ),
              const SizedBox(width: 12),
              IconButton.outlined(
                key: const Key('parafoveal-toggle'),
                iconSize: 28,
                tooltip: _parafoveal ? 'Classic mode' : 'Parafoveal mode',
                onPressed: () => setState(() => _parafoveal = !_parafoveal),
                icon: Icon(_parafoveal ? Icons.blur_off : Icons.blur_on),
              ),
            ],
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
    // Campaign 4 Phase 2 follow-along: the shared cursor (_wordIdx) is
    // already advancing under _play()/_step() exactly as RSVP drives it —
    // this is the only piece RSVP never needed: keeping the viewport
    // following it. Reused from karaoke_screen.dart's own
    // _followPlayback idiom (there was no auto-scroll anywhere in this
    // file before this).
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _followAlongScroll(cursorAt(doc, _wordIdx).segment));
    // The print measure (proposal-2 §12): on wide screens the page sets as
    // a centered column rather than sprawling wall to wall — 680dp unless
    // the profile's typography prefs (Campaign 4 Phase 1) say otherwise.
    return Center(
      child: ConstrainedBox(
        key: const Key('print-column'),
        constraints: BoxConstraints(maxWidth: _typography.maxTextWidth),
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
        final translation =
            _showTranslation ? _translationBelow(block, theme) : null;
        child = translation == null
            ? Text(block.text,
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(block.text,
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  translation,
                ],
              );
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

    // Generous print margins (proposal-2 §12), widened vertically by the
    // profile's paragraph-spacing preference (Campaign 4 Phase 1) on top
    // of the reader's 8dp base.
    //
    // KeyedSubtree carries follow-along's GlobalKey WITHOUT displacing the
    // Container's own pinned ValueKey (`segment-tile-$blockPos`, looked up
    // by value in existing tests) — Scrollable.ensureVisible needs a
    // GlobalKey's currentContext, and a widget can only own one Key.
    return KeyedSubtree(
      key: _segKeys.putIfAbsent(blockPos, GlobalKey.new),
      child: Container(
        key: Key('segment-tile-$blockPos'),
        padding: EdgeInsets.symmetric(
            horizontal: 24, vertical: 8 + _typography.paragraphSpacing),
        color: isCurrent ? theme.colorScheme.surfaceContainerHighest : null,
        child: child,
      ),
    );
  }

  /// Follow-along's own half of the shared cursor (see [_scrollBody]'s doc
  /// comment): once per segment the cursor newly enters, while [_playing]
  /// and in a scroll-family mode (Scroll, or Lines as of Campaign 9 Phase
  /// 6 — RSVP has its own dedicated full-screen display, nothing to
  /// scroll), scroll it into view — karaoke_screen.dart's own
  /// `_followPlayback` idiom (`ensureVisible`, alignment 0.3, 300ms).
  void _followAlongScroll(int segment) {
    if (!_playing || _mode == ReaderMode.rsvp) return;
    if (segment == _lastFollowedSegment) return;
    _lastFollowedSegment = segment;
    final ctx = _segKeys[segment]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(ctx,
        alignment: 0.3, duration: const Duration(milliseconds: 300));
  }

  // ───── Lines (Campaign 9 Phase 6: "a third way to read") ─────

  /// Same shape as [_scrollBody] (the print column, the split-around-an-
  /// anchor [CustomScrollView], follow-along's post-frame callback) — a
  /// deliberate near-duplicate rather than a parameterized shared method:
  /// [_scrollBody] sits inside Babel's own heavily-edited region of this
  /// file, and a new top-level mode is exactly the kind of change the
  /// dispatch note asks to land as a new method rather than an in-place
  /// rewrite of a rebase hotspot.
  Widget _linesBody(core.TokenizedDocument doc) {
    const centerKey = ValueKey('lines-center');
    final blocks = _blocks!;
    final anchor = _scrollAnchor.clamp(0, blocks.length - 1);
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _followAlongScroll(cursorAt(doc, _wordIdx).segment));
    return Center(
      child: ConstrainedBox(
        key: const Key('lines-print-column'),
        constraints: BoxConstraints(maxWidth: _typography.maxTextWidth),
        child: CustomScrollView(
          center: centerKey,
          anchor: 0.15,
          slivers: [
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (_, i) => _linePacedTile(doc, anchor - 1 - i),
                childCount: anchor,
              ),
            ),
            SliverList(
              key: centerKey,
              delegate: SliverChildBuilderDelegate(
                (_, i) => _linePacedTile(doc, anchor + i),
                childCount: blocks.length - anchor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A prose block renders through [LinePacedBlock] (the one-visual-line
  /// highlight, no clock of its own — see that file's doc comment); every
  /// other block kind (heading, code, table, figure) reuses [_segmentTile]
  /// completely unchanged, since Lines mode has nothing new to say about
  /// them. [_segKeys] is the SAME map [_segmentTile] populates — one
  /// follow-along GlobalKey per block position regardless of which mode
  /// built the tile, so [_followAlongScroll] never needs to know which
  /// mode is currently active to find it.
  Widget _linePacedTile(core.TokenizedDocument doc, int blockPos) {
    final blocks = _blocks!;
    final block = blocks[blockPos];
    if (block.kind != core.SegmentKind.prose) {
      return _segmentTile(doc, blockPos);
    }

    final start = doc.blockStartWordIdx[blockPos];
    final end = blockPos + 1 < doc.blockStartWordIdx.length
        ? doc.blockStartWordIdx[blockPos + 1]
        : doc.words.length;
    final theme = Theme.of(context);
    final bodySize = theme.textTheme.bodyLarge?.fontSize;
    final style = theme.textTheme.bodyLarge!.copyWith(
        fontFamily: readerTypefaceFontFamily(_typography.typeface),
        height: _typography.lineHeight,
        fontSize: bodySize == null ? null : bodySize * _typography.fontScale);
    final cursor = cursorAt(doc, _wordIdx);
    final localIdx = cursor.segment == blockPos ? cursor.word : -1;

    return KeyedSubtree(
      key: _segKeys.putIfAbsent(blockPos, GlobalKey.new),
      child: Container(
        key: Key('segment-tile-$blockPos'),
        padding: EdgeInsets.symmetric(
            horizontal: 24, vertical: 8 + _typography.paragraphSpacing),
        child: LinePacedBlock(
          words: doc.words.sublist(start, end),
          style: style,
          currentLocalWordIdx: localIdx,
        ),
      ),
    );
  }

  /// The untranslated path stays exactly what it always was — a single
  /// [Wrap] of every word in the block — whether or not Show ⟨language⟩
  /// is on for a block with nothing translated in it
  /// (reader_print_test.dart pins this shape).
  Widget _proseWrap(core.TokenizedDocument doc, int blockPos) {
    final blocks = _blocks!;
    final block = blocks[blockPos];
    final start = doc.blockStartWordIdx[blockPos];
    final end = blockPos + 1 < doc.blockStartWordIdx.length
        ? doc.blockStartWordIdx[blockPos + 1]
        : doc.words.length;
    final theme = Theme.of(context);
    // The print body (proposal-2 §12): the profile's typeface (Lora by
    // default) at its chosen line height and font scale.
    final bodySize = theme.textTheme.bodyLarge?.fontSize;
    final base = theme.textTheme.bodyLarge?.copyWith(
        fontFamily: readerTypefaceFontFamily(_typography.typeface),
        height: _typography.lineHeight,
        fontSize: bodySize == null ? null : bodySize * _typography.fontScale);

    if (!_showTranslation) return _wordWrap(doc, start, end, base, theme);

    // Dual display (ADR-0008 "Babel"; generalized Campaign 8): one row
    // per ENGLISH sentence — its own word range's [Wrap], unchanged,
    // immediately followed by its translated line where the store
    // actually has one. sentence boundaries come from the SAME
    // `core.splitSentences(block.text)` call sentenceUnitsOf uses, so a
    // row's index here always means the row TranslationJobController
    // wrote.
    final sentences = core.splitSentences(block.text);
    if (sentences.isEmpty) return _wordWrap(doc, start, end, base, theme);
    final rows = <Widget>[];
    for (var i = 0; i < sentences.length; i++) {
      final sStart = start + sentences[i].firstWordIdx;
      final sEnd =
          i + 1 < sentences.length ? start + sentences[i + 1].firstWordIdx : end;
      rows.add(_wordWrap(doc, sStart, sEnd, base, theme));
      final translated = translatedTextFor(
          stored: _translatedSentences,
          segIdx: block.idx,
          sentenceIdx: i,
          currentSourceText: sentences[i].text);
      if (translated != null) {
        rows.add(_translatedLine(translated, theme,
            key: Key('translation-${block.idx}-$i')));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  /// One block's word range as a plain flowing [Wrap] — the ENTIRE
  /// pre-Babel `_proseWrap` body, unchanged, so the untranslated path's
  /// widget tree stays byte-identical.
  Widget _wordWrap(core.TokenizedDocument doc, int start, int end,
      TextStyle? base, ThemeData theme) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      // Ragged-right by default; justified distributes each line's words
      // across the full measure INCLUDING the last line (this is a
      // per-word Wrap, not Flutter's TextAlign.justify, which special-
      // cases the last line — the honest ceiling ADR-0010 records).
      alignment:
          _typography.justified ? WrapAlignment.spaceBetween : WrapAlignment.start,
      // The drop-cap word stands taller than its run; bottom-aligning keeps
      // the rest of the line sitting on (near) its baseline.
      crossAxisAlignment: WrapCrossAlignment.end,
      children: [
        for (var w = start; w < end; w++)
          GestureDetector(
            onTap: () => _seekToWord(w),
            onLongPress: () => _openDefinitionSheet(doc.words[w]),
            child: _flowWord(doc, w, base, theme),
          ),
      ],
    );
  }

  /// The translated line's own quiet style — subordinate to the
  /// original, the same italic-body idiom [_segmentTile] already uses
  /// for a figure caption (its own kind of secondary text under a
  /// primary element).
  Widget _translatedLine(String text, ThemeData theme, {Key? key}) => Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 6),
        child: Text(text,
            key: key,
            style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'Lora',
                fontStyle: FontStyle.italic,
                color: theme.colorScheme.onSurfaceVariant)),
      );

  /// Every translated sentence in a HEADING block, one line each — headings
  /// render as a single opaque [Text] (no per-word Wrap), so there is no
  /// row to interleave into; the translation(s) sit below the whole title
  /// instead. Null when nothing in this block is translated.
  Widget? _translationBelow(core.Segment block, ThemeData theme) {
    final sentences = core.splitSentences(block.text);
    final lines = <Widget>[];
    for (var i = 0; i < sentences.length; i++) {
      final translated = translatedTextFor(
          stored: _translatedSentences,
          segIdx: block.idx,
          sentenceIdx: i,
          currentSourceText: sentences[i].text);
      if (translated != null) {
        lines.add(_translatedLine(translated, theme,
            key: Key('translation-${block.idx}-$i')));
      }
    }
    if (lines.isEmpty) return null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: lines);
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
