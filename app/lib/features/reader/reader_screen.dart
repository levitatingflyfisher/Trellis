import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:brain_wiring/brain_wiring.dart' show BrainTier;
import 'package:drift/drift.dart' show TableUpdate, TableUpdateQuery;
import 'package:flutter/foundation.dart' show kIsWeb;
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
import '../models/consent.dart';
import '../models/format.dart';
import '../models/model_store.dart';
import '../player/media_item_mapping.dart';
import '../player/mini_player_host.dart';
import '../player/playback_session.dart';
import '../player/player_controller.dart';
import '../transcribe/transcript_so_far.dart';
import '../transcribe/transcript_writer.dart' show decodeWordTimingBlob;
import '../study/card_editing.dart' show CardDraft, clozeFromSentence;
import '../study/card_editor_screen.dart';
import '../study/card_images.dart' show CardPictures;
import '../study/card_store.dart' show addToMyCards;
import 'dictionary_sheet.dart';
import 'ledger_screen.dart';
import 'line_paced_view.dart';
import 'reader_code_face.dart';
import '../works/device_hooks.dart' show openExternalLink;
import '../works/link_confirm.dart';
import 'reader_logic.dart';
import 'reader_prefs.dart';
import '../settings/reading_settings.dart';
import 'recap_sheet.dart';
import '../player/speed_control.dart';
import 'speech/just_audio_speech_queue.dart';
import 'speech/speech_audio_queue.dart';
import 'speech/speech_engine.dart';
import 'speech/speech_playback_pipeline.dart';
import 'speech/speech_temp_files.dart';
import 'speech/spoken_text.dart';
import 'speech/read_aloud_voices.dart';
import 'translation/brain_translator.dart';
import 'translation/language_names.dart';
import 'translation/sentence_units.dart';
import 'translation/translation_job.dart';
import 'translation/translation_route.dart';
import 'translation/translation_service.dart';

/// A sentence the opener puts at the top of the reader, with at most one
/// action (board-0130): reading a translation of an episode says whether
/// that language has audio, and offers the tap that makes or plays it.
class ReaderNote {
  final String text;

  /// The action's words; null for a note with no action.
  final String? action;

  /// Run with the reader's own context, so what it says shows there.
  final Future<void> Function(BuildContext context)? onAction;

  const ReaderNote(this.text, {this.action, this.onAction});
}

/// The hearth red — the heritage ORP pivot color carried from both donors,
/// which is the fleet's own hearth500 (C1: from the tokens, not retyped).
const Color kPivotColor = OhColors.hearth500;

/// Campaign 9 Phase 6 ("a third way to read") adds [lines] as a genuine
/// third top-level mode alongside the original two — a scroll-family view
/// (see [_linesBody]) highlighting one VISUAL LINE at a time rather than
/// one word ([rsvp]) or nothing beyond the current segment ([scroll]).
enum ReaderMode { rsvp, scroll, lines }

/// The mode picker's public label (1.5.5 user ruling: two modes, RSVP
/// and Page; "three screens for 'read this text' is insane"). Scroll and
/// Lines are both Page; what differs is Page's highlight, see
/// [pageHighlightLabel]. No highlight label reuses a mode's name.
String readerModeLabel(ReaderMode m) => switch (m) {
      ReaderMode.rsvp => 'RSVP',
      ReaderMode.scroll || ReaderMode.lines => 'Page',
    };

String readerModeDescription(ReaderMode m) => switch (m) {
      // The user's wording; the house copy rule forbids a spaced em dash.
      ReaderMode.rsvp => 'Rapid serial visual presentation: one word at a '
          'time, eyes still (foveal reading).',
      ReaderMode.scroll ||
      ReaderMode.lines =>
        'The whole text, lit as it is read or heard.',
    };

/// Page's highlight: Follow along (word by word, the default) or Line.
String pageHighlightLabel(ReaderMode m) => switch (m) {
      ReaderMode.lines => 'Line',
      _ => 'Follow along',
    };

String pageHighlightDescription(ReaderMode m) => switch (m) {
      ReaderMode.lines => 'Lights one line of text at a time.',
      _ => 'Lights each word as it is spoken.',
    };

/// Both's rhythm (1.5.9: "the reading layout spacing is horrible"): a
/// translation sits [kTranslationGapAbove] under its own sentence, and the
/// next sentence stands [kTranslationGapBelow] clear of it, so each pair
/// reads as one, apart from the next and still closer than a paragraph.
/// The line height is pinned because the translation's script often falls
/// back to a system font, whose own default leading differs.
const double kTranslationGapAbove = 4;
const double kTranslationGapBelow = 12;
const double kTranslationLineHeight = 1.5;

IconData readerModeIcon(ReaderMode m) => switch (m) {
      ReaderMode.rsvp => Icons.center_focus_strong,
      ReaderMode.scroll || ReaderMode.lines => Icons.article_outlined,
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

  /// Translation (1.5.5): every language this work can go into, what
  /// each costs to download, the download, and the models. Null (the web
  /// tier) hides Translate.
  final TranslationService? translation;

  /// Campaign 4 Phase 4: true when this work was reopened untouched for
  /// more than 3 UTC days with real progress already made
  /// ([shouldOfferRecap], resolved by the caller from [Positions]/segment
  /// count — the same "resolved before the push" shape [offerNeuralVoice]
  /// already uses, so this widget's own tests stay a plain bool). Shows a
  /// dismissible "Catch me up?" chip; false (every existing call site)
  /// shows nothing.
  final bool offerRecap;

  /// Opens at this segment instead of the saved place (a search hit).
  /// The saved place is left alone until the reader moves from here, so
  /// a look at a match never costs the reader where they were.
  final int? startSegmentIdx;

  /// The work page (1.5.4) opens the reader already doing what was
  /// asked: [startSpeaking] reads aloud from the saved place,
  /// [speakTranslation] speaks the active translation instead of the
  /// original, [layerLang] projects that `mt` layer, and
  /// [openTranslatePicker] asks which language to translate into. Each
  /// applies once, on the first load; none is remembered.
  final bool startSpeaking;
  final bool speakTranslation;
  final String? layerLang;
  final bool openTranslatePicker;

  /// Opens on Page even if RSVP was last used: the door from a transcribed
  /// episode's Read and from the player.
  final bool openOnPage;

  /// Shown at the top until dismissed; null for none.
  final ReaderNote? note;

  /// Opens a link met in the text, once the reader agreed (1.6.2). The
  /// browser by default; tests stand in for it.
  final Future<void> Function(Uri uri) openLink;

  /// The media session read aloud takes while it reads (1.6.0, user: "it
  /// stops when the screen goes dark, I would like it treated just like
  /// media/podcast playing"): the session brings the playback service,
  /// the notification and the lock-screen buttons, and with it read aloud
  /// goes on behind the screen. With none (the web build, tests that
  /// don't ask) read aloud stops when the app leaves the screen, as it
  /// always did, since nothing would keep it alive there.
  final PlaybackSession session;

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
      this.translation,
      this.offerRecap = false,
      this.startSegmentIdx,
      this.startSpeaking = false,
      this.speakTranslation = false,
      this.layerLang,
      this.openTranslatePicker = false,
      this.openOnPage = false,
      this.note,
      this.openLink = openExternalLink,
      this.session = const NoPlaybackSession()});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with WidgetsBindingObserver {
  List<core.Segment>? _blocks;
  core.TokenizedDocument? _doc;

  /// The cursor, written through [_wordIdx], which stamps a real move; a
  /// load or a re-projection (the same place in other text) sets this
  /// field alone.
  int _cursorIdx = 0;

  /// When the cursor last really moved (wall clock, the database's own
  /// stamp), or the saved row's stamp when a load put it there. Every
  /// save carries it, so a cursor left alone never lands over a place the
  /// player saved since (1.5.9: follow off, the app sent to the
  /// background, a kill, and the episode resumed where the reader opened).
  int _cursorAtMs = 0;

  int get _wordIdx => _cursorIdx;
  set _wordIdx(int idx) {
    if (idx != _cursorIdx) _cursorAtMs = DateTime.now().millisecondsSinceEpoch;
    _cursorIdx = idx;
  }

  /// Where a search hit opened the reader; null otherwise. Saving waits
  /// until the cursor leaves it (see [ReaderScreen.startSegmentIdx]).
  int? _hitWordIdx;

  /// Whether [ReaderScreen.startSegmentIdx] still applies to a load.
  bool _startPending = true;

  /// A transcript still being made (1.6.9): how far it has got, for the
  /// line at the top; null when the transcript is whole.
  TranscriptMaking? _making;

  /// Writes to this work's transcript and its job, while a transcript
  /// is made under the open page.
  StreamSubscription<Set<TableUpdate>>? _transcriptWrites;

  /// The alignments the page was last loaded with, as (count, end): a
  /// write that changes them brings new text.
  (int, int) _loadedAligned = (0, 0);

  /// New text arrived while the page was busy (reading on, speaking, a
  /// translation shown); it is put in when the page is still again.
  bool _transcriptStale = false;
  bool _reloadingTranscript = false;

  /// Whether the work page's entry request (speak, a layer, the picker)
  /// is still to be carried out: once, after the first load.
  bool _entryPending = true;
  ReaderMode _mode = ReaderMode.rsvp;

  /// Page's last highlight, so RSVP then Page comes back to it.
  ReaderMode _pageMode = ReaderMode.scroll;
  int _scrollAnchor = 0; // segment the scroll view opens around

  /// Campaign 4 Phase 2 follow-along: one [GlobalKey] per built segment
  /// tile, lazily populated by [_segmentTile] (only tiles the sliver has
  /// actually built get an entry).
  final Map<int, GlobalKey> _segKeys = {};

  /// Dedupes [_followAlongScroll] so it only calls `ensureVisible` once
  /// per segment the cursor enters, not once per rebuild.
  int _lastFollowedSegment = -1;

  /// The lit word on Follow along, so the page can keep its line in view
  /// inside a long segment ([_keepCursorWordInView]).
  final GlobalKey _cursorWordKey = GlobalKey();

  /// True while the page is moving itself to follow; a check in the
  /// meantime would restart the motion every frame.
  bool _followScrolling = false;
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

  /// The neighbor-fade sigma, shown as "Focus spread" (donor default 2.0,
  /// slider 0.8-4.0 step 0.2). Remembered per reader with the mode, [_wpm]
  /// and [_parafoveal] (ReaderSession in reader_prefs.dart).
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

  /// Whether read aloud says citations, footnote marks and bare links
  /// (1.6.0). Off until chosen: the voice skips them and the page keeps
  /// them ([spokenText]). A device setting, read in [_load].
  bool _speakCitations = false;

  SpeechAudioQueue? _queueHolder;
  SpeechAudioQueue get _queue => _queueHolder ??= _openSpeechQueue();
  StreamSubscription<SpeechInterruption>? _speechInterruptions;

  /// A call, an alarm or pulled headphones stopped read aloud (set only
  /// when it was speaking). Any start or stop by hand clears it, so the
  /// end of the call never overrides the reader.
  bool _resumeAfterInterruption = false;

  SpeechAudioQueue _openSpeechQueue() {
    final queue =
        (widget.createSpeechAudioQueue ?? JustAudioSpeechQueue.new)();
    _speechInterruptions =
        queue.interruptionStream.listen(_onSpeechInterruption);
    return queue;
  }

  SpeechPlaybackPipeline? _pipelineHolder;

  /// The current synthesis run's flat unit list and the `_speakGen` it
  /// belongs to — [SpeechPlaybackPipeline]'s callbacks are bound ONCE (the
  /// pipeline itself is reused across runs), so they read these MUTABLE
  /// fields rather than closing over a single run's locals; the `_synthGen`
  /// check is `_speakGen`'s own fencing law, carried one level lower
  /// (mirrors the utterance path's `gen == _speakGen` check in `live()`,
  /// on top of — not instead of — the pipeline's own internal fencing).
  List<_SpeechUnit> _synthUnits = const [];
  int _synthGen = 0;

  /// Read aloud's voice per language ([ReaderPrefs.voices]), loaded in
  /// [_load] and changed in the voices sheet.
  Map<String, String> _voiceChoices = const {};

  /// The current run reads on the phone's voices (not the downloaded
  /// one), so a speed change goes to them.
  bool _runOnSystemVoice = false;

  /// Read aloud is saying a translation under its original (Both), so
  /// that translation's line is what lights.
  bool _voicingTranslation = false;

  /// Whether the translation of the sentence at words [start, end) lights:
  /// while it is heard, or (not reading aloud) while the cursor or the
  /// audio is in its sentence.
  bool _translationLit(int start, int end) =>
      _wordIdx >= start &&
      _wordIdx < end &&
      (!_speaking || _voicingTranslation);

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
  /// alignments as a [core.Spine], resolved
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
  /// itself), so a pause never raises "Back to audio".
  bool _followingAudio = false;

  /// Whisper's per-word stamps, `[word, t0, t1]` by DB segment idx, for
  /// the word-by-word motion the transcript view had (1.5.8). Empty for a
  /// work without them; the word then moves through its segment by length
  /// ([tokenStartTimes]).
  Map<int, List<List<Object>>> _wordTimings = const {};

  /// Polls the playhead every frame while following a playing work. The
  /// player's own position ticks come at most five times a second, which
  /// at 3-4x skips several words between ticks; its position getter is
  /// exact in between, so reading it per frame keeps the lit word on the
  /// voice at any speed.
  Timer? _followPoll;
  bool _onScreen = true;

  /// Bumped to rebuild the Page scroll view around [_scrollAnchor] when
  /// the cursor's tile is too far away to have been built (a lazy sliver
  /// only builds what is near the viewport, so there is nothing for
  /// `ensureVisible` to scroll to).
  int _recenterGen = 0;

  /// Read-aloud's word sweep (1.5.8): moves the lit word through the
  /// sentence being spoken at an estimated pace for the shared speed.
  /// Speech engines report sentence starts, not words, so each start
  /// re-anchors it, and it holds on the sentence's last word rather than
  /// run into the next. [_sweepStart] is that sentence's first word,
  /// where a stop leaves the cursor (ADR-0002).
  Timer? _sweep;
  int? _sweepStart;

  /// The speed last handed to the voice, so a speed change mid-run is
  /// passed on once.
  double? _appliedSpeechSpeed;

  /// The translation store overlay (Campaign 8 "Babel widens" Phase 1,
  /// generalizing ADR-0008 "Babel" Phase 3's fixed-Spanish version) —
  /// deliberately separate from [_activeLang]'s whole-segment mt swap:
  /// this pairs each original sentence with its translation rather than
  /// replacing the text the cursor and every existing test key off. Both
  /// the Translate action and the Show ⟨language⟩ toggle are offered
  /// only while [_activeLang] is null (guards against numbering under a
  /// language-swapped projection, whose own `splitSentences` boundaries
  /// can differ from the English original's).
  TranslationRun? _translationJob;

  /// The legs being downloaded for a translation the reader just picked,
  /// with their progress; null when nothing is downloading.
  ModelDownload? _download;
  ModelDownloadProgress? _downloadProgress;
  String? _downloadLabel;

  /// The one active translation target for this work (`null` = none
  /// chosen yet), mirroring [Works.activeTranslationLang] — "one active
  /// translation layer per work at a time" made literal: picking a new
  /// target REPLACES this, never adds to a set.
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

  /// Under Both, Read aloud reads each sentence and then its translation
  /// (1.5.9; before, "Speak in ⟨language⟩" swapped the translation in,
  /// which is what Translation only now does). On by default, because
  /// Both shows the two; the ⋮ item turns the translation off for this
  /// session, to hear the original alone.
  bool _speakTranslation = true;

  /// Under Both, the ⋮ item that turns [_speakTranslation] off: there once
  /// a translation shows or is being made (its sentences are read as
  /// they arrive).
  bool get _offersSpeakTranslation =>
      _showTranslation &&
      (_hasStoredTranslation || _translationJob != null) &&
      _activeLang == null &&
      !_translationOnly;

  /// A run reads the translation, now or as it arrives: Translation only,
  /// or Both with [_speakTranslation]. Its language is then in the run's
  /// plan even before a translated sentence exists, so a sentence that
  /// arrives mid-run is never read by another language's voice (the web
  /// says yes to any language).
  bool get _readsTranslation =>
      _activeTranslationLang != null &&
      _activeLang == null &&
      _showTranslation &&
      (_hasStoredTranslation || _translationJob != null) &&
      (_translationOnlyActive || _speakTranslation);

  /// The phone's voices, listed once per visit: a list is a platform round
  /// trip (in a browser, up to a second's wait while it loads them). The
  /// voices sheet lists them afresh, so a voice added in Settings shows
  /// once the sheet is opened again. An empty list is never kept: a
  /// browser slower than the speaker's wait may have its voices by the
  /// next press.
  List<SystemVoice>? _phoneVoices;
  bool _phoneVoicesListed = false;

  Future<List<SystemVoice>?> _listVoices({bool fresh = false}) async {
    if (_phoneVoicesListed && !fresh) return _phoneVoices;
    final voices = await _tts.voices();
    _phoneVoices = voices;
    _phoneVoicesListed = voices == null || voices.isNotEmpty;
    return voices;
  }

  /// Translation only (1.5.8, remembered per work in
  /// [Works.translationView]): the translated text in place of the
  /// original, at reading size, in every mode — RSVP, Line and Follow
  /// along all read [_blocks], so the translation becomes what they read.
  /// Off is Both: each translated sentence under its original.
  bool _translationOnly = false;

  /// The original, tokenized once: audio follows its words even while the
  /// page shows a translation.
  core.TokenizedDocument? _origDoc;

  /// Under Translation only, each block's translated sentences' first
  /// words (block-local), by block position: the bridge between a
  /// translated word and the original sentence the audio is in.
  Map<int, List<int>> _projStarts = const {};

  /// The page's current translated sentence, as a global word range, lit
  /// whole while following audio under Translation only: word timings
  /// don't cross languages, sentences do.
  (int, int)? _litSentence;

  /// [_wordSpace]'s memo: Page rebuilds on every word step.
  final Map<(TextStyle?, TextScaler), double> _spaceWidths = {};

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

  /// What the work is written in (1.5.5, [resolveSourceLanguage]): its
  /// own language, else its feed's, else what whisper heard in its
  /// transcript. Null when nobody knows; Translate then asks first, and
  /// never assumes English.
  String? _sourceLang;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.player?.addListener(_onSpeechSpeed);
    final p = widget.player;
    if (p != null) _lastTurn = (id: p.current?.id, playing: p.playing);
    p?.addListener(_onPlayerTurn);
    _load();
    unawaited(_findAnthropic());
    // Only an episode's transcript is made under an open page.
    if (widget.work.sourceUrl != null) {
      _transcriptWrites = widget.db
          .tableUpdates(TableUpdateQuery.onAllTables(
              [widget.db.alignments, widget.db.jobsTable]))
          .listen((_) => unawaited(_onTranscriptWrite()));
    }
  }

  /// A window of the transcript landed, or its job moved on: the line at
  /// the top follows, and new text goes onto the page.
  Future<void> _onTranscriptWrite() async {
    final making = await transcriptMaking(widget.db, widget.work.id);
    final aligned = await widget.db.spineDao.alignmentsOf(widget.work.id);
    if (!mounted) return;
    if (making != _making) setState(() => _making = making);
    if (_alignedShape(aligned.map((a) => a.tEndMs)) != _loadedAligned) {
      await _reloadTranscript();
    }
  }

  /// (count, latest end) of a work's alignments, from their ends.
  static (int, int) _alignedShape(Iterable<int> ends) {
    var count = 0;
    var end = 0;
    for (final e in ends) {
      count++;
      if (e > end) end = e;
    }
    return (count, end);
  }

  /// Reads the page again for the new text and keeps the cursor on the
  /// word it was on. Waits while the page is busy.
  Future<void> _reloadTranscript() async {
    if (_playing ||
        _speaking ||
        _activeLang != null ||
        _translationOnlyActive ||
        _reloadingTranscript) {
      _transcriptStale = true;
      return;
    }
    _transcriptStale = false;
    _reloadingTranscript = true;
    try {
      final doc = _doc;
      final blocks = _blocks;
      (int, int)? at;
      if (doc != null && blocks != null && doc.words.isNotEmpty) {
        final c = cursorAt(doc, _wordIdx);
        at = (blocks[c.segment].idx, c.word);
      }
      final atMs = _cursorAtMs;
      await _load();
      if (!mounted || at == null) return;
      final fresh = _doc;
      final freshBlocks = _blocks;
      if (fresh == null || freshBlocks == null || fresh.words.isEmpty) return;
      final pos = freshBlocks.indexWhere((b) => b.idx == at!.$1);
      if (pos < 0) return;
      final idx = globalWordIndex(fresh, pos, at.$2);
      setState(() {
        _cursorIdx = idx;
        _cursorAtMs = atMs;
        _scrollAnchor = cursorAt(fresh, idx).segment;
      });
    } finally {
      _reloadingTranscript = false;
    }
    if (_transcriptStale && mounted) unawaited(_reloadTranscript());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Campaign 9 Phase 7: safe even if never attached (removeListener
    // no-ops on an unheld listener) — every listener this screen ever
    // adds gets exactly one matching removal on its way out.
    widget.player?.removeListener(_onPlayerTick);
    unawaited(_transcriptWrites?.cancel());
    _followPoll?.cancel();
    _sweep?.cancel();
    widget.player?.removeListener(_onSpeechSpeed);
    widget.player?.removeListener(_onPlayerTurn);
    _timer?.cancel();
    // Silence the voice without creating one: only an already-used speaker
    // needs stopping (fake-async law 1: fire-and-forget, never await here).
    _speakGen++;
    _speaking = false;
    _sessionGone();
    final tts = _ttsHolder;
    if (tts != null) unawaited(tts.stop().catchError((_) {}));
    // The synthesis-path trio, torn down in the same fire-and-forget spirit
    // — never awaited here, but every native/platform handle this screen
    // ever opened gets a dispose() call on its way out.
    final pipeline = _pipelineHolder;
    if (pipeline != null) unawaited(pipeline.dispose().catchError((_) {}));
    unawaited(_speechInterruptions?.cancel());
    final queue = _queueHolder;
    if (queue != null) unawaited(queue.dispose().catchError((_) {}));
    final synthEngine = _synthEngineHolder;
    if (synthEngine != null) unawaited(synthEngine.dispose().catchError((_) {}));
    // Leaving mid-translation stops the run at the next sentence and frees
    // its model, but keeps the run marker: the next open picks it up.
    _translationJob?.stop();
    _download?.cancel();
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
      if (_speaking && _inSession) {
        // In the media session read aloud goes on behind the screen
        // (1.6.0, user: "it stops when the screen goes dark"). Nobody
        // watches the sweep there: the cursor rests at the sentence's
        // start, where a stop would leave it.
        final sentenceStart = _sweepStart;
        _stopSweep();
        if (sentenceStart != null) setState(() => _wordIdx = sentenceStart);
      } else {
        unawaited(_stopSpeak());
      }
      unawaited(_savePosition().catchError((_) {}));
    }
    // The per-frame poll is for eyes on the page: off-screen the podcast
    // plays on, and the player's own ticks keep the cursor close.
    _onScreen = state == AppLifecycleState.resumed;
    _syncFollowPoll();
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
    // One-shot: once the cursor has left the hit, a reload (a language
    // change) goes back to the saved place like any other.
    if (_hitWordIdx != null && _wordIdx != _hitWordIdx) {
      _startPending = false;
      _hitWordIdx = null;
    }
    final start = _startPending ? widget.startSegmentIdx : null;
    if (start != null && doc.words.isNotEmpty) {
      final blockPos = blocks.indexWhere((b) => b.idx == start);
      if (blockPos >= 0) {
        wordIdx = globalWordIndex(doc, blockPos, 0);
        _hitWordIdx = wordIdx;
      }
    } else if (saved != null && doc.words.isNotEmpty) {
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
    final speakCitations =
        await widget.db.deviceSettingsDao.read(speakCitationsKey) == 'on';
    final resolver = widget.resolveSpeechEngine;
    final synthEngine =
        resolver == null ? null : await resolver(lang: workLang);
    // The study crown: only offer "Listen from here" where it can actually
    // start something (an audio source) AND land somewhere meaningful (an
    // alignment to project the cursor through). The same rows also feed
    // Phase 7's [_spine], built once here so [_onPlayerTick] never
    // re-fetches per tick.
    final alignmentRows =
        await widget.db.spineDao.alignmentsOf(widget.work.id);
    final making = widget.work.sourceUrl == null
        ? null
        : await transcriptMaking(widget.db, widget.work.id);
    final hasAlignedAudio =
        widget.work.sourceUrl != null && alignmentRows.isNotEmpty;
    final wordTimings = {
      for (final a in alignmentRows)
        if (a.wordTimings != null)
          a.segmentIdx: decodeWordTimingBlob(a.wordTimings!),
    };
    final spine = alignmentRows.isEmpty
        ? null
        : core.Spine(segments: const [], layers: const [], alignments: [
            for (final a in alignmentRows)
              core.Alignment(
                  segmentIdx: a.segmentIdx,
                  tStartMs: a.tStartMs,
                  tEndMs: a.tEndMs),
          ]);
    // The translation store: which language is active, and its sentences.
    final feedLang =
        await widget.db.feedsDao.languageOfWorkFeed(widget.work.id);
    final transcriptLangs = await widget.db.spineDao
        .layerLangsOf(widget.work.id, kind: 'transcript');
    final sourceLang = resolveSourceLanguage(
        workLang: workLang,
        feedLang: feedLang,
        transcriptLang: transcriptLangs.isEmpty ? null : transcriptLangs.first);
    final activeLang =
        await widget.db.spineDao.activeTranslationLang(widget.work.id);
    final showTranslation =
        await widget.db.spineDao.showTranslationLayer(widget.work.id);
    final translatedSentences = activeLang == null
        ? const <(int, int), TranslationSentence>{}
        : await widget.db.spineDao
            .translationSentencesOf(widget.work.id, lang: activeLang);
    final unfinishedRun =
        await widget.db.spineDao.translationRunLang(widget.work.id);
    final translationOnly =
        await widget.db.spineDao.translationOnly(widget.work.id);
    final readerPrefs = await widget.db.profilesDao.readerPrefs(widget.profileId);
    if (!mounted) return;
    setState(() {
      _original = blocks;
      _mtLangs = mtLangs;
      _mtTexts = mtTexts;
      _activeLang = null;
      _blocks = blocks;
      _doc = doc;
      _cursorIdx = wordIdx;
      _cursorAtMs =
          saved?.updatedAtMs ?? DateTime.now().millisecondsSinceEpoch;
      _scrollAnchor = doc.words.isEmpty ? 0 : cursorAt(doc, wordIdx).segment;
      _preferSystemVoice = preferSystemVoice;
      _speakCitations = speakCitations;
      _synthEngineHolder = synthEngine;
      _hasAlignedAudio = hasAlignedAudio;
      _workLang = workLang;
      _sourceLang = sourceLang;
      _spine = spine;
      _wordTimings = wordTimings;
      _making = making;
      _loadedAligned = _alignedShape(alignmentRows.map((a) => a.tEndMs));
      _activeTranslationLang = activeLang;
      _showTranslation = showTranslation;
      _translatedSentences = translatedSentences;
      _translationOnly = translationOnly;
      _origDoc = doc;
      _projStarts = const {};
      _typography = readerPrefs.typography;
      _voiceChoices = readerPrefs.voices;
      // How this reader last read: mode, speed, nearby words (persona A1:
      // "the reader forgets their settings" was a reason to quit).
      final session = readerPrefs.session;
      _mode = _modeFromWire(session.mode);
      if (_mode != ReaderMode.rsvp) _pageMode = _mode;
      // Read on a transcribed episode, or the player's Page door, opens
      // on Page whatever was last used.
      if (widget.openOnPage && _mode == ReaderMode.rsvp) _mode = _pageMode;
      _wpm = session.wpm;
      _parafoveal = session.nearbyWords;
      _sigma = session.focusSpread;
      if (_mode != ReaderMode.rsvp && doc.words.isNotEmpty) {
        _scrollAnchor = cursorAt(doc, wordIdx).segment;
      }
    });
    // The saved place is the original's; Translation only re-reads the
    // page in translation at the same sentence.
    if (_translationOnlyActive && doc.words.isNotEmpty) {
      final c = cursorAt(doc, wordIdx);
      _applyProjection((
        segment: c.segment,
        sentence: _sentenceAt(_origStarts(c.segment), c.word)
      ));
    }
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
    if (_entryPending) {
      _entryPending = false;
      _applyEntry();
    }
    // A run the system killed (its marker outlived it) carries on.
    if (unfinishedRun != null && _translationJob == null && mounted) {
      unawaited(_resumeTranslation(unfinishedRun));
    }
  }

  void _applyEntry() {
    final layer = widget.layerLang;
    final doc = _doc;
    if (layer != null && doc != null && _mtLangs.contains(layer)) {
      final segment = doc.words.isEmpty ? 0 : cursorAt(doc, _wordIdx).segment;
      final blocks = _projectedBlocks(layer);
      final newDoc = core.tokenizeDocument(blocks);
      setState(() {
        _activeLang = layer;
        _blocks = blocks;
        _doc = newDoc;
        _cursorIdx =
            newDoc.words.isEmpty ? 0 : globalWordIndex(newDoc, segment, 0);
        _scrollAnchor = segment;
      });
    }
    // Listen in the translation (the work page's language choice): the
    // page shows and reads the translation alone for this visit, without
    // changing the work's remembered Both / Translation only.
    if (widget.speakTranslation && _hasStoredTranslation && _activeLang == null) {
      final at = _cursorSentence();
      setState(() {
        _showTranslation = true;
        _translationOnly = true;
      });
      _applyProjection(at);
    }
    if (widget.startSpeaking) _startSpeak();
    if (widget.openTranslatePicker) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_openTranslatePicker());
      });
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
      _cursorIdx = newDoc.words.isEmpty
          ? 0
          : globalWordIndex(newDoc, currentSegment, 0);
      _scrollAnchor = currentSegment;
    });
    if (next == null && _translationOnlyActive) {
      _applyProjection((segment: currentSegment, sentence: 0));
    }
  }

  // ───── Translation only / Both (1.5.8) ─────

  bool get _translationOnlyActive =>
      _translationOnly &&
      _showTranslation &&
      _hasStoredTranslation &&
      _activeLang == null;

  /// Both: translated sentences under their originals.
  bool get _interlinear => _showTranslation && !_translationOnlyActive;

  /// The language the page's words are in, when it isn't the work's.
  String? get _shownLang =>
      _activeLang ?? (_translationOnlyActive ? _activeTranslationLang : null);

  /// Block [blockPos]'s sentence starts (block-local word indices) in the
  /// original.
  List<int> _origStarts(int blockPos) => [
        for (final s in core.splitSentences(_original[blockPos].text))
          s.firstWordIdx
      ];

  /// The same in whatever the page shows now.
  List<int> _shownStarts(int blockPos) => _translationOnlyActive
      ? (_projStarts[blockPos] ?? const [])
      : _origStarts(blockPos);

  static int _sentenceAt(List<int> starts, int local) {
    var i = 0;
    for (var k = 0; k < starts.length; k++) {
      if (starts[k] <= local) i = k;
    }
    return i;
  }

  /// Where the cursor is, as (block, sentence): the same place in any
  /// projection of the text.
  ({int segment, int sentence}) _cursorSentence() {
    final doc = _doc;
    if (doc == null || doc.words.isEmpty) return (segment: 0, sentence: 0);
    final c = cursorAt(doc, _wordIdx);
    return (
      segment: c.segment,
      sentence: _sentenceAt(_shownStarts(c.segment), c.word)
    );
  }

  /// [_original] with each sentence replaced by its stored translation,
  /// and where each translated sentence starts ([translatedProjection]).
  (List<core.Segment>, Map<int, List<int>>) _translatedProjection() =>
      translatedProjection(_original, _translatedSentences);

  /// Re-reads [_blocks] for the current choices, putting the cursor at
  /// the start of the same sentence in the new projection.
  void _applyProjection(({int segment, int sentence}) at) {
    final List<core.Segment> blocks;
    var starts = const <int, List<int>>{};
    if (_activeLang != null) {
      blocks = _projectedBlocks(_activeLang);
    } else if (_translationOnlyActive) {
      (blocks, starts) = _translatedProjection();
    } else {
      blocks = _original;
    }
    final doc = core.tokenizeDocument(blocks);
    setState(() {
      _blocks = blocks;
      _doc = doc;
      _projStarts = starts;
      if (doc.words.isEmpty || blocks.isEmpty) {
        _cursorIdx = 0;
        return;
      }
      final seg = at.segment.clamp(0, blocks.length - 1);
      final shown = _shownStarts(seg);
      _cursorIdx = globalWordIndex(doc, seg,
          shown.isEmpty ? 0 : shown[at.sentence.clamp(0, shown.length - 1)]);
      _scrollAnchor = seg;
      _recenterGen++;
    });
  }

  /// The menu's Translation only / Both: remembered for this work.
  Future<void> _setTranslationOnly(bool only) async {
    if (only != _translationOnly) {
      _pause();
      unawaited(_stopSpeak());
      final at = _cursorSentence();
      _translationOnly = only;
      _applyProjection(at);
    }
    // Written even when the page already shows it: a Listen visit shows
    // Translation only without remembering it, and picking it there is a
    // choice to keep.
    await widget.db.spineDao.setTranslationOnly(widget.work.id, only);
  }

  /// Under Translation only, the original word a shown word stands for:
  /// the first word of its sentence (the audio's words are the
  /// original's). Identity otherwise.
  int _originalWordOf(int globalIdx) {
    final doc = _doc;
    final orig = _origDoc;
    if (!_translationOnlyActive || doc == null || orig == null) {
      return globalIdx;
    }
    final c = cursorAt(doc, globalIdx);
    final si = _sentenceAt(_projStarts[c.segment] ?? const [], c.word);
    final origStarts = _origStarts(c.segment);
    return globalWordIndex(orig, c.segment,
        origStarts.isEmpty ? 0 : origStarts[si.clamp(0, origStarts.length - 1)]);
  }

  /// The inverse of [_originalWordOf], for an audio-driven cursor: the
  /// shown sentence holding original word [origIdx].
  int _shownWordOf(int origIdx) {
    final doc = _doc;
    final orig = _origDoc;
    if (!_translationOnlyActive || doc == null || orig == null) return origIdx;
    final c = cursorAt(orig, origIdx);
    final si = _sentenceAt(_origStarts(c.segment), c.word);
    final shown = _projStarts[c.segment] ?? const [];
    return globalWordIndex(
        doc, c.segment, shown.isEmpty ? 0 : shown[si.clamp(0, shown.length - 1)]);
  }

  /// [_litSentence] for this build.
  (int, int)? _computeLitSentence(core.TokenizedDocument doc) {
    if (!_translationOnlyActive || !_followingAudio || doc.words.isEmpty) {
      return null;
    }
    final c = cursorAt(doc, _wordIdx);
    final starts = _projStarts[c.segment] ?? const [];
    if (starts.isEmpty) return null;
    final si = _sentenceAt(starts, c.word);
    final base = doc.blockStartWordIdx[c.segment];
    return (
      base + starts[si],
      si + 1 < starts.length ? base + starts[si + 1] : _blockEnd(doc, c.segment)
    );
  }

  /// Under Both, the translation of the sentence the cursor is in — what
  /// RSVP shows under its word.
  String? _translationOfCursorSentence() {
    final doc = _doc;
    if (!_interlinear || doc == null || doc.words.isEmpty) return null;
    final c = cursorAt(doc, _wordIdx);
    final block = _blocks![c.segment];
    final sentences = core.splitSentences(block.text);
    if (sentences.isEmpty) return null;
    final si = _sentenceAt([for (final s in sentences) s.firstWordIdx], c.word);
    return translatedTextFor(
        stored: _translatedSentences,
        segIdx: block.idx,
        sentenceIdx: si,
        currentSourceText: sentences[si].text);
  }

  Future<void> _savePosition({String modality = 'read'}) async {
    final doc = _doc;
    final blocks = _blocks;
    if (doc == null || blocks == null || doc.words.isEmpty) return;
    if (_hitWordIdx != null) {
      if (_hitWordIdx == _wordIdx) return;
      _hitWordIdx = null;
      _startPending = false;
    }
    // The saved place is always the original's (under Translation only,
    // the start of the shown sentence's original): Position knows no
    // language (ADR-0002).
    // Mid-sentence while reading aloud (the sweep is an estimate) is
    // the sentence's start, as a stop leaves it.
    final at = _sweepStart ?? _wordIdx;
    final orig = _origDoc;
    final c = _translationOnlyActive && orig != null
        ? cursorAt(orig, _originalWordOf(at))
        : cursorAt(doc, at);
    await widget.db.spineDao.savePosition(
        profileId: widget.profileId,
        workId: widget.work.id,
        segmentIdx: blocks[c.segment].idx,
        wordIdx: c.word,
        lastModality: modality,
        readAtMs: _cursorAtMs);
    // Campaign 4 Phase 5's write side: every position save is proof the
    // cursor actually advanced today, so this is the one honest place to
    // mark a reading day (idempotent — see ReadingDays' own doc comment).
    await widget.db.profilesDao
        .recordReadingDay(widget.profileId, epochDayUtcNow());
  }

  // ───── speak mode (the TtsSpeaker seam; cursor law ADR-0002) ─────

  void _toggleSpeak() {
    _resumeAfterInterruption = false;
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
    if (_pauseAudioThen(_startSpeak, anyWork: true)) return;
    _pause();
    setState(() => _speaking = true);
    _sessionPlaying();
    if (widget.offerNeuralVoice && !_offeredNeuralVoice) {
      _offeredNeuralVoice = true;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
            content: Text('A downloaded voice reads more smoothly. Get '
                'one in Models.')));
    }
    unawaited(_speakLoop());
  }

  Future<void> _stopSpeak() async {
    if (!_speaking) return;
    _speakGen++;
    final sentenceStart = _sweepStart;
    _stopSweep();
    setState(() {
      _speaking = false;
      if (sentenceStart != null) _wordIdx = sentenceStart;
    });
    _sessionPaused();
    await _tts.stop();
    // Only touch the pipeline if speech ever actually created one — never
    // spin up the queue's platform player just to stop it.
    final pipeline = _pipelineHolder;
    if (pipeline != null) await pipeline.stop();
    unawaited(_savePosition(modality: 'speak').catchError((_) {}));
    if (_transcriptStale && mounted) unawaited(_reloadTranscript());
  }

  /// The language the page's own text is in: an mt layer's, else what
  /// the work is written in. Null when nobody knows (the voice's default).
  String? get _sourceSpeechLang =>
      _activeLang ?? _sourceLang ?? _workLang ?? widget.work.lang;

  /// What the downloaded voice reads (ADR-0006/0007): the language it
  /// was resolved for in [_load], and those it speaks; nothing when there
  /// is none or the listener set it aside. Russian, German and Chinese
  /// are never in it: its character table has no Cyrillic or CJK
  /// (docs/reference/tts-voices.md).
  Set<String> get _neuralLangs =>
      _synthEngineHolder == null || _preferSystemVoice
          ? const {}
          : neuralLangsFor(baseLanguage(_workLang ?? widget.work.lang));

  /// What Read aloud says for block [seg] of [_blocks], in order — the
  /// one authority both voices read from (1.5.9):
  ///
  ///  * Translation only: each original sentence's translation (the
  ///    original where it has none yet), in its own language, swept over
  ///    the translated words the page shows.
  ///  * Both, with [_speakTranslation]: each sentence, then its
  ///    translation; while the translation is heard the cursor holds the
  ///    sentence's start, which lights the translation's line.
  ///  * Otherwise: the shown text's sentences.
  ///
  /// The sentence numbering is always the original's
  /// (`core.splitSentences` over [_original]), the numbering the stored
  /// translations were written under. Sentinel blocks (code/table/
  /// figure) and blank ones say nothing.
  ///
  /// Unless the listener turned them back on, citations, footnote marks
  /// and bare links are left out of what is said ([spokenText]), and a
  /// sentence that was nothing else is not said at all. The sweep still
  /// runs over the words the page shows.
  List<_SpeechUnit> _blockUnits(int seg) {
    String say(String text) => _speakCitations ? text : spokenText(text);
    final blocks = _blocks!;
    final block = blocks[seg];
    final speakable = block.kind == core.SegmentKind.prose ||
        block.kind == core.SegmentKind.heading;
    if (!speakable || block.text.trim().isEmpty) return const [];
    final source = _sourceSpeechLang;
    final target = _activeTranslationLang;
    String? translationOf(core.Segment original, List<core.Sentence> ss,
            int i) =>
        target == null
            ? null
            : translatedTextFor(
                stored: _translatedSentences,
                segIdx: original.idx,
                sentenceIdx: i,
                currentSourceText: ss[i].text);
    final units = <_SpeechUnit>[];
    if (_translationOnlyActive) {
      final original = _original[seg];
      final sentences = core.splitSentences(original.text);
      final starts = _projStarts[seg] ?? const <int>[];
      for (var i = 0; i < sentences.length; i++) {
        if (sentences[i].text.trim().isEmpty) continue;
        final translated = translationOf(original, sentences, i);
        final said = say(translated ?? sentences[i].text);
        if (said.isEmpty) continue;
        units.add(_SpeechUnit(
            seg: seg,
            from: i < starts.length ? starts[i] : 0,
            to: i + 1 < starts.length ? starts[i + 1] : null,
            text: said,
            lang: translated != null ? target : source));
      }
      return units;
    }
    final sentences = core.splitSentences(block.text);
    final alsoTranslation = _interlinear && _activeLang == null &&
        _speakTranslation;
    for (var i = 0; i < sentences.length; i++) {
      if (sentences[i].text.trim().isEmpty) continue;
      final from = sentences[i].firstWordIdx;
      final to = i + 1 < sentences.length ? sentences[i + 1].firstWordIdx : null;
      final said = say(sentences[i].text);
      if (said.isNotEmpty) {
        units.add(_SpeechUnit(
            seg: seg, from: from, to: to, text: said, lang: source));
      }
      final translated =
          alsoTranslation ? translationOf(block, sentences, i) : null;
      final saidTranslated = translated == null ? '' : say(translated);
      if (saidTranslated.isNotEmpty) {
        units.add(_SpeechUnit(
            seg: seg,
            from: from,
            to: to,
            text: saidTranslated,
            lang: target,
            sweep: false));
      }
    }
    return units;
  }

  /// Every unit from block [fromSeg] to the end: what a run will say.
  List<_SpeechUnit> _remainingUnits(int fromSeg) => [
        for (var seg = fromSeg; seg < _blocks!.length; seg++)
          ..._blockUnits(seg),
      ];

  /// One speaking run (ADR-0006): decides its voices first
  /// ([planReadAloud]: the downloaded voice only when it reads every
  /// language in the run, else the phone's, each language with its own
  /// voice), refuses with a plain sentence when a language has no voice
  /// at all, then reads. An utterance engine keeps the reader's
  /// per-sentence awaited loop; a synthesis engine hands the rest of the
  /// document to [SpeechPlaybackPipeline], which synthesizes and plays
  /// gaplessly, ahead of playback. Both paths advance the SAME cursor
  /// under the SAME law (ADR-0002): stopping anywhere leaves Position at
  /// that sentence's start.
  Future<void> _speakLoop() async {
    final gen = ++_speakGen;
    final doc = _doc!;
    final blocks = _blocks!;
    bool live() => mounted && _speaking && gen == _speakGen;
    final seg = cursorAt(doc, _wordIdx).segment;
    final units = _remainingUnits(seg);
    final target = baseLanguage(_activeTranslationLang);
    final langs = {
      for (final u in units) ?baseLanguage(u.lang),
      if (_readsTranslation) ?target,
    };
    // A text whose language nobody set, in letters the downloaded voice
    // can't say (Cyrillic, CJK...): no voice can be chosen for it, and
    // reading on would be silence or the wrong language's voice.
    if (units.any((u) => u.lang == null && hasNonLatinLetters(u.text))) {
      setState(() => _speaking = false);
      _sessionGone();
      _say(unknownLanguageMessage);
      return;
    }
    final synth = _synthEngineHolder;
    final neuralLangs = _neuralLangs;
    var plan = planReadAloud(
        langs: langs,
        neuralLangs: neuralLangs,
        choices: _voiceChoices,
        installed: null);
    if (!plan.neural) {
      final installed = await _listVoices();
      if (!live()) return;
      plan = planReadAloud(
          langs: langs,
          neuralLangs: neuralLangs,
          choices: _voiceChoices,
          installed: installed);
    }
    if (plan.missing.isNotEmpty) {
      setState(() => _speaking = false);
      _sessionGone();
      // The translation's language first: the one most likely missing,
      // and the one the listener is asking for. Under Both the original
      // can still be heard alone, and the message says how.
      final missing =
          plan.missing.contains(target) ? target! : plan.missing.first;
      final original = baseLanguage(_sourceSpeechLang);
      _say(
          noVoiceMessage(missing,
              originalLang: missing == target &&
                      _offersSpeakTranslation &&
                      original != null &&
                      !plan.missing.contains(original)
                  ? original
                  : null),
          voiceSettings: true);
      return;
    }
    _runOnSystemVoice = !plan.neural;
    _voicingTranslation = false;
    _applySpeechSpeed();
    if (plan.neural) {
      await _speakWithSynthesis(synth!, units, gen, live);
    } else {
      await _speakWithUtterance(
          UtteranceSpeechEngine(_tts), plan, doc, blocks, seg, live);
    }
  }

  /// [voiceSettings]: the message is about a voice the phone lacks, so
  /// it carries the door to Android's text-to-speech settings.
  void _say(String message, {bool voiceSettings = false}) =>
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
            content: Text(message, key: const Key('read-aloud-message')),
            // A convenience: the voices sheet has the same door, so the
            // line may lapse with its eight seconds.
            persist: false,
            action: voiceSettings && !kIsWeb
                ? SnackBarAction(
                    key: const Key('read-aloud-message-settings'),
                    label: 'Voice settings',
                    onPressed: () => unawaited(_tts.openSettings()))
                : null,
            duration: const Duration(seconds: 8)));

  /// The phone voice's path: block by block from the cursor's, each
  /// [_blockUnits] unit in turn; each advance moves the cursor to the
  /// unit's sentence and saves the Position row BEFORE speaking on. A
  /// block with nothing to say (a sentinel) is still one stop for the
  /// cursor, passed in one silent beat, the way an eye passes it. A
  /// sentence the engine refuses ([TtsNoVoiceException]: it has no voice
  /// for that language after all) ends the run with the same plain
  /// message as the check before it.
  Future<void> _speakWithUtterance(
      UtteranceSpeechEngine engine,
      ReadAloudVoicePlan plan,
      core.TokenizedDocument doc,
      List<core.Segment> blocks,
      int startSeg,
      bool Function() live) async {
    var seg = startSeg;
    var first = true;
    while (live() && seg < blocks.length) {
      final units = _blockUnits(seg);
      if (units.isEmpty) {
        if (!first) {
          setState(() => _wordIdx = globalWordIndex(doc, seg, 0));
          await _savePosition(modality: 'speak');
          if (!live()) return;
        }
        first = false;
        seg++;
        continue;
      }
      for (final unit in units) {
        if (!live()) return;
        final from = globalWordIndex(doc, seg, unit.from);
        if (!first) {
          setState(() {
            _wordIdx = from;
            _voicingTranslation = !unit.sweep;
          });
          await _savePosition(modality: 'speak');
          if (!live()) return;
        }
        first = false;
        if (unit.sweep) {
          _sweepSentence(doc, from, _unitEnd(doc, unit));
        }
        final lang = unit.lang;
        try {
          await engine.speak(unit.text,
              lang: lang,
              voice: plan.systemVoices[baseLanguage(lang)]);
        } on TtsNoVoiceException catch (e) {
          if (!live()) return;
          await _stopSpeak();
          final missing = baseLanguage(e.lang) ?? e.lang;
          _say(
              noVoiceMessage(missing,
                  internetVoice: _phoneVoices?.any(
                          (v) => v.lang == missing && v.needsInternet) ??
                      false),
              voiceSettings: true);
          return;
        } on TtsSpeakException {
          if (!live()) return;
          await _stopSpeak();
          _say(_needsInternet(baseLanguage(lang), plan)
              ? 'This voice needs the internet.'
              : 'Read aloud stopped: the voice couldn’t play.');
          return;
        } catch (_) {
          if (!live()) return;
          await _stopSpeak();
          _say('Read aloud stopped: the voice couldn’t play.');
          return;
        }
        _stopSweep();
        if (!live()) return;
      }
      seg++;
    }
    _finishSpeaking(live);
  }

  /// Whether the voice reading [lang] in [plan] needs the internet: the
  /// one picked, or, for the language's default, every voice listed for
  /// it (then the default can only be one of those).
  bool _needsInternet(String? lang, ReadAloudVoicePlan plan) {
    final picked = plan.systemVoices[lang];
    if (picked != null) return picked.needsInternet;
    final listed = [
      for (final v in _phoneVoices ?? const <SystemVoice>[])
        if (v.lang == lang) v
    ];
    return listed.isNotEmpty && listed.every((v) => v.needsInternet);
  }

  /// The global index one past [unit]'s sentence.
  int _unitEnd(core.TokenizedDocument doc, _SpeechUnit unit) {
    final to = unit.to;
    return to == null
        ? _blockEnd(doc, unit.seg)
        : globalWordIndex(doc, unit.seg, to);
  }

  /// The neural voice's path: hands every remaining sentence to a
  /// long-lived [SpeechPlaybackPipeline] (reused across runs — its own
  /// generation counter, bumped on every `start()`, is what makes reuse
  /// safe) and returns immediately — like the utterance path, this run is
  /// fire-and-forget from the caller's perspective; [_onSynthSentenceStart]
  /// and [_onSynthDone] carry it the rest of the way via the pipeline's
  /// callbacks.
  Future<void> _speakWithSynthesis(SynthesisSpeechEngine engine,
      List<_SpeechUnit> units, int gen, bool Function() live) async {
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
      onFailed: _onSynthFailed,
    );
    unawaited(_queue.setSpeed(_speechSpeed).catchError((_) {}));
    await pipeline.start([for (final u in units) u.text],
        lang: _sourceSpeechLang,
        langOverrides: [for (final u in units) u.lang]);
  }

  /// The synthesis path's cursor advance: index 0 is the sentence the
  /// cursor already sat on when this run started (mirrors the utterance
  /// path's `first` flag — no move, no save), every later index moves and
  /// saves BEFORE the next sentence is heard, the same cursor law either
  /// engine obeys.
  void _onSynthSentenceStart(int index) {
    if (!mounted || !_speaking || _synthGen != _speakGen) return;
    if (index >= _synthUnits.length) return;
    final doc = _doc;
    if (doc == null) return;
    final unit = _synthUnits[index];
    final from = globalWordIndex(doc, unit.seg, unit.from);
    _stopSweep();
    if (index > 0) {
      setState(() {
        _wordIdx = from;
        _voicingTranslation = !unit.sweep;
      });
      unawaited(_savePosition(modality: 'speak').catchError((_) {}));
    }
    if (unit.sweep) _sweepSentence(doc, from, _unitEnd(doc, unit));
  }

  /// The global index one past block [seg]'s last word.
  int _blockEnd(core.TokenizedDocument doc, int seg) =>
      seg + 1 < doc.blockStartWordIdx.length
          ? doc.blockStartWordIdx[seg + 1]
          : doc.words.length;

  /// A voice's pace at 1x, by characters (about 165 words a minute):
  /// only an estimate, which is why the sweep re-anchors every sentence.
  static const _speechMsPerChar = 66;

  /// Sweeps the cursor over words [from, to) — see [_sweep].
  void _sweepSentence(core.TokenizedDocument doc, int from, int to) {
    _stopSweep();
    // Behind the screen (read aloud in the media session) there is nobody
    // to sweep for: sixty rebuilds a second would be wasted battery.
    if (!_onScreen) return;
    if (to - from < 1) return;
    _sweepStart = from;
    final ends = <int>[];
    var chars = 0;
    for (var w = from; w < to; w++) {
      chars += doc.words[w].length + 1;
      ends.add(chars);
    }
    _sweep = Timer.periodic(const Duration(milliseconds: 16), (t) {
      if (!mounted || !_speaking) return;
      final said = t.tick * 16 * _speechSpeed / _speechMsPerChar;
      var k = 0;
      while (k < ends.length - 1 && ends[k] <= said) {
        k++;
      }
      if (from + k != _wordIdx) setState(() => _wordIdx = from + k);
    });
  }

  void _stopSweep() {
    _sweep?.cancel();
    _sweep = null;
    _sweepStart = null;
  }

  /// The shared speed control's value (1.5.8): the player's, for read-
  /// aloud as for listening; 1x where there is no player.
  double get _speechSpeed => widget.player?.speed ?? 1.0;

  /// Hands [_speechSpeed] to the voice: flutter_tts counts 0.5 as a
  /// voice's normal pace on a phone (its Android side doubles the value,
  /// 4.2.5) but hands the web's speechSynthesis the value as is, where
  /// 1.0 is normal; the neural voice's queue plays its clips faster. The
  /// system voice takes a new rate from its next sentence.
  void _applySpeechSpeed() {
    final speed = _speechSpeed;
    _appliedSpeechSpeed = speed;
    if (_runOnSystemVoice) {
      unawaited(_tts.setRate(kIsWeb ? speed : speed / 2).catchError((_) {}));
    }
    final queue = _queueHolder;
    if (queue != null) unawaited(queue.setSpeed(speed).catchError((_) {}));
  }

  void _onSpeechSpeed() {
    if (_speaking && _speechSpeed != _appliedSpeechSpeed) _applySpeechSpeed();
  }

  // ───── one voice at a time (1.5.9) ─────
  //
  // The report that started this: a transcribed episode's reader had the
  // bar's Play, the page's Listen and a third Play (the one-word pacer, or
  // Read aloud) that ignored the other two, so audio and the page's own
  // pace or voice ran over each other. Now whichever starts last wins:
  // Read aloud pauses any audio (two voices at once is never wanted), the
  // pacer pauses this episode (it would otherwise race the words), and
  // the episode starting to play, from the bar, the lock screen or
  // anywhere, stops both and takes the cursor back.

  /// Pauses the audio [start] must not run over, then runs [start] once
  /// it is quiet. True when it took over (the caller returns).
  ///
  /// A pause that fails starts nothing while the audio still plays: a
  /// second voice over the first is the very thing this prevents. The
  /// listener is told, in words, and the bar's Pause is right there.
  bool _pauseAudioThen(VoidCallback start, {required bool anyWork}) {
    final p = widget.player;
    if (p == null || !p.playing) return false;
    if (!anyWork && p.current?.id != widget.work.id) return false;
    unawaited(p.toggle().catchError((Object _) {}).then((_) {
      if (!mounted) return;
      if (!p.playing) return start();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
            content:
                Text('Couldn’t pause the audio. Pause it, then try again.')));
    }));
    return true;
  }

  /// The player's (current work, playing) at the last notification, so
  /// [_onPlayerTurn] acts on a start, not on every position tick.
  ({int? id, bool playing})? _lastTurn;

  void _onPlayerTurn() {
    final p = widget.player;
    if (p == null || !mounted) return;
    final turn = (id: p.current?.id, playing: p.playing);
    final started = turn.playing && turn != _lastTurn;
    _lastTurn = turn;
    if (!started) return;
    // The episode took over: the end of a call must not take it back.
    _resumeAfterInterruption = false;
    if (_speaking) unawaited(_stopSpeak());
    if (turn.id != widget.work.id) return;
    if (_playing) _pause();
    // Resumed from anywhere (the bar, the lock screen): the page follows
    // the voice again, so the two never drift apart. A hand that takes
    // the cursor while it plays still detaches, until the next start.
    _attachAudioFollow();
  }

  /// The bar (MiniPlayerHost's, on every pushed screen) is playing this
  /// work and the page is following it: the bar's Play is this page's
  /// Play then, and the page doesn't repeat it. Paused, or with the
  /// reader away from the voice, Listen from here stays: the bar would
  /// resume where the voice stopped, not where the reader is.
  bool get _barHoldsListen {
    final p = widget.player;
    return p != null &&
        p.current?.id == widget.work.id &&
        p.playing &&
        _followingAudio &&
        (MiniPlayerHost.maybeOf(context)?.hasBar ?? false);
  }

  /// The synthesis path's natural end — fired only once every sentence has
  /// genuinely finished playing (the pipeline's own `onDone` contract) —
  /// restores the non-speaking state through the exact same call the
  /// utterance path uses.
  void _onSynthDone() {
    if (!mounted || !_speaking || _synthGen != _speakGen) return;
    _finishSpeaking(() => mounted && _speaking && _synthGen == _speakGen);
  }

  /// The synthesis run could not go on (a sentence that would not
  /// synthesize, a clip or player that failed): the page leaves speaking
  /// through the same path as Stop, and says so, instead of sitting on
  /// Stop in silence.
  void _onSynthFailed() {
    if (!mounted || !_speaking || _synthGen != _speakGen) return;
    unawaited(_stopSpeak());
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
          content: Text('Read aloud stopped: the voice couldn’t play.')));
  }

  /// The audio session took the speaker (the queue has already paused).
  /// The page stops the way Stop does, the cursor back at the sentence's
  /// start, so what it shows matches what is heard. A passing
  /// interruption hands the voice back, as it does the podcast
  /// (just_audio resumes a player a call paused), but only to a page that
  /// is on screen, the one place read aloud ever plays.
  void _onSpeechInterruption(SpeechInterruption why) {
    if (!mounted) return;
    switch (why) {
      case SpeechInterruption.began:
      case SpeechInterruption.noisy:
        if (!_speaking) return;
        unawaited(_stopSpeak());
        _resumeAfterInterruption = why == SpeechInterruption.began;
      case SpeechInterruption.ended:
        final resume = _resumeAfterInterruption;
        _resumeAfterInterruption = false;
        if (resume && !_speaking && (_onScreen || _inSession)) _startSpeak();
    }
  }

  void _finishSpeaking(bool Function() live) {
    _stopSweep();
    if (live()) {
      setState(() => _speaking = false);
      _sessionGone();
      unawaited(_savePosition(modality: 'speak').catchError((_) {}));
    }
  }

  // ───── the media session (1.6.0) ─────
  //
  // The owner: "I am having an essay read aloud to me but it stops when
  // the screen goes dark, I would like it treated just like media/podcast
  // playing." While it reads, read aloud is what the app's media session
  // shows, as an episode is while it plays: that is what brings the
  // playback service (so Android leaves the app running behind the
  // screen), the notification, and the lock-screen and headset buttons.
  // A stop leaves it there paused, so Play on the lock screen picks it
  // up; the end of the text, or leaving the reader, lets it go.

  late final _ReadAloudClient _sessionClient = _ReadAloudClient(this);

  /// Read aloud is in the session (reading or paused). Never true with no
  /// session to be in.
  bool _inSession = false;

  void _sessionPlaying() {
    final session = widget.session;
    if (session is NoPlaybackSession) return;
    session.attach(
        _sessionClient,
        LockScreenTag(
            id: 'read-aloud-${widget.work.id}',
            title: widget.work.title,
            album: 'Read aloud'));
    _inSession = true;
    session.report(_sessionClient,
        const SessionState(playing: true, phase: SessionPhase.ready));
  }

  void _sessionPaused() {
    if (!_inSession) return;
    widget.session
        .report(_sessionClient, const SessionState(phase: SessionPhase.ready));
  }

  void _sessionGone() {
    if (!_inSession) return;
    _inSession = false;
    widget.session.detach(_sessionClient);
  }

  static SpeechTempFiles _fallbackSpeechTempFiles() => DiskSpeechTempFiles(
      dir: Directory('${Directory.systemTemp.path}/trellis-speech-temp'));

  /// The Read aloud voices sheet: a voice for each language this work
  /// reads in (its own, and the translation's while one shows).
  Future<void> _openReadAloudVoices() async {
    final installed = await _listVoices(fresh: true);
    if (!mounted) return;
    final source = _sourceSpeechLang;
    final target = _hasStoredTranslation && _activeLang == null
        ? _activeTranslationLang
        : null;
    final langs =
        <String>{?baseLanguage(source), ?baseLanguage(target)}.toList();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ReadAloudVoicesSheet(
          langs: langs,
          neuralLangs: _neuralLangs,
          installed: installed,
          choices: _voiceChoices,
          onPick: _pickVoice,
          systemVoiceOn: _synthEngineHolder != null && _preferSystemVoice,
          onOpenSettings: _tts.openSettings),
    );
  }

  /// Remembers [voiceId] for [lang] (the whole prefs blob is shared, so
  /// it changes through [ProfilesDao.updateReaderPrefs]). The next run
  /// reads with it.
  void _pickVoice(String lang, String voiceId) {
    setState(() => _voiceChoices = {..._voiceChoices, lang: voiceId});
    unawaited(widget.db.profilesDao
        .updateReaderPrefs(widget.profileId,
            (p) => p.copyWith(voices: {...p.voices, lang: voiceId}))
        .catchError((Object _) {}));
  }

  // ───── translation (ADR-0008 "Babel"; Campaign 8 "Babel widens"; any
  // registered language, downloaded on demand and via English, 1.5.5) ─────

  /// The calm per-work source-language selector (Campaign 8 "Babel
  /// widens" Phase 1): a curated list, never a guess. Returns the chosen
  /// language (or the current one if the reader backs out). Reloads the
  /// whole screen after a change: a language change can change which
  /// voice [_synthEngineHolder] should be and whether an active
  /// translation still makes sense, and [_load] re-derives all of it.
  Future<String?> _openWorkLanguagePicker({String? title}) async {
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        key: const Key('work-language-picker'),
        title: Text(title ?? 'This work is in…'),
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
    if (chosen == null || chosen == _sourceLang) return _sourceLang;
    await widget.db.spineDao.setWorkLang(widget.work.id, chosen);
    if (!mounted) return chosen;
    await _load();
    return chosen;
  }

  /// The Translate sheet (1.5.5): every language this work can go into,
  /// each marked ready or with what it would download (both legs, via
  /// English, when there is no direct pair). Picking one downloads what
  /// is missing after one confirmation, then translates. Asks what the
  /// work is written in first when nobody knows.
  Future<void> _openTranslatePicker() async {
    final service = widget.translation;
    if (service == null || _activeLang != null || _making != null) return;
    if (_translationJob != null || _download != null) return;
    final source = _sourceLang ??
        await _openWorkLanguagePicker(title: 'What language is this in?');
    if (source == null || !mounted) return;
    final routes = await service.routesFrom(source);
    routes.sort((a, b) =>
        languageDisplayName(a.target).compareTo(languageDisplayName(b.target)));
    final better = source == 'en' ? await _betterJapanese() : null;
    if (!mounted) return;
    final chosen = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.75),
          child: ListView(
            key: const Key('translate-picker'),
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                    'Translate from ${languageDisplayName(source)} to…',
                    style: Theme.of(ctx).textTheme.titleMedium),
              ),
              if (routes.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Text(
                      'There’s no offline translator for '
                      '${languageDisplayName(source)} yet.',
                      key: const Key('translate-none')),
                ),
              for (final r in routes)
                ListTile(
                  key: Key('translate-target-${r.target}'),
                  minTileHeight: 56,
                  title: Text(languageDisplayName(r.target)),
                  subtitle: Text(_routeLine(r)),
                  trailing: Icon(r.ready
                      ? Icons.chevron_right
                      : Icons.download_outlined),
                  onTap: () => Navigator.of(ctx).pop(r),
                ),
              if (better != null)
                ListTile(
                  key: const Key('translate-better-ja'),
                  minTileHeight: 56,
                  title: const Text('Japanese, better'),
                  subtitle: Text('Online: Anthropic’s Claude, with your key. '
                      '${costLine(better.cents)}'),
                  trailing: const Icon(Icons.cloud_outlined),
                  onTap: () => Navigator.of(ctx).pop(better),
                ),
            ],
          ),
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    if (chosen is _BetterJapanese) return _translateBetterJapanese(chosen);
    if (chosen is! TranslationRoute) return;
    if (!chosen.ready && !await _downloadLegs(chosen)) return;
    final fresh = await service.route(source, chosen.target);
    if (fresh == null || !fresh.ready || !mounted) return;
    await _startTranslation(fresh);
  }

  /// The Anthropic brain, when it is the chosen brain and its key is
  /// there; null otherwise. Found once as the reader opens, in the
  /// background, so the Translate sheet never waits on the key store.
  BrainReady? _anthropic;

  Future<void> _findAnthropic() async {
    final store = widget.brain ?? widget.translation?.brain;
    if (store == null) return;
    final use = await store.brainForUse();
    if (!mounted) return;
    if (use is BrainReady &&
        use.provenance.brainTier == BrainTier.byokAnthropic) {
      _anthropic = use;
    }
  }

  /// Better Japanese (board-0126 point 2): offered for an English work
  /// only while Anthropic is the chosen brain and its key is there. A key
  /// kept while another brain is chosen is not used: the person picks the
  /// brain (brain_wiring's no-silent-fallback law). [cents] prices only
  /// the sentences the brain has not translated yet.
  Future<_BetterJapanese?> _betterJapanese() async {
    final use = _anthropic;
    if (use == null) return null;
    final stored =
        await widget.db.spineDao.translationSentencesOf(widget.work.id, lang: 'ja');
    final todo = [
      for (final u in sentenceUnitsOf(_original))
        if (!_madeByBrain(stored, u)) u.text,
    ];
    // All of it made by the brain already: nothing to send, no choice.
    if (todo.isEmpty) return null;
    return _BetterJapanese(use, brainTranslationCents(todo));
  }

  /// Whether [u]'s current Japanese is the brain's.
  static bool _madeByBrain(Map<(int, int), TranslationSentence> stored,
      TranslatableSentence u) {
    final row = stored[(u.segIdx, u.sentenceIdx)];
    return row != null &&
        row.sourceText == u.text &&
        row.engine == _betterJapaneseEngine;
  }

  /// Asks before anything leaves the device (ADR-0003 law 6), naming
  /// where the text goes, under whose key, and what it costs; then runs
  /// the translation through the brain. A no sends and stores nothing.
  Future<void> _translateBetterJapanese(_BetterJapanese better) async {
    final ok = await confirmDownload(context,
        title: 'Send to Anthropic?',
        accept: 'Send',
        items: [
          DownloadItem('The text of “${widget.work.title}” goes to '
              '${better.ready.egressHost}, where Anthropic’s Claude puts it '
              'into Japanese.'),
          DownloadItem('It uses your Anthropic key. '
              '${costLine(better.cents)}'),
        ]);
    if (!ok || !mounted) return;
    final translator = BrainSentenceTranslator(BrainTranslator(
        brain: better.ready.brain,
        sourceLang: languageDisplayName('en'),
        targetLang: languageDisplayName('ja'),
        engine: _betterJapaneseEngine));
    final phase = await _runTranslation(
      target: 'ja',
      steps: [
        TranslationStep(
            lang: 'ja',
            engine: _betterJapaneseEngine,
            open: () async => translator),
      ],
      resumable: false,
    );
    if (!mounted) return;
    final missed = sentenceUnitsOf(_original)
        .any((u) => !_madeByBrain(_translatedSentences, u));
    if (phase == TranslationJobPhase.done && missed) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Anthropic didn’t translate every sentence. '
              'Choose Japanese, better again to try the rest.')));
    }
  }

  /// What rows made by the Anthropic brain carry as their engine.
  static final _betterJapaneseEngine = anthropicTranslationEngine;

  /// "Ready", "Via English · Ready", "Download 113 MB", "Update
  /// available: 60 MB" (a pair already here whose decoder was re-pinned).
  static String _routeLine(TranslationRoute r) {
    final how = r.ready
        ? 'Ready'
        : r.update
            ? 'Update available: ${formatBytes(r.missingBytes)}'
            : 'Download ${formatBytes(r.missingBytes)}';
    return r.viaEnglish ? 'Via English · $how' : how;
  }

  /// Downloads every missing leg of [route] after ONE confirmation that
  /// names each leg and its size (the consent chokepoint, ADR-0003 law
  /// 6). Shows progress in the body with a Cancel; returns true only once
  /// every leg is installed.
  Future<bool> _downloadLegs(TranslationRoute route) async {
    final service = widget.translation!;
    final missing = route.missing;
    final ok = await confirmDownload(context, items: [
      for (final l in missing)
        DownloadItem('${languageDisplayName(l.source)} to '
            '${languageDisplayName(l.target)} translator'
            '${l.update ? ' update' : ''}, ${formatBytes(l.missingBytes)}'),
      if (missing.length > 1)
        DownloadItem('${formatBytes(route.missingBytes)} in all, to '
            'translate via English'),
    ]);
    if (!ok || !mounted) return false;
    for (final leg in missing) {
      final download = service.download(leg.spec);
      setState(() {
        _download = download;
        _downloadProgress = null;
        _downloadLabel = '${languageDisplayName(leg.source)} to '
            '${languageDisplayName(leg.target)}';
      });
      final sub = download.progress.listen((p) {
        if (mounted) setState(() => _downloadProgress = p);
      });
      ModelInstallOutcome outcome;
      try {
        outcome = await download.done;
      } catch (_) {
        outcome = ModelInstallOutcome.cancelled;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('The download didn’t finish. Try again '
                  'later; what arrived is kept.')));
        }
      }
      // The stream is over by now; waiting on the cancel only delays the
      // next leg.
      unawaited(sub.cancel());
      if (!mounted) return false;
      setState(() {
        _download = null;
        _downloadProgress = null;
      });
      if (outcome != ModelInstallOutcome.installed) return false;
    }
    return true;
  }

  /// Picks up a run the system killed, if its models are still there;
  /// otherwise drops the marker so the reader isn't left waiting.
  Future<void> _resumeTranslation(String target) async {
    final service = widget.translation;
    final source = _sourceLang;
    final route = service == null || source == null
        ? null
        : await service.route(source, target);
    if (!mounted) return;
    if (route == null || !route.ready) {
      await widget.db.spineDao.setTranslationRunLang(widget.work.id, null);
      return;
    }
    await _startTranslation(route);
  }

  /// Runs the cancellable, resumable translation into [route]'s target
  /// over [_original] — never [_blocks], which under [_activeLang] is a
  /// language-swapped projection whose own `splitSentences` boundaries
  /// would disagree with the store's numbering. Already-stored sentences
  /// are skipped, so this is also how an interrupted run resumes. Each
  /// leg's model opens when its pass starts and is freed when it ends.
  /// Refuses a target equal to the work's own language, a second gate
  /// behind the planner's.
  Future<void> _startTranslation(TranslationRoute route) async {
    final service = widget.translation;
    if (service == null) return;
    if (route.target == route.source) return;
    await _runTranslation(target: route.target, steps: [
      for (final leg in route.legs)
        TranslationStep(lang: leg.target, open: () => service.open(leg.spec)),
    ]);
  }

  /// Runs [steps] into [target] (see [_startTranslation]). [resumable] is
  /// false for a run that sends text away: it is never picked up again
  /// without a new yes. Returns how the run ended, or null when none ran.
  Future<TranslationJobPhase?> _runTranslation({
    required String target,
    required List<TranslationStep> steps,
    bool resumable = true,
  }) async {
    final service = widget.translation;
    if (target == _sourceLang) return null;
    if (_activeLang != null || _translationJob != null) return null;
    await widget.db.spineDao.setActiveTranslationLang(widget.work.id, target);
    // The sentences in memory are the old target's until this run ends:
    // left there, Both would show another language's sentences under the
    // new one's name, and Read aloud would hand them to the new
    // language's voice. Swap in what is stored for the new target (none,
    // or what an interrupted run already made).
    final stored = target == _activeTranslationLang
        ? _translatedSentences
        : await widget.db.spineDao
            .translationSentencesOf(widget.work.id, lang: target);
    if (!mounted) return null;
    final from = _cursorSentence();
    final onlyBefore = _translationOnlyActive;
    final run = TranslationRun(
      dao: widget.db.spineDao,
      workId: widget.work.id,
      units: sentenceUnitsOf(_original),
      target: target,
      steps: steps,
      foreground: service?.foreground,
      title: widget.work.title,
      resumable: resumable,
    );
    run.addListener(_onTranslationProgress);
    setState(() {
      _activeTranslationLang = target;
      _translatedSentences = stored;
      _showTranslation = true;
      _translationJob = run;
    });
    if (onlyBefore || _translationOnlyActive) _applyProjection(from);
    await run.start();
    run.removeListener(_onTranslationProgress);
    if (!mounted) return null;
    final translatedSentences = await widget.db.spineDao
        .translationSentencesOf(widget.work.id, lang: target);
    if (!mounted) return null;
    final at = _cursorSentence();
    final wasOnly = _translationOnlyActive;
    setState(() {
      _translatedSentences = translatedSentences;
      _translationJob = null;
    });
    if (wasOnly || _translationOnlyActive) _applyProjection(at);
    if (run.state.phase == TranslationJobPhase.failed) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('The translator couldn’t start. Try downloading '
              'its language again in Models.')));
    }
    return run.state.phase;
  }

  void _onTranslationProgress() {
    if (!mounted) return;
    setState(() {}); // the card reads _translationJob!.state directly
  }

  void _cancelTranslation() => _translationJob?.cancel();

  /// The scroll-mode dual-display toggle: persisted through the DAO (not
  /// local-only state), same law the system-voice switch follows. With
  /// it off Read aloud reads the original only, whatever
  /// [_speakTranslation] says: that choice is about Both.
  Future<void> _toggleShowTranslation() async {
    final next = !_showTranslation;
    final at = _cursorSentence();
    final wasOnly = _translationOnlyActive;
    setState(() => _showTranslation = next);
    if (wasOnly != _translationOnlyActive) _applyProjection(at);
    await widget.db.spineDao.setShowTranslationLayer(widget.work.id, next);
  }

  /// Reading the translation under Both: takes effect on the NEXT run, the same law the system-voice switch
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
    if (_pauseAudioThen(_play, anyWork: false)) return;
    unawaited(_stopSpeak()); // one cursor-advancer at a time
    _detachAudioFollow(); // the pacer is a hand on the cursor too
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
    if (_transcriptStale) unawaited(_reloadTranscript());
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
    // A link's word opens the link (1.6.2), after the same question show
    // notes ask. It does not also move the reading place.
    final link = linkOfToken(doc.originals[globalIdx]);
    if (link != null) {
      unawaited(confirmAndOpenLink(context, link, widget.openLink));
      return;
    }
    _timer?.cancel();
    unawaited(_stopSpeak());
    // On Page a tapped word is seek + follow (1.5.5, 1.5.8): while this
    // work is in the player, the audio goes to that word's own stamp and
    // the page follows it again, as the transcript view did.
    final player = widget.player;
    final spine = _spine;
    if (_audioFollowable &&
        _mode != ReaderMode.rsvp &&
        player != null &&
        spine != null) {
      _pause();
      final idx = globalIdx.clamp(0, doc.words.length - 1);
      setState(() => _wordIdx = idx);
      final only = _translationOnlyActive;
      final tMs = audioTimeOfWord(
          spine: spine,
          doc: only ? _origDoc! : doc,
          blocks: only ? _original : _blocks!,
          globalIdx: _originalWordOf(idx),
          wordTimings: _wordTimings,
          wordLevel: _wordLevel);
      unawaited(() async {
        if (tMs != null) {
          await player.playWorkAt(widget.work, Duration(milliseconds: tMs));
        }
        if (mounted) _attachAudioFollow();
      }());
      return;
    }
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
  static ReaderMode _modeFromWire(String wire) => switch (wire) {
        'scroll' => ReaderMode.scroll,
        'lines' => ReaderMode.lines,
        _ => ReaderMode.rsvp,
      };

  static String _modeToWire(ReaderMode m) => switch (m) {
        ReaderMode.rsvp => 'words',
        ReaderMode.scroll => 'scroll',
        ReaderMode.lines => 'lines',
      };

  /// Remembers how this reader reads, for the next open (read-modify-write:
  /// the same blob carries typography and the last-played work).
  Future<void> _rememberSession() async {
    final session = ReaderSession(
        mode: _modeToWire(_mode),
        wpm: _wpm,
        nearbyWords: _parafoveal,
        focusSpread: _sigma);
    await widget.db.profilesDao.updateReaderPrefs(
        widget.profileId, (p) => p.copyWith(session: session));
  }

  void _setMode(ReaderMode next) {
    if (next == _mode) return;
    _pause();
    setState(() {
      _mode = next;
      if (next != ReaderMode.rsvp) _pageMode = next;
      final doc = _doc;
      if (_mode != ReaderMode.rsvp && doc != null && doc.words.isNotEmpty) {
        _scrollAnchor = cursorAt(doc, _wordIdx).segment;
      }
    });
    unawaited(_rememberSession());
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
        lang: _shownLang ?? _workLang ?? widget.work.lang,
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
  /// Pauses first, matching [_openReadingSettings] and [_setMode]:
  /// Phase 2's follow-along made scroll mode playable, which means a held
  /// word can now be on a document that's still advancing underneath the
  /// modal — an un-paused cursor would keep calling `_followAlongScroll`'s
  /// `Scrollable.ensureVisible` on a scrollable sitting under the sheet's
  /// route, racing the sheet for the user's attention.
  void _openDefinitionSheet(String token, int wordIdx) {
    final cleaned = ledgerWord(token);
    if (cleaned == null) return;
    _pause();
    unawaited(_stopSpeak());
    unawaited(showDefinitionSheet(
      context,
      word: cleaned,
      lookupDefinition: widget.lookupDefinition ?? (_) async => null,
      onKeep: () => _keepWord(token),
      onMakeCard: () => _makeCardFrom(wordIdx, cleaned),
    ));
  }

  /// A held word as a cloze card in its own sentence (owner, 28 Oct:
  /// "flashcard mechanics for highlighting and writing stuff"): the
  /// sentence as shown, with the word hidden, opened in the card editor
  /// to change before it is saved into My cards.
  Future<void> _makeCardFrom(int wordIdx, String word) async {
    final doc = _doc;
    final blocks = _blocks;
    if (doc == null || blocks == null || wordIdx >= doc.words.length) return;
    final c = cursorAt(doc, wordIdx);
    final text = blocks[c.segment].text;
    var sentence = text;
    // The last sentence starting at or before the word is the one it is
    // in: the splitter counts words the way the cursor does.
    for (final s in core.splitSentences(text)) {
      if (s.firstWordIdx <= c.word) sentence = s.text;
    }
    final saved = await showCardEditor(context,
        title: 'Make a card',
        initial: CardDraft.cloze(clozeFromSentence(sentence.trim(), word)),
        pictures: CardPictures(widget.db),
        onSave: (draft, _) =>
            addToMyCards(widget.db, widget.profileId, draft));
    if (!saved || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Saved to My cards.')));
  }

  void _openLedger() {
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) =>
            LedgerScreen(db: widget.db, profileId: widget.profileId)));
  }

  // ───── the study crown: read -> listen handoff ─────

  /// "Listen from here": hands the reading cursor's own segment/word to
  /// [ReaderScreen.player], which projects it to an audio time via the SAME
  /// alignments the page follows the audio through (Spine.projectAudioTime) —
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

  /// Whether the visible Play button listens: this work has aligned
  /// audio and a player to hand it to. Otherwise it is the silent pacer.
  bool get _canListen => _hasAlignedAudio && widget.player != null;

  /// The reader's one visible Play (1.5.5: a Play that makes sound). With
  /// aligned audio it listens: it hands the cursor to the player, and
  /// pauses it, with the speed control beside it. A text is read aloud,
  /// the same as the bar's Read aloud. RSVP's own controls hold its pacer.
  Widget? _playButton({required bool fab}) {
    if (!_canListen) {
      if (!fab) return null;
      final readAloud = FloatingActionButton(
        key: const Key('reader-play'),
        tooltip: _speaking ? 'Stop reading' : 'Read aloud',
        onPressed: _toggleSpeak,
        child: Icon(_speaking ? Icons.pause : Icons.play_arrow),
      );
      final player = widget.player;
      if (player == null) return readAloud;
      // The same shared speed as listening (1.5.8).
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _speedControl(player),
          const SizedBox(height: 8),
          readAloud,
        ],
      );
    }
    final player = widget.player!;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        // The bar's Play is this episode's one Play; the speed is there
        // too.
        if (_barHoldsListen) return const SizedBox.shrink();
        // Pause only where no bar holds it, and only while the page
        // follows; otherwise this starts the voice at the cursor.
        final listening = player.current?.id == widget.work.id &&
            player.playing &&
            _followingAudio;
        final VoidCallback onPressed = listening
            ? () => unawaited(player.toggle())
            : () {
                // One hand on the cursor at a time.
                _pause();
                unawaited(_stopSpeak());
                unawaited(_listenFromHere());
              };
        // Headphones, as on the work page's Listen: beside the bar's
        // Play, a second play glyph read as a duplicate.
        final icon =
            Icon(listening ? Icons.pause : Icons.headphones_outlined);
        final tooltip = listening ? 'Pause' : 'Listen from here';
        if (!fab) {
          return OhIconButton.filledTonal(
              key: const Key('reader-play'),
              iconSize: 28,
              tooltip: tooltip,
              onPressed: onPressed,
              icon: icon);
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _speedControl(player),
            const SizedBox(height: 8),
            FloatingActionButton(
                key: const Key('reader-play'),
                tooltip: tooltip,
                onPressed: onPressed,
                child: icon),
          ],
        );
      },
    );
  }

  /// The player's speed control, shared by listening and read-aloud.
  Widget _speedControl(PlayerController player) => ListenableBuilder(
        listenable: player,
        builder: (context, _) => Material(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          shape: const StadiumBorder(),
          child: SpeedControl(
              key: const Key('reader-speed'),
              speed: player.speed,
              onChanged: player.setSpeed),
        ),
      );

  // ───── Campaign 9 Phase 7: the reader follows the player ─────

  /// True whenever there is ANYTHING to follow, whether or not this
  /// screen is currently doing so — "Back to audio" is never shown for a
  /// work with no player, no aligned audio, or where playback has moved
  /// on to something else entirely.
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
    // A fresh follow always re-centres, even on the segment it left from.
    _lastFollowedSegment = -1;
    setState(() => _followingAudio = true);
    _onPlayerTick();
  }

  /// "Back to audio" (1.5.8): the one way back after the user's hand took
  /// the cursor. The same in every mode — the cursor jumps to the voice
  /// and, on Page, the page re-centres on it ([_followAlongScroll]).
  void _backToAudio() {
    _pause();
    unawaited(_stopSpeak());
    _attachAudioFollow();
  }

  /// Word-by-word only while the page shows the words the audio speaks;
  /// a translation in place keeps to the segment.
  bool get _wordLevel => _activeLang == null;

  /// Runs [_followPoll] exactly while following a playing work.
  void _syncFollowPoll() {
    final want =
        _onScreen && _followingAudio && (widget.player?.playing ?? false);
    if (want && _followPoll == null) {
      _followPoll = Timer.periodic(
          const Duration(milliseconds: 16), (_) => _onPlayerTick());
    } else if (!want && _followPoll != null) {
      _followPoll!.cancel();
      _followPoll = null;
    }
  }

  /// The user's hand always wins (house law): a manual seek, a manual
  /// scroll, or playback moving on to a different work all call this.
  /// Safe to call when nothing is attached — `ChangeNotifier
  /// .removeListener` no-ops on a listener it never held.
  void _detachAudioFollow() {
    widget.player?.removeListener(_onPlayerTick);
    _followPoll?.cancel();
    _followPoll = null;
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
    if (!mounted) return;
    _syncFollowPoll();
    if (spine == null || doc == null || blocks == null) return;
    final only = _translationOnlyActive;
    final origIdx = wordIndexAtAudioTime(
        spine: spine,
        doc: only ? _origDoc! : doc,
        blocks: only ? _original : blocks,
        audioTimeMs: player.position.inMilliseconds,
        wordTimings: _wordTimings,
        wordLevel: _wordLevel);
    final newIdx = origIdx == null ? null : _shownWordOf(origIdx);
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

  /// Reading settings (board-0131): reading style, the system voice and
  /// citations, the same rows as Settings' Reading group. Both cursor
  /// advancers stop first, as for distill. On return the page and the
  /// next read aloud take what changed: a run already under way would
  /// finish as it began (ADR-0006), and none is under way here.
  Future<void> _openReadingSettings() async {
    _pause();
    unawaited(_stopSpeak());
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ReadingSettingsScreen(
            db: widget.db,
            profileId: widget.profileId,
            offerSystemVoice: _synthEngineHolder != null)));
    if (!mounted) return;
    final prefs = await widget.db.profilesDao.readerPrefs(widget.profileId);
    final preferSystemVoice =
        await widget.db.profilesDao.preferSystemVoice(widget.profileId);
    final speakCitations =
        await widget.db.deviceSettingsDao.read(speakCitationsKey) == 'on';
    if (!mounted) return;
    setState(() {
      _typography = prefs.typography;
      _preferSystemVoice = preferSystemVoice;
      _speakCitations = speakCitations;
    });
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
  bool _noteDismissed = false;

  /// The opener's sentence, its action beside it while it fits and below
  /// it at large text.
  Widget _noteBar(BuildContext context, ReaderNote note) {
    final theme = Theme.of(context);
    final act = note.onAction;
    return ColoredBox(
      key: const Key('reader-note'),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
        child: Row(
          children: [
            Expanded(
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  Text(note.text,
                      key: const Key('reader-note-text'),
                      style: theme.textTheme.bodyMedium),
                  if (note.action case final label? when act != null)
                    TextButton(
                      key: const Key('reader-note-action'),
                      style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48)),
                      onPressed: () => unawaited(act(context)),
                      child: Text(label),
                    ),
                ],
              ),
            ),
            IconButton(
              key: const Key('reader-note-dismiss'),
              tooltip: 'Close this note',
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => setState(() => _noteDismissed = true),
            ),
          ],
        ),
      ),
    );
  }

  /// The plain line over a transcript still being made: how far it has
  /// got, and whether more is coming.
  Widget _soFarBar(BuildContext context, TranscriptMaking making) {
    final theme = Theme.of(context);
    return ColoredBox(
      key: const Key('reader-so-far'),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(soFarReaderLine(making),
                  style: theme.textTheme.bodyMedium),
            ),
          ],
        ),
      ),
    );
  }

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

  PopupMenuItem<ReaderMode> _modeItem(
          Key key, ReaderMode value, String label, String description,
          {required bool checked}) =>
      CheckedPopupMenuItem<ReaderMode>(
        key: key,
        value: value,
        checked: checked,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label),
            Text(description,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    return Scaffold(
      // Scroll and Lines put Play where the thumb rests; RSVP's own
      // controls already hold its Play, and hold Listen beside it.
      floatingActionButton:
          doc == null || doc.words.isEmpty || _mode == ReaderMode.rsvp
              ? null
              : _playButton(fab: true),
      appBar: AppBar(
        leading: BackButton(onPressed: _back),
        title: Text(widget.work.title,
            overflow: TextOverflow.ellipsis, maxLines: 1),
        // Icon + word for the reading mode (the current one, named on the
        // face: audit rank 3) and for reading aloud; everything else in the
        // worded menu (fleet ruling on top bars).
        actions: [
          OhBarActions(children: [
          // 1.5.5: two modes, RSVP and Page, each with a one-line
          // description, and Page's highlight below them. Picking a
          // highlight is picking Page with it; the cursor never moves.
          PopupMenuButton<ReaderMode>(
            key: const Key('mode-toggle'),
            tooltip: 'Reading mode: ${readerModeLabel(_mode)}',
            enabled: doc != null,
            onSelected: _setMode,
            itemBuilder: (_) => [
              _modeItem(const Key('mode-item-rsvp'), ReaderMode.rsvp,
                  readerModeLabel(ReaderMode.rsvp),
                  readerModeDescription(ReaderMode.rsvp),
                  checked: _mode == ReaderMode.rsvp),
              _modeItem(const Key('mode-item-page'), _pageMode, 'Page',
                  readerModeDescription(ReaderMode.scroll),
                  checked: _mode != ReaderMode.rsvp),
              const PopupMenuDivider(),
              const PopupMenuItem<ReaderMode>(
                  enabled: false, height: 32, child: Text('Page highlight')),
              for (final m in const [ReaderMode.scroll, ReaderMode.lines])
                _modeItem(
                    Key(m == ReaderMode.lines
                        ? 'highlight-item-line'
                        : 'highlight-item-follow'),
                    m,
                    pageHighlightLabel(m),
                    pageHighlightDescription(m),
                    checked: _mode == m),
            ],
            child: _BarMenuFace(
                icon: readerModeIcon(_mode), label: readerModeLabel(_mode)),
          ),
          // On Page a text's Play already reads aloud; the bar keeps the
          // action only where nothing else does (1.5.5 ruling).
          if (_mode == ReaderMode.rsvp || _canListen)
            OhBarAction(
              key: const Key('speak-toggle'),
              icon: _speaking ? Icons.stop_circle_outlined
                  : Icons.volume_up_outlined,
              label: _speaking ? 'Stop' : 'Read aloud',
              onPressed: doc == null ? null : _toggleSpeak,
            ),
          OhBarOverflow<String>(
            key: const Key('reader-overflow'),
            onSelected: (value) {
              if (value == 'distill') unawaited(_distill());
              if (value == 'voices') unawaited(_openReadAloudVoices());
              if (value == 'translate') unawaited(_openTranslatePicker());
              if (value == 'show-translation') {
                unawaited(_toggleShowTranslation());
              }
              if (value == 'speak-translation') _toggleSpeakTranslation();
              if (value == 'translation-only') {
                unawaited(_setTranslationOnly(true));
              }
              if (value == 'translation-both') {
                unawaited(_setTranslationOnly(false));
              }
              if (value == 'reading-settings') {
                unawaited(_openReadingSettings());
              }
              if (value == 'work-language') unawaited(_openWorkLanguagePicker());
              if (value == 'lang') _toggleLanguage();
              if (value == 'ledger') _openLedger();
            },
            itemBuilder: (_) => [
              if (_mtLangs.isNotEmpty && doc != null)
                PopupMenuItem(
                  key: const Key('lang-toggle'),
                  value: 'lang',
                  child: Text(_activeLang == null
                      ? 'Show translation'
                      : 'Switch translation (showing $_activeLang)'),
                ),
              const PopupMenuItem(
                  key: Key('open-ledger'),
                  value: 'ledger',
                  child: Text('Word ledger')),
              const PopupMenuItem(
                  value: 'distill',
                  child: Text('Distill into a course')),
              // Campaign 8 "Babel widens" Phase 1: the calm per-work
              // source-language selector — always offered (unlike the
              // translate/show/speak items below, which gate on there
              // being something to offer), since correcting a work's
              // declared language is meaningful even with nothing
              // downloaded to translate it with yet.
              PopupMenuItem(
                  key: const Key('work-language-action'),
                  value: 'work-language',
                  child: Text(_sourceLang == null
                      ? 'Language: not set'
                      : 'Language: ${languageDisplayName(_sourceLang!)}')),
              // A voice for each language this text reads in (1.5.9):
              // rare, so here, not on the bar.
              const PopupMenuItem(
                  key: Key('read-aloud-voices'),
                  value: 'voices',
                  child: Text('Read aloud voices')),
              // The model gate (ADR-0008; generalized to any pair,
              // Campaign 8 "Babel widens"): offered only once at least
              // one target pair for this work's source language is
              // actually downloaded, and only over the canonical
              // English text — hidden under the existing mt language
              // swap. "Translate…" opens a picker (there is no longer a
              // SINGLE fixed target — see [_openTranslatePicker]).
              // A transcript still being made waits: translated now,
              // each window landing after it would stay untranslated.
              if (widget.translation != null &&
                  _activeLang == null &&
                  _translationJob == null &&
                  _download == null)
                _making == null
                    ? const PopupMenuItem(
                        key: Key('translate-action'),
                        value: 'translate',
                        child: Text('Translate…'))
                    : const PopupMenuItem(
                        key: Key('translate-action'),
                        value: 'translate',
                        enabled: false,
                        child: Text('Translate waits for the whole transcript')),
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
              // Translation only / Both (1.5.8): where the translation
              // shows, once there is one showing.
              if (_showTranslation &&
                  _hasStoredTranslation &&
                  _activeLang == null) ...[
                CheckedPopupMenuItem<String>(
                  key: const Key('translation-view-only'),
                  value: 'translation-only',
                  checked: _translationOnly,
                  child: const Text('Translation only'),
                ),
                CheckedPopupMenuItem<String>(
                  key: const Key('translation-view-both'),
                  value: 'translation-both',
                  checked: !_translationOnly,
                  child: const Text('Both'),
                ),
              ],
              // Under Translation only the voice already reads the
              // translation, so there is nothing to switch; under Both it
              // reads each sentence, then its translation, unless this
              // is off.
              if (_offersSpeakTranslation)
                CheckedPopupMenuItem<String>(
                  key: const Key('speak-translation-toggle'),
                  value: 'speak-translation',
                  checked: _speakTranslation,
                  child: Text('Read the '
                      '${languageDisplayName(_activeTranslationLang!)} '
                      'aloud too'),
                ),
              // Last, as on no other ⋮: the reader hides the bottom bar,
              // so its door to the reading settings is here (board-0131).
              // The same rows as Settings' Reading group.
              const PopupMenuDivider(),
              const PopupMenuItem(
                  key: Key('reading-settings'),
                  value: 'reading-settings',
                  child: Text('Reading settings')),
            ],
          ),
          ]),
        ],
      ),
      body: Column(
        children: [
          if (widget.note case final note? when !_noteDismissed)
            _noteBar(context, note),
          if (_download != null) _downloadCard(),
          if (_translationJob != null) _translationProgressCard(),
          if (_making case final making?) _soFarBar(context, making),
          // Natural-height, not an AppBar.bottom fixed slot — see
          // _recapOfferBar's own doc comment for why. Only once there is
          // real content to catch up on, matching the switch's own
          // content branch below.
          if (widget.offerRecap &&
              !_recapOfferDismissed &&
              doc != null &&
              doc.words.isNotEmpty)
            _recapOfferBar(context),
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
                    ReaderMode.scroll => _withBackToAudio(_scrollBody(doc)),
                    ReaderMode.lines => _withBackToAudio(_linesBody(doc)),
                  },
              },
            ),
          ),
        ],
      ),
    );
  }

  /// "Back to audio" (1.5.8): shown only after the user's hand has taken
  /// the cursor from the voice, and always that one action — while
  /// following there is no button at all, so no label ever changes
  /// meaning. Rebuilt on the player so it leaves when playback moves to
  /// another work.
  Widget _backToAudioButton() {
    final player = widget.player;
    if (player == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        if (!_audioFollowable || _followingAudio) {
          return const SizedBox.shrink();
        }
        return FilledButton.tonalIcon(
          key: const Key('back-to-audio'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _backToAudio,
          icon: const Icon(Icons.headphones_outlined),
          label: const Text('Back to audio'),
        );
      },
    );
  }

  /// The batch's own calm progress banner (ADR-0008 "Babel" Phase 3) — one
  /// card while translating, mirroring `job_cards.dart`'s status/progress/
  /// button shape without pulling in its river-level coordinator, since
  /// this run is scoped to one work already open in front of the reader.
  Widget _translationProgressCard() {
    final run = _translationJob!;
    final s = run.state;
    final total = s.totalUnits;
    final perPass = run.units.length;
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
                  // A pivot says so, and counts each pass's sentences
                  // rather than a doubled total.
                  final how = run.passCount > 1
                      ? '$label via English, step ${run.pass + 1} of '
                          '${run.passCount}'
                      : label;
                  return total == 0
                      ? 'Translating to $how…'
                      : 'Translating to $how: ${run.passDone} of $perPass '
                          'sentences';
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

  /// A leg downloading for the translation just picked: what, how far,
  /// and a Cancel that keeps what arrived (the resumable engine's
  /// `.part` files) so a later pick resumes rather than restarts.
  Widget _downloadCard() {
    final p = _downloadProgress;
    final total = p?.totalBytes ?? 0;
    final fraction = p == null || total == 0 ? null : p.receivedBytes / total;
    return Card(
      key: const Key('translation-download'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                p == null
                    ? 'Downloading the $_downloadLabel translator…'
                    : 'Downloading the $_downloadLabel translator: '
                        '${formatBytes(p.receivedBytes)} of '
                        '${formatBytes(total)}',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: fraction),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  key: const Key('translation-download-cancel'),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => _download?.cancel(),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Page's place for [_backToAudioButton]: bottom centre, in thumb
  /// reach and clear of the Play button on the right. Overlaid, so the
  /// text never shifts as it comes and goes.
  Widget _withBackToAudio(Widget page) => Stack(
        children: [
          Positioned.fill(child: page),
          Positioned(
            left: 0,
            right: 0,
            bottom: 16,
            child: Center(child: _backToAudioButton()),
          ),
        ],
      );

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
                  : () => _openDefinitionSheet(doc.words[_wordIdx], _wordIdx),
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
                  ?_rsvpTranslation(),
                  Positioned(
                      left: 0,
                      right: 0,
                      bottom: 12,
                      child: Center(child: _backToAudioButton())),
                ],
              ),
            ),
          ),
          _rsvpControls(doc),
        ],
      ),
    );
  }

  /// Under Both (1.5.8), RSVP shows the translation of the sentence the
  /// word belongs to, small, below the word: placed on its own so a
  /// longer translation never moves the word the eyes rest on, and above
  /// Back to audio.
  Widget? _rsvpTranslation() {
    final translated = _translationOfCursorSentence();
    if (translated == null) return null;
    final theme = Theme.of(context);
    return Positioned(
      left: 24,
      right: 24,
      bottom: 72,
      child: Text(translated,
          key: const Key('rsvp-translation'),
          textAlign: TextAlign.center,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          textDirection:
              isRightToLeft(_activeTranslationLang) ? TextDirection.rtl : null,
          style: theme.textTheme.bodyLarge?.copyWith(
              fontFamily: readerTypefaceFontFamily(ReaderTypeface.lora),
              package: kReaderFontPackage,
              fontStyle: FontStyle.italic,
              color: theme.colorScheme.onSurfaceVariant)),
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
            onChangeEnd: (_) => unawaited(_rememberSession()),
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
              label: 'Focus spread ${_sigma.toStringAsFixed(1)}',
              onChanged: (v) => setState(() => _sigma = v),
              onChangeEnd: (_) => unawaited(_rememberSession()),
            ),
            // Plain words, not the Gaussian's "sigma" (jargon ruling).
            Text('Focus spread: higher keeps nearby words brighter',
                style: Theme.of(context).textTheme.labelSmall),
          ],
          const SizedBox(height: 4),
          // Wrap, not Row: at large text the worded chip drops under the
          // play button instead of running off the screen.
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              // The pacer runs the words, silent. Worded and outlined, not
              // a filled Play: beside the bar's Play (and Listen) a second
              // one read as a duplicate (1.5.9). "Start", not a mode's
              // name; while it runs the voice is paused, so its Pause is
              // the only Pause on screen.
              OutlinedButton.icon(
                key: const Key('play-toggle'),
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 48)),
                onPressed: _playing ? _pause : _play,
                icon: Icon(_playing ? Icons.pause : Icons.speed),
                label: Text(_playing ? 'Pause' : 'Start'),
              ),
              ?_playButton(fab: false),
              // The shared speed, for listening and reading aloud alike.
              if (widget.player != null) _speedControl(widget.player!),
              // A state control named by a word (audit rank 3; jargon
              // ruling: "parafoveal" is the field's term, not a household
              // one): on shows the neighbouring words, faded, beside the
              // focus word.
              FilterChip(
                key: const Key('parafoveal-toggle'),
                label: const Text('Nearby words'),
                avatar: const Icon(Icons.blur_on),
                showCheckmark: true,
                selected: _parafoveal,
                onSelected: (on) {
                  setState(() => _parafoveal = on);
                  unawaited(_rememberSession());
                },
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
    // following it (the old transcript view's ensureVisible idiom).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_followAlongScroll(cursorAt(doc, _wordIdx).segment)) {
        _keepCursorWordInView();
      }
    });
    _litSentence = _computeLitSentence(doc);
    // The print measure (proposal-2 §12): on wide screens the page sets as
    // a centered column rather than sprawling wall to wall — 680dp unless
    // the profile's typography prefs (Campaign 4 Phase 1) say otherwise.
    return Center(
      child: ConstrainedBox(
        key: const Key('print-column'),
        constraints: BoxConstraints(maxWidth: _typography.maxTextWidth),
        child: CustomScrollView(
          key: ValueKey('page-$_recenterGen'),
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
            // Room under the last line for the Play button.
            const SliverToBoxAdapter(child: SizedBox(height: 88)),
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
            _interlinear ? _translationBelow(block, theme) : null;
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
                    // Lora, because Nunito has no italic face and a
                    // synthesized slant is not an italic (dfh-02).
                    ? theme.textTheme.bodyMedium?.copyWith(
                        fontFamily:
                            readerTypefaceFontFamily(ReaderTypeface.lora),
                        package: kReaderFontPackage,
                        fontStyle: FontStyle.italic)
                    : readerCodeStyle(color: theme.colorScheme.onSurface)),
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
  /// scroll), scroll it into view (`ensureVisible`, alignment 0.3, 300ms,
  /// the old transcript view's idiom).
  ///
  /// Following audio counts as playing (1.5.8: the page stood still under
  /// the voice). A tile too far off to be built has no context to scroll
  /// to, so the page is rebuilt around it instead ([_recenterGen]) — the
  /// difference between a catch-up that works and one that silently
  /// doesn't.
  ///
  /// True when it moved the page.
  bool _followAlongScroll(int segment) {
    if (!(_playing || _speaking || _followingAudio) ||
        _mode == ReaderMode.rsvp) {
      return false;
    }
    if (segment == _lastFollowedSegment) return false;
    _lastFollowedSegment = segment;
    final ctx = _segKeys[segment]?.currentContext;
    if (ctx == null) {
      if (mounted) {
        setState(() {
          _scrollAnchor = segment;
          _recenterGen++;
        });
      }
      return true;
    }
    _followScrollTo(ctx);
    return true;
  }

  void _followScrollTo(BuildContext ctx) {
    _followScrolling = true;
    Scrollable.ensureVisible(ctx,
            alignment: 0.3, duration: const Duration(milliseconds: 300))
        .whenComplete(() => _followScrolling = false);
  }

  /// The old transcript page's motion inside a segment: a segment can run
  /// far past the screen (a long whisper segment, an article paragraph),
  /// and scrolling only when a new one starts left the lit word below the
  /// fold. When the lit word leaves the band between a tenth and three
  /// quarters of the page, its line glides back to a third of the way
  /// down, the same place a new segment lands. Within the band nothing
  /// moves, so the page holds still while the eyes read down it.
  void _keepCursorWordInView() {
    if (_followScrolling ||
        !(_playing || _speaking || _followingAudio) ||
        _mode != ReaderMode.scroll) {
      return;
    }
    final ctx = _cursorWordKey.currentContext;
    if (ctx == null) return;
    final word = ctx.findRenderObject();
    final scrollable = Scrollable.maybeOf(ctx);
    final view = scrollable?.context.findRenderObject();
    if (word is! RenderBox || view is! RenderBox || !word.attached) return;
    final top = word.localToGlobal(Offset.zero, ancestor: view).dy;
    final height = view.size.height;
    if (top >= height * 0.1 && top + word.size.height <= height * 0.75) return;
    _followScrollTo(ctx);
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
          key: ValueKey('page-$_recenterGen'),
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
            const SliverToBoxAdapter(child: SizedBox(height: 88)),
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
        package: kReaderFontPackage,
        height: _typography.lineHeight,
        fontSize: bodySize == null ? null : bodySize * _typography.fontScale);
    final cursor = cursorAt(doc, _wordIdx);
    final localIdx = cursor.segment == blockPos ? cursor.word : -1;

    Widget lines(int from, int to) => LinePacedBlock(
          words: doc.words.sublist(from, to),
          style: style,
          currentLocalWordIdx:
              _wordIdx >= from && _wordIdx < to ? _wordIdx - from : -1,
          onTapWord: (local) => _seekToWord(from + local),
        );

    Widget body = LinePacedBlock(
      words: doc.words.sublist(start, end),
      style: style,
      currentLocalWordIdx: localIdx,
      onTapWord: (local) => _seekToWord(start + local),
    );
    // Both (1.5.8): Line shows each translated sentence under its
    // original, as Follow along does.
    final sentences = _interlinear ? core.splitSentences(block.text) : null;
    if (sentences != null && sentences.isNotEmpty) {
      final rows = <Widget>[];
      for (var i = 0; i < sentences.length; i++) {
        final sStart = start + sentences[i].firstWordIdx;
        final sEnd = i + 1 < sentences.length
            ? start + sentences[i + 1].firstWordIdx
            : end;
        rows.add(lines(sStart, sEnd));
        final translated = translatedTextFor(
            stored: _translatedSentences,
            segIdx: block.idx,
            sentenceIdx: i,
            currentSourceText: sentences[i].text);
        if (translated != null) {
          rows.add(_translatedLine(translated, theme,
              key: Key('translation-${block.idx}-$i'),
              lit: _translationLit(sStart, sEnd),
              last: i == sentences.length - 1));
        }
      }
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
    }

    return KeyedSubtree(
      key: _segKeys.putIfAbsent(blockPos, GlobalKey.new),
      child: Container(
        key: Key('segment-tile-$blockPos'),
        padding: EdgeInsets.symmetric(
            horizontal: 24, vertical: 8 + _typography.paragraphSpacing),
        child: body,
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
        package: kReaderFontPackage,
        height: _typography.lineHeight,
        fontSize: bodySize == null ? null : bodySize * _typography.fontScale);

    if (!_interlinear) return _wordWrap(doc, start, end, base, theme);

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
            key: Key('translation-${block.idx}-$i'),
            lit: _translationLit(sStart, sEnd),
            last: i == sentences.length - 1));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  /// One block's word range as a plain flowing [Wrap] — the ENTIRE
  /// pre-Babel `_proseWrap` body, unchanged, so the untranslated path's
  /// widget tree stays byte-identical.
  Widget _wordWrap(core.TokenizedDocument doc, int start, int end,
      TextStyle? base, ThemeData theme) {
    // Line's rhythm (1.5.9): words a plain space apart at the reader's
    // text scale, and lines stepped by the line height alone. A fixed gap
    // and run spacing set Follow along looser than the same text on Line,
    // and the gap didn't grow with the text.
    final space = _wordSpace(base);
    // Japanese is one unit a character, and its characters touch: a block
    // holding any such pair carries each word's gap after it instead, and
    // none where two characters meet. A block without one keeps the plain
    // spacing, so Latin pages lay out exactly as before.
    final touches = <int>{
      for (var w = start; w + 1 < end; w++)
        if (core.joinsWithoutSpace(doc.words[w], doc.words[w + 1])) w,
    };
    if (touches.isNotEmpty) {
      return Wrap(
        runSpacing: 0,
        alignment: WrapAlignment.start,
        crossAxisAlignment: WrapCrossAlignment.end,
        children: [
          for (var w = start; w < end; w++)
            GestureDetector(
              onTap: () => _seekToWord(w),
              onLongPress: () => _openDefinitionSheet(doc.words[w], w),
              child: Padding(
                padding: EdgeInsets.only(
                    right: touches.contains(w) || w == end - 1 ? 0 : space),
                // No band reaches past its own character: the one beside
                // it touches, and a band would paint over its edge.
                child: _flowWord(doc, w, base, theme, 0),
              ),
            ),
        ],
      );
    }
    return Wrap(
      spacing: space,
      runSpacing: 0,
      // Always ragged-right (1.6.0). A per-word Wrap can only "justify"
      // by spreading each line's words across the whole measure, the last
      // line included: wide, uneven gaps that made the page hard to read.
      // No mode justifies; the owner ruled stretched spacing out.
      alignment: WrapAlignment.start,
      // The drop-cap word stands taller than its run; bottom-aligning keeps
      // the rest of the line sitting on (near) its baseline.
      crossAxisAlignment: WrapCrossAlignment.end,
      children: [
        for (var w = start; w < end; w++)
          GestureDetector(
            onTap: () => _seekToWord(w),
            onLongPress: () => _openDefinitionSheet(doc.words[w], w),
            child: _flowWord(doc, w, base, theme, space),
          ),
      ],
    );
  }

  /// The translated line's own quiet style — subordinate to the
  /// original, the same italic-body idiom [_segmentTile] already uses
  /// for a figure caption (its own kind of secondary text under a
  /// primary element).
  ///
  /// [lit] marks the translation of the sentence being read or heard (1.5.8:
  /// word timings don't map across languages, so it lights whole). The
  /// block's [last] line leaves the gap below to the paragraph spacing,
  /// so a translated paragraph ends no further from the next than any.
  Widget _translatedLine(String text, ThemeData theme,
          {Key? key, bool lit = false, bool last = false}) =>
      Padding(
        padding: EdgeInsets.only(
            top: kTranslationGapAbove, bottom: last ? 0 : kTranslationGapBelow),
        child: _litBox(lit, theme, Text(text,
            key: key,
            // Arabic (and any other right-to-left target) reads from the
            // right even under a left-to-right original.
            textDirection: isRightToLeft(_activeTranslationLang)
                ? TextDirection.rtl
                : null,
            style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: readerTypefaceFontFamily(ReaderTypeface.lora),
                package: kReaderFontPackage,
                fontStyle: FontStyle.italic,
                height: kTranslationLineHeight,
                color: lit
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.onSurfaceVariant))),
      );

  Widget _litBox(bool lit, ThemeData theme, Widget child) => lit
      ? DecoratedBox(
          key: const Key('translation-lit'),
          decoration: BoxDecoration(
              color: theme.colorScheme.tertiaryContainer,
              borderRadius: BorderRadius.circular(4)),
          child: child)
      : child;

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
            key: Key('translation-${block.idx}-$i'),
            last: i == sentences.length - 1));
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
  ///
  /// Neither highlight changes a word's size (1.5.9): a bold face or a
  /// padded box widened the lit words, so every step shoved the rest of
  /// the line along and could rewrap the paragraph under the reader's
  /// eye. The band is painted out into the gap beside the word instead;
  /// a lit sentence's bands meet across the gaps as one.
  ///
  /// The cursor's band is the strong tertiary with its own ink, not the
  /// lit sentence's pale container: the pale one all but vanished on the
  /// current paragraph's tint, and inside a lit sentence it was the same
  /// colour as the sentence (reader_cursor_contrast_test.dart pins 3:1).
  Widget _flowWord(core.TokenizedDocument doc, int w, TextStyle? base,
      ThemeData theme, double space) {
    final current = w == _wordIdx;
    final lit = _litSentence;
    final inLit = lit != null && w >= lit.$1 && w < lit.$2;
    final scheme = theme.colorScheme;
    // A link looks like one: it can be tapped.
    final linked = linkOfToken(doc.originals[w]) != null;
    final plain = linked
        ? base?.copyWith(
            color: scheme.primary, decoration: TextDecoration.underline)
        : base;
    final style = current ? base?.copyWith(color: scheme.onTertiary) : plain;
    final Widget child = w == 0
        ? DropCap(
            word: doc.words[w],
            bodyStyle: style,
            color: current ? scheme.onTertiary : null)
        : Text(doc.words[w],
            key: current ? const Key('cursor-word') : null, style: style);
    if (!current && !inLit) return child;
    final band = CustomPaint(
      key: current ? null : const Key('sentence-lit'),
      painter: WordBandPainter(
          color: current ? scheme.tertiary : scheme.tertiaryContainer,
          spread: current ? math.min(3, space / 2) : space / 2,
          radius: current ? 4 : 0),
      child: child,
    );
    return current ? KeyedSubtree(key: _cursorWordKey, child: band) : band;
  }

  /// The width of a space in [style] at the reader's text scale: the gap
  /// Line's flowing text leaves between words.
  double _wordSpace(TextStyle? style) {
    final scaler = MediaQuery.textScalerOf(context);
    return _spaceWidths.putIfAbsent((style, scaler), () {
      double width(String text) {
        final painter = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: TextDirection.ltr,
            textScaler: scaler)
          ..layout();
        final w = painter.width;
        painter.dispose();
        return w;
      }

      // The primary font's space: a word in a fallback font (Cyrillic on
      // Android) may want a slightly different gap.
      return width('a a') - width('aa');
    });
  }
}

/// A highlight band behind one flowing word, reaching [spread] into the
/// gaps either side without taking any room of its own. Public for
/// reader_cursor_contrast_test.dart, which reads its colour.
@visibleForTesting
class WordBandPainter extends CustomPainter {
  const WordBandPainter(
      {required this.color, required this.spread, required this.radius});

  final Color color;
  final double spread;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTRB(-spread, 0, size.width + spread, size.height);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)),
        Paint()..color = color);
  }

  @override
  bool shouldRepaint(WordBandPainter old) =>
      old.color != color || old.spread != spread || old.radius != radius;
}

/// The print signature (proposal-2 §12): the work's opening word sets its
/// first letter as a drop cap — outsized in Lora against the body face —
/// while staying ONE word to the reader's hand: the whole widget lives
/// inside the same tap/long-press detector as any other flowing word, so
/// seeking and the word ledger keep working on it.
class DropCap extends StatelessWidget {
  final String word;
  final TextStyle? bodyStyle;

  /// The cap's ink, when the word is the cursor's (on its band); the
  /// theme's otherwise.
  final Color? color;
  const DropCap({super.key, required this.word, this.bodyStyle, this.color});

  @override
  Widget build(BuildContext context) {
    final chars = word.characters;
    final cap = chars.take(1).toString();
    final rest = chars.skip(1).toString();
    final capStyle = Theme.of(context).textTheme.displayMedium?.copyWith(
        fontFamily: readerTypefaceFontFamily(ReaderTypeface.lora),
        package: kReaderFontPackage,
        fontWeight: FontWeight.w700,
        height: 1.0,
        color: color);
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

/// The face of a top-bar menu that names its current choice: icon, word
/// and a drop-down caret, in neutral ink, sized like an [OhBarAction]. It
/// folds (glyph and caret only) by the bar's space rule, like the actions
/// beside it. Strict C11 cannot see this word from the call site, so the
/// picker is recorded in `barLabelExemptions`.
class _BarMenuFace extends StatelessWidget {
  const _BarMenuFace({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ink = OhBarAction.inkOf(context);
    Widget face({required bool worded}) => ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: ink),
                if (worded) ...[
                  const SizedBox(width: 6),
                  Text(label,
                      maxLines: 1,
                      softWrap: false,
                      style: Theme.of(context)
                          .textTheme
                          .labelLarge
                          ?.copyWith(color: ink)),
                ],
                Icon(Icons.arrow_drop_down, color: ink),
              ],
            ),
          ),
        );
    return OhBarFoldable(
        worded: face(worded: true), folded: face(worded: false));
  }
}

/// One thing Read aloud says: a sentence in block [seg] of the page's
/// blocks, words [from, to) of that block (`to` null: to the block's end),
/// in [lang]. [sweep] false: a translation heard under its original
/// (Both), where the cursor holds the original's start instead of
/// sweeping words that aren't the ones being said.
class _SpeechUnit {
  final int seg;
  final int from;
  final int? to;
  final String text;
  final String? lang;
  final bool sweep;
  const _SpeechUnit(
      {required this.seg,
      required this.from,
      required this.to,
      required this.text,
      required this.lang,
      this.sweep = true});
}

/// Read aloud, as the media session's buttons reach it: Play reads on
/// from the sentence it stopped at, Pause and Stop stop there. There is
/// no place to seek to in a voice that is made as it goes.
class _ReadAloudClient implements SessionClient {
  _ReadAloudClient(this._reader);
  final _ReaderScreenState _reader;

  @override
  Future<void> play() async {
    if (_reader.mounted && !_reader._speaking) _reader._startSpeak();
  }

  @override
  Future<void> pause() async {
    if (_reader.mounted) await _reader._stopSpeak();
  }

  @override
  Future<void> stop() => pause();

  @override
  Future<void> seek(Duration position) async {}
}

/// The better-Japanese choice in the Translate sheet: the brain to send
/// to, and what it would cost in US cents.
class _BetterJapanese {
  const _BetterJapanese(this.ready, this.cents);
  final BrainReady ready;
  final int cents;
}
