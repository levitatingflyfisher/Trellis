/// Episode playback under the cursor law (ADR-0002).
///
/// Listening progress is a projection concern: when the work has alignments
/// the controller writes the SAME Position row the reader reads (time →
/// segmentIdx via loom_core), so "stop listening in the car, resume reading
/// at the same sentence" is a row read. Without alignments the honest
/// fallback is a raw tMs in player_positions — never a fabricated segment.
///
/// Finishing an episode (playing it to the end) is one of the user's three
/// promoting hands (ADR-0003 law 2: extract, pin, or finish).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:loom_core/loom_core.dart' as core;

import '../../db/database.dart';
import 'episode_player.dart';
import 'media_item_mapping.dart';
import 'shake_detector.dart';
import 'sleep_timer.dart';
import 'smart_resume.dart';
import 'speed_control.dart' show clampSpeed, maxSpeed, minSpeed;

/// How a fetch begun for Play ended (1.6.0); see
/// [PlayerController.playWork].
enum FetchEnd { landed, failed, paused }

/// What the player has to say about a Play that could not simply play.
enum PlayNotice { downloadingFirst, waitingForWifi, downloadFailed }

class PlayerController extends ChangeNotifier {
  PlayerController({
    required this.db,
    required this.profileId,
    required EpisodePlayer Function() createPlayer,
    DateTime Function()? now,
    Future<void> Function()? haptic,
    Stream<AccelerationSample> Function()? accelerometerSamples,
    File Function(int workId, String url)? localAudioFileFor,
    File Function(int feedId)? artworkFileFor,
    Future<bool> Function()? downloadFirst,
    Future<Future<FetchEnd>?> Function(Work work, String url)? beginFetch,
  }) : _createPlayer = createPlayer,
       _downloadFirst = downloadFirst,
       _beginFetch = beginFetch,
       _now = now ?? DateTime.now,
       _haptic = haptic ?? HapticFeedback.mediumImpact,
       _accelerometerSamples = accelerometerSamples,
       _localAudioFileFor = localAudioFileFor,
       _artworkFileFor = artworkFileFor;

  final AppDatabase db;
  final int profileId;

  /// "Play on an episode that isn't downloaded" (1.6.0, user: "Play for
  /// download then play"): whether the listener chose Download first.
  /// Null, as in tests and on the web, Play streams as it always has.
  final Future<bool> Function()? _downloadFirst;

  /// Starts fetching [work]'s audio for a Play. Null back means it
  /// cannot start now (it waits for Wi-Fi, and is queued for it);
  /// otherwise how the fetch ended.
  final Future<Future<FetchEnd>?> Function(Work work, String url)? _beginFetch;

  /// Told when a Play could not simply play, for the shell to say so in
  /// words where the listener is looking.
  void Function(PlayNotice notice)? onNotice;

  /// Bumped by every Play the listener presses and by X, so a fetch
  /// that lands after they asked for something else does not start
  /// playing.
  int _playIntent = 0;
  final EpisodePlayer Function() _createPlayer;
  final DateTime Function() _now;

  /// Campaign 6's local-file law: null (every caller before this campaign,
  /// and every test that doesn't ask for it) means "always stream" — the
  /// exact behavior this app had before a local copy of anything existed.
  /// Wired callers pass `services.audioFileFor`, the SAME path resolver
  /// eviction deletes from and the DSP pipeline promotes into — whichever
  /// of those wrote there last IS what plays.
  final File Function(int workId, String url)? _localAudioFileFor;

  /// Campaign 9 Phase 2e (ADR-0015 Decision 3): resolves a feed's own
  /// downloaded artwork file, mirroring [_localAudioFileFor]'s injection
  /// shape exactly — null (the web tier, and every test that doesn't ask
  /// for it) means "no artwork source," never a dart:io call where none
  /// works. Wired callers pass `services.artworkFileFor`, the SAME
  /// deterministic path Phase 5c's river thumbnail already reads.
  final File Function(int feedId)? _artworkFileFor;

  /// The sleep timer's "shortly before stop" mercy — Flutter's own SDK
  /// call, not a plugin, so it needs no platform channel a bare unit test
  /// would choke on; injectable so a test can count calls instead.
  final Future<void> Function() _haptic;

  /// Where shake-to-extend reads live acceleration from — null (the
  /// default, and what every test but the shake ones uses) means the
  /// device has no accelerometer wired and shaking is simply unavailable.
  /// Never called until a duration-mode timer actually arms, so no test
  /// that doesn't ask for it ever touches a platform channel.
  final Stream<AccelerationSample> Function()? _accelerometerSamples;

  EpisodePlayer? _player;
  final List<StreamSubscription<Object?>> _subs = [];

  /// Bumped by [stop] and by every new load: a load begun before sees the
  /// change when its awaits return and gives up, rather than start the
  /// sound under a closed bar or seek the next episode to its own place.
  int _loadGen = 0;

  /// Whether the player stands at the listener's place. False from the
  /// start of a load until the resume seek lands: the engine sits at zero
  /// meanwhile, and saving then wrote zero over the saved place (1.5.9,
  /// X while buffering).
  bool _placeKnown = false;

  /// How often the place is written while playing (1.5.9, user: "I'll
  /// listen for 30 minutes, leave, come back, and I've lost my place").
  /// Only the app's own Pause used to write it; a pause from the lock
  /// screen, the notification, a headset or the widget reached the engine
  /// alone, and a process the system later killed took the session with it.
  static const saveEvery = Duration(seconds: 10);

  /// When the place was last written, on [_now]'s clock; null until this
  /// load's first write.
  int? _lastSavedAtMs;

  /// The place as last heard from the engine while it played, as last set
  /// by this app's own seek, or as an outside scrub left it while paused.
  /// See [_placeMs] for why the engine's word alone is not enough.
  int? _heardMs;

  /// The audiobook file [_heardMs] is in: the engine moves on to the next
  /// file on its own, and an offset into one file is no place in another.
  int? _heardFileIdx;

  /// Whether the engine played when last looked at, so the moment it
  /// stops is seen once, whichever of its streams says so first.
  bool _enginePlaying = false;

  /// What the engine reported as it stopped: just_audio's stale snap-back
  /// (see [_placeMs]). Any other position it reports while stopped is the
  /// engine speaking: ExoPlayer's own word on where it paused, or a scrub
  /// on the lock screen or the notification.
  int? _snapMs;

  void _hear(int ms) {
    _heardMs = ms;
    _heardFileIdx = _currentFileIdx;
  }

  /// Notes the engine starting or stopping, whoever did it. A stop sets
  /// the smart-resume clock: an outside pause earns the same rewind as
  /// the app's own.
  void _notePlaying(EpisodePlayer p) {
    final now = p.playing;
    if (now == _enginePlaying) return;
    _enginePlaying = now;
    if (now) {
      _snapMs = null;
    } else {
      _snapMs = p.position.inMilliseconds;
      if (_placeKnown) _pausedAtMs = _nowMs;
    }
  }

  /// Where the listener is. The engine's own position, except once
  /// something outside the app (the lock screen, the notification) has
  /// stopped it: just_audio then drops back to its last event, often where
  /// this stretch of playing began, until the engine reports again, and
  /// after the notification's Stop it never does (seen on the emulator,
  /// 1.5.9). The place heard while playing is the truth then.
  int _placeMs(EpisodePlayer p) {
    final engine = p.position.inMilliseconds;
    final heard = _heardMs;
    if (p.playing || heard == null) return engine;
    if (isAudiobook && _heardFileIdx != _currentFileIdx) return engine;
    return engine < heard - 1000 ? heard : engine;
  }

  /// The release [stop] began, while the old player is still letting go.
  /// Background audio allows one player per process, so a load waits for
  /// it before making the next.
  Future<void>? _releasing;

  Work? _current;
  List<core.Alignment> _alignments = const [];
  double _speed = 1.0;

  /// The current episode's feed row — read once in [playWork], not on
  /// every tick, so per-podcast settings (speed override, skip-intro,
  /// skip-outro) cost one query per episode start, not one per second.
  Feed? _currentFeed;

  /// Campaign 7 (ADR-0013): the current work's ordered file list — null
  /// unless a [playAudiobook]/[playAudiobookAt] load is active. This is
  /// the mode switch every audiobook-aware method below branches on,
  /// mirroring how [_currentFeed] marks an episode load.
  List<AudiobookFileRow>? _currentAudiobookFiles;

  /// The current audiobook's settings row (per-book speed override) —
  /// read once per load, same reasoning as [_currentFeed].
  AudiobookRow? _currentAudiobookSettings;

  /// Which playlist entry is current, kept in sync by
  /// [EpisodePlayer.currentIndexStream] — the file axis of the position
  /// law (ADR-0013). Null outside an audiobook load.
  int? _currentFileIdx;

  /// Whether the current work is playing through the multi-file audiobook
  /// path — the mini player's Chapters door gates on this exactly like
  /// [hasAlignments] gates the mini player's Page door.
  bool get isAudiobook => _currentAudiobookFiles != null;

  /// The current audiobook's ordered files, for a Chapters screen to walk
  /// — null outside an audiobook load.
  List<AudiobookFileRow>? get currentAudiobookFiles => _currentAudiobookFiles;

  /// The current audiobook's active file index — null outside an
  /// audiobook load.
  int? get currentFileIdx => _currentFileIdx;

  /// Guards the "finish" hand (promote + mark finished) against firing
  /// twice for one episode: the outro cutoff and the player's own natural
  /// completion are two independent producers for the same event. Reset
  /// per [playWork].
  bool _finishHandled = false;

  /// Whether this episode's played fact is already stamped this load, so
  /// the last-30-seconds check costs one write, not one per tick.
  bool _playedStamped = false;

  /// How close to the end counts as played (ADR-0016): credits and
  /// sign-offs shouldn't leave an episode looking unfinished.
  static const playedWithin = Duration(seconds: 30);

  /// When the current episode was paused (smart resume) — null when playing
  /// or when nothing has been paused this session. Cleared on a fresh
  /// [playWork] so a stale value from a previous episode never leaks in.
  int? _pausedAtMs;

  /// Campaign 9 Phase 2 ("resume after restart"): the saved position for
  /// [_current], read cheaply from disk by [rehydrateLastPlayed] BEFORE any
  /// real audio has loaded — [position]/[duration] stay at their ordinary
  /// no-player defaults on purpose (a misleading full-width slider is worse
  /// than a bar the mini player renders as a plain "Paused at mm:ss" line
  /// instead). Cleared the moment a real [EpisodePlayer] is created (see
  /// [_ensurePlayer]), since the live player's own position takes over
  /// from there.
  int? _rehydratedPositionMs;

  /// Non-null only while [_current] is a rehydrated-but-not-yet-loaded work
  /// — see [_rehydratedPositionMs]'s own doc for why this stays separate
  /// from [position].
  int? get rehydratedPositionMs =>
      _player == null ? _rehydratedPositionMs : null;

  /// The rehydrated work's duration as last learned from a real play
  /// (episode row, or the resumed audiobook file), so the paused bar's
  /// slider can sit where the listener actually is. Null when it was never
  /// learned; the bar then keeps the slider at zero and relies on the
  /// "Paused at" caption alone.
  int? _rehydratedDurationMs;
  int? get rehydratedDurationMs =>
      _player == null ? _rehydratedDurationMs : null;

  // ── sleep timer ──
  //
  // Lives here, not in a widget, so it survives screen navigation. Driven
  // off the SAME positionStream tick playback already produces rather than
  // a wall-clock Timer of its own — see sleep_timer.dart's library comment
  // for why that keeps it testable with a scripted player and nothing else.
  SleepTimerMode? _sleepMode;
  Duration? _sleepDuration;
  int? _sleepStartedAtMs;
  Duration _sleepExtra = Duration.zero;
  bool _sleepHapticFired = false;
  ShakeDetector? _shakeDetector;
  StreamSubscription<void>? _shakeSub;

  SleepTimerMode? get sleepTimerMode => _sleepMode;

  /// Time left before the timer stops playback, or null when no timer is
  /// armed. In [SleepTimerMode.duration] this counts down in wall-clock
  /// time from when it was armed (plus any shake-to-extend); in
  /// [SleepTimerMode.endOfEpisode] it is simply what's left of the episode.
  Duration? get sleepTimerRemaining {
    final mode = _sleepMode;
    if (mode == null) return null;
    if (mode == SleepTimerMode.duration) {
      final started = _sleepStartedAtMs;
      final target = _sleepDuration;
      if (started == null || target == null) return null;
      final elapsed = Duration(milliseconds: _nowMs - started);
      final remaining = (target + _sleepExtra) - elapsed;
      return remaining.isNegative ? Duration.zero : remaining;
    }
    final dur = duration;
    if (dur == null) return null;
    final remaining = dur - position;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Arms the sleep timer. Null [duration] means "stop at the end of the
  /// current episode" rather than a fixed clock target.
  void startSleepTimer({Duration? duration}) {
    _sleepMode = duration == null
        ? SleepTimerMode.endOfEpisode
        : SleepTimerMode.duration;
    _sleepDuration = duration;
    _sleepStartedAtMs = _nowMs;
    _sleepExtra = Duration.zero;
    _sleepHapticFired = false;
    _armShakeDetector();
    notifyListeners();
  }

  void cancelSleepTimer() {
    _sleepMode = null;
    _sleepDuration = null;
    _sleepStartedAtMs = null;
    _sleepExtra = Duration.zero;
    _sleepHapticFired = false;
    _disarmShakeDetector();
    notifyListeners();
  }

  /// Listens for shakes only while a duration-mode timer is live — an
  /// end-of-episode timer has nothing for a shake to extend, so it's never
  /// worth even opening the accelerometer stream for one.
  void _armShakeDetector() {
    _disarmShakeDetector();
    if (_sleepMode != SleepTimerMode.duration) return;
    final factory = _accelerometerSamples;
    if (factory == null) return;
    final detector = ShakeDetector(samples: factory(), now: _now);
    _shakeDetector = detector;
    _shakeSub = detector.shakes.listen((_) => extendSleepTimer());
  }

  void _disarmShakeDetector() {
    unawaited(_shakeSub?.cancel());
    _shakeSub = null;
    unawaited(_shakeDetector?.dispose());
    _shakeDetector = null;
  }

  /// Shake to extend: +10 minutes. Duration mode only — an end-of-episode
  /// timer has no clock target to push back.
  void extendSleepTimer() {
    if (_sleepMode != SleepTimerMode.duration) return;
    _sleepExtra += const Duration(minutes: 10);
    _sleepHapticFired = false; // past the warning point once already
    notifyListeners();
  }

  /// Applies the fade, fires the one-shot haptic, and — duration mode
  /// only — pauses and clears the timer once it reaches zero. End-of-episode
  /// mode never pauses here: the episode's own natural completion is its
  /// only stop, so [_onCompleted] does the clearing instead.
  Future<void> _tickSleepTimer() async {
    final mode = _sleepMode;
    if (mode == null) return;
    final remaining = sleepTimerRemaining;
    if (remaining == null) return;
    final p = _player;
    if (p == null) return;
    await p.setVolume(sleepTimerFadeVolume(remaining));
    if (!_sleepHapticFired && remaining <= const Duration(seconds: 3)) {
      _sleepHapticFired = true;
      unawaited(_haptic());
    }
    if (mode == SleepTimerMode.duration && remaining <= Duration.zero) {
      await p.pause();
      await saveProgress();
      await p.setVolume(1.0);
      cancelSleepTimer();
    }
  }

  Work? get current => _current;

  /// The current episode's show, for the bar's "Go to show"; null for a
  /// work with no feed (an audiobook, a read-aloud text).
  Feed? get currentFeed => _currentFeed;

  /// The current show's artwork on disk, or null (none downloaded, no
  /// feed, or the web tier, where no artwork source is wired). Looked up
  /// once per show per load, not on every rebuild of the bar.
  File? get currentArtwork {
    final feed = _currentFeed;
    if (feed == null) return null;
    if (_artworkFeedId != feed.id) {
      _artworkFeedId = feed.id;
      final file = _artworkFileFor?.call(feed.id);
      _artwork = file != null && file.existsSync() ? file : null;
    }
    return _artwork;
  }

  int? _artworkFeedId;
  File? _artwork;

  bool get playing => _player?.playing ?? false;
  Duration get position => _player?.position ?? Duration.zero;
  Duration? get duration => _player?.duration;
  double get speed => _speed;

  /// Whether the current work has synced text (karaoke is possible).
  bool get hasAlignments => _alignments.isNotEmpty;

  /// The current work's alignments — the reader's follow-along projects through
  /// these.
  List<core.Alignment> get alignments => _alignments;

  /// Re-read the current work's alignments — called when a transcription
  /// lands mid-playback so the Page door opens without a restart.
  Future<void> reloadAlignments(int workId) async {
    if (_current?.id != workId) return;
    _alignments = [
      for (final a in await db.spineDao.alignmentsOf(workId))
        core.Alignment(
          segmentIdx: a.segmentIdx,
          tStartMs: a.tStartMs,
          tEndMs: a.tEndMs,
        ),
    ];
    notifyListeners();
  }

  int get _nowMs => _now().millisecondsSinceEpoch;

  EpisodePlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final p = _createPlayer();
    _player = p;
    // A real player now owns position/duration — the rehydrated snapshot
    // (Campaign 9 Phase 2) has served its purpose.
    _rehydratedPositionMs = null;
    _rehydratedDurationMs = null;
    _enginePlaying = p.playing;
    _subs.add(
      p.positionStream.listen((at) {
        _notePlaying(p);
        final ms = at.inMilliseconds;
        var movedWhilePaused = false;
        if (_placeKnown) {
          if (p.playing) {
            _hear(ms);
          } else if (ms != _snapMs && !p.idle) {
            // Stopped, the engine reports only when something moved it
            // (or to correct its snap-back): that is the place now, and
            // a process killed while paused must not lose it.
            _hear(ms);
            movedWhilePaused = true;
          }
        }
        unawaited(_tickSleepTimer());
        unawaited(_tickOutroCutoff());
        unawaited(_tickPlayed());
        unawaited(_tickSave());
        if (movedWhilePaused) _saveSoon();
        notifyListeners();
      }),
    );
    // Whoever stopped the sound (this app, the lock screen, the
    // notification's Stop, a headset, another app taking the audio), the
    // place is written then: the app may never run again to do it later.
    _subs.add(p.playingStream.listen((playing) {
      _notePlaying(p);
      if (!playing) _saveSoon();
      notifyListeners();
    }));
    _subs.add(p.durationStream.listen(_onDuration));
    _subs.add(p.completedStream.listen((_) => _finish()));
    // Campaign 7 (ADR-0013): the ONLY way `_currentFileIdx` changes once
    // a playlist is loaded — the engine advances files on its own, this
    // just keeps the position law's file axis in sync with wherever it
    // landed.
    _subs.add(p.currentIndexStream.listen((i) => _currentFileIdx = i));
    return p;
  }

  /// Per-feed "stop/advance at duration-minus-outro": once the position
  /// crosses that line, this is treated as the episode finishing — the
  /// SAME hand as playing all the way to the true end, just early enough
  /// to skip whatever outro the feed's owner set aside.
  Future<void> _tickOutroCutoff() async {
    // Mid-switch the engine still reports the last episode's place and
    // length: past its cutoff, which would finish the next one unheard.
    if (!_placeKnown) return;
    final outroSeconds = _currentFeed?.skipOutroSeconds;
    if (outroSeconds == null || outroSeconds <= 0) return;
    final p = _player;
    final dur = p?.duration;
    if (p == null || dur == null) return;
    final cutoff = dur - Duration(seconds: outroSeconds);
    if (p.position >= cutoff) await _finish();
  }

  /// The periodic write while playing; see [saveEvery]. The gap is taken
  /// either way round: a clock set back mid-session must not stall it.
  Future<void> _tickSave() async {
    if (!playing || !_placeKnown) return;
    final last = _lastSavedAtMs;
    if (last != null && (_nowMs - last).abs() < saveEvery.inMilliseconds) {
      return;
    }
    await _saveLogged();
  }

  /// A save nobody waits for (a stream listener's): a failure is logged,
  /// not left to the zone as an unhandled error.
  void _saveSoon() => unawaited(_saveLogged());

  Future<void> _saveLogged() => saveProgress().catchError((Object e) {
        debugPrint('Player: saving the listening place failed: $e');
      });

  /// Marks the episode played once it is within [playedWithin] of the
  /// end, without stopping it: the listener still hears the tail.
  Future<void> _tickPlayed() async {
    // Mid-switch the engine still reports the last episode's place.
    if (_playedStamped || isAudiobook || !_placeKnown) return;
    final p = _player;
    final dur = p?.duration;
    final work = _current;
    if (p == null || dur == null || work == null) return;
    // A trailer shorter than the window would count as played at once;
    // it waits for the finish hand instead.
    if (dur <= playedWithin || p.position < dur - playedWithin) return;
    _playedStamped = true;
    await db.feedsDao.setFinished(work.id, _nowMs);
  }

  /// Campaign 9 Phase 2 ("resume after restart"): user: "when I pause or
  /// close the play bar it's hard to find what I was playing." Reads
  /// [ReaderPrefs.lastPlayedWorkId] and, if it still names a real work,
  /// makes the mini bar show it PAUSED at the saved position — never
  /// creates a real [EpisodePlayer], never touches the network or a local
  /// file, and never calls play(). The actual load happens lazily, the
  /// first time [toggle] is tapped, so a cold boot alone never starts a
  /// download or a stream on its own.
  ///
  /// A pref naming a work that no longer exists (its feed unfollowed, the
  /// book removed) is cleared rather than left to dangle and re-fail every
  /// future boot.
  ///
  /// A no-op if something is already current (a normal play already
  /// happened this session; there is nothing stale to rehydrate over).
  ///
  /// A bar closed with X stays closed at launch; [evenIfClosed] is for an
  /// explicit Play elsewhere (the home-screen widget) that names it again.
  Future<void> rehydrateLastPlayed({bool evenIfClosed = false}) async {
    if (_current != null) return;
    final prefs = await db.profilesDao.readerPrefs(profileId);
    final workId = prefs.lastPlayedWorkId;
    if (workId == null) return;
    if (prefs.playerClosed && !evenIfClosed) return;
    final work = await db.spineDao.workById(workId);
    if (work == null) {
      await db.profilesDao.updateReaderPrefs(
          profileId, (p) => p.copyWith(clearLastPlayedWorkId: true));
      return;
    }
    _current = work;
    _pausedAtMs = null;
    _finishHandled = false;
    _playedStamped = false;
    _alignments = [
      for (final a in await db.spineDao.alignmentsOf(work.id))
        core.Alignment(
            segmentIdx: a.segmentIdx, tStartMs: a.tStartMs, tEndMs: a.tEndMs),
    ];
    final episode = await db.feedsDao.episodeOf(work.id);
    _currentFeed =
        episode == null ? null : await db.feedsDao.feedById(episode.feedId);
    final audiobookFiles = await db.audiobooksDao.filesOf(work.id);
    if (audiobookFiles.isNotEmpty) {
      _currentAudiobookFiles = audiobookFiles;
      _currentAudiobookSettings = await db.audiobooksDao.audiobookOf(work.id);
      final resume = await db.feedsDao
          .playerPosition(profileId: profileId, workId: work.id);
      _currentFileIdx =
          (resume?.fileIdx ?? 0).clamp(0, audiobookFiles.length - 1);
      _rehydratedPositionMs = resume?.tMs ?? 0;
      _rehydratedDurationMs = audiobookFiles[_currentFileIdx!].durationMs;
    } else {
      _rehydratedPositionMs = await _resumeMs(work.id);
      _rehydratedDurationMs = episode?.durationMs;
    }
    notifyListeners();
  }

  /// Play an episode work; called on the current one it toggles. The
  /// `_player != null` half of the guard (Campaign 9 Phase 2) is what lets
  /// [toggle]'s own rehydrated-work fallback reach this body instead of
  /// bouncing back into itself: [rehydrateLastPlayed] can set [_current]
  /// without ever creating a player, so `_current?.id == work.id` alone is
  /// no longer proof that toggling (rather than loading) is the right verb.
  /// [startAt], when given, replaces the resume point and the intro skip,
  /// so the first sound is from there: see [playWorkAt].
  ///
  /// With "Download first" chosen, a Play the listener presses on an
  /// episode that isn't on disk fetches it and plays once it has landed;
  /// what was playing plays on meanwhile. [auto] is the queue moving on
  /// by itself, which streams whatever the setting: nobody pressed
  /// anything, and a fetch that had to wait would leave the queue silent.
  Future<void> playWork(Work work,
      {Duration? startAt, bool auto = false}) async {
    if (_current?.id == work.id && _player != null) return toggle();
    final url = work.sourceUrl;
    if (url == null || url.isEmpty) return;
    // The queue moving on is nobody's new wish: it leaves a Play that
    // is still downloading to start when it lands.
    if (!auto) {
      final intent = ++_playIntent;
      if (!await _fetchedFirst(work, url, intent)) return;
      // Asking is itself a wait, even when nothing is fetched: an X or
      // another Play pressed during it has already won.
      if (intent != _playIntent) return;
    }

    final gen = ++_loadGen;
    if (_current != null) await saveProgress();
    await _awaitRelease();
    if (gen != _loadGen) return;
    final p = _ensurePlayer();
    _placeKnown = false;
    _lastSavedAtMs = null;
    _heardMs = null;
    _heardFileIdx = null;
    _snapMs = null;
    _artworkFeedId = null;
    _current = work;
    _pausedAtMs = null;
    await db.profilesDao.recordLastPlayed(profileId, work.id);
    if (gen != _loadGen) return;
    _finishHandled = false;
    _playedStamped = false;
    // Campaign 7 (ADR-0013): a previous audiobook load's state must never
    // leak into an episode/text-work load — this IS the mode switch every
    // audiobook-aware method below reads.
    _currentAudiobookFiles = null;
    _currentAudiobookSettings = null;
    _currentFileIdx = null;
    await p.setVolume(1.0); // a prior sleep-timer fade never leaks in
    final alignments = [
      for (final a in await db.spineDao.alignmentsOf(work.id))
        core.Alignment(
          segmentIdx: a.segmentIdx,
          tStartMs: a.tStartMs,
          tEndMs: a.tEndMs,
        ),
    ];
    final episode = await db.feedsDao.episodeOf(work.id);
    final feed = episode == null
        ? null
        : await db.feedsDao.feedById(episode.feedId);
    // Cancelled meanwhile: what stop cleared stays cleared.
    if (gen != _loadGen) return;
    _alignments = alignments;
    _currentFeed = feed;
    // Campaign 9 Phase 2e (ADR-0015 Decision 3): the lock-screen/tray tag
    // for whichever loader runs below — built once, from the SAME feed
    // row just resolved, so the album name and the per-podcast settings
    // above it never disagree about which feed this episode belongs to.
    final artFile =
        episode == null ? null : _artworkFileFor?.call(episode.feedId);
    final trackInfo =
        lockScreenTagFor(work, album: _currentFeed?.title, artworkFile: artFile);
    // The local file IS the episode once one exists on disk; stream
    // otherwise. `existsSync` on purpose (never `exists`): a real-IO await
    // here would never resolve under a widget test's fake-async zone (the
    // same law `dismiss`'s sync delete already follows in the transcribe
    // coordinator).
    final local = _localAudioFileFor?.call(work.id, url);
    try {
      if (local != null && local.existsSync()) {
        await p.setFilePath(local.path, mediaItem: trackInfo);
      } else {
        await p.setUrl(url, mediaItem: trackInfo);
      }
    } catch (_) {
      // X during the load releases the player, which interrupts it.
      if (gen != _loadGen) return;
      rethrow;
    }
    if (gen != _loadGen) return;
    final resumeMs = await _resumeMs(work.id);
    if (gen != _loadGen) return;
    final introSeconds = _currentFeed?.skipIntroSeconds;
    // A place at the very end is nowhere to resume: see [playedOutWithin].
    final playedOut = _playedOut(
        resumeMs, p.duration?.inMilliseconds ?? episode?.durationMs);
    if (startAt != null) {
      await p.seek(startAt);
    } else if (resumeMs > 0 && !playedOut) {
      await p.seek(Duration(milliseconds: resumeMs));
    } else if (introSeconds != null && introSeconds > 0) {
      // Only on a fresh start — never re-applied on a resume, so pausing
      // partway through the intro and coming back doesn't re-skip it.
      await p.seek(Duration(seconds: introSeconds));
    }
    if (gen != _loadGen) return;
    _placeKnown = true;
    await p.setSpeed(_currentFeed?.speedOverride ?? _speed);
    await db.feedsDao.markRead(work.id, _nowMs);
    if (gen != _loadGen) return;
    await p.play();
    notifyListeners();
  }

  /// Whether [work] may load now. False when Download first applies and
  /// the fetch is waiting for Wi-Fi, failed, was paused, or landed after
  /// the listener asked for something else ([intent] is no longer the
  /// newest).
  Future<bool> _fetchedFirst(Work work, String url, int intent) async {
    final begin = _beginFetch;
    final local = _localAudioFileFor?.call(work.id, url);
    if (begin == null || local == null || local.existsSync()) return true;
    if (!(await _downloadFirst?.call() ?? false)) return true;
    if (intent != _playIntent) return false;
    final landing = await begin(work, url);
    if (intent != _playIntent) return false;
    if (landing == null) {
      onNotice?.call(PlayNotice.waitingForWifi);
      return false;
    }
    onNotice?.call(PlayNotice.downloadingFirst);
    final end = await landing;
    if (intent != _playIntent) return false;
    switch (end) {
      case FetchEnd.landed:
        return true;
      case FetchEnd.failed:
        onNotice?.call(PlayNotice.downloadFailed);
        return false;
      case FetchEnd.paused:
        return false;
    }
  }

  /// Play (or, if already current, toggle) an audiobook — the multi-file
  /// counterpart to [playWork] (Campaign 7, ADR-0013). Loads the WHOLE
  /// file list as one gapless playlist ([EpisodePlayer.setFilePaths]);
  /// from there the engine advances through files on its own — see that
  /// method's own doc comment for what that means for [position]/
  /// [duration]/[completedStream]. Resumes from the stored (fileIdx, tMs)
  /// position, or file 0 offset 0 for a book never opened before.
  Future<void> playAudiobook(Work work, {bool auto = false}) async {
    if (_current?.id == work.id && _player != null) return toggle();
    if (!auto) _playIntent++;
    final gen = ++_loadGen;
    final files = await db.audiobooksDao.filesOf(work.id);
    if (files.isEmpty || gen != _loadGen) return;
    if (_current != null) await saveProgress();
    final resume = await db.feedsDao.playerPosition(
      profileId: profileId,
      workId: work.id,
    );
    var startFileIdx = resume?.fileIdx ?? 0;
    var startMs = resume?.tMs ?? 0;
    // Played to the end of its last file: Play starts the book again.
    if (startFileIdx >= files.length - 1 &&
        _playedOut(startMs, files.last.durationMs)) {
      startFileIdx = 0;
      startMs = 0;
    }
    await _loadAudiobook(
      gen,
      work,
      files,
      startFileIdx: startFileIdx,
      startMs: startMs,
    );
  }

  /// The study crown's audiobook analogue of a capture jump: starts (or
  /// re-anchors) playback at an EXACT (fileIdx, offset) — [CapturesScreen]
  /// uses this for a bookmark that names a specific file, which
  /// [playWork]'s plain resume-then-seek shape cannot express (there is
  /// no single "the" position to resume when a book has more than one
  /// file). Always reloads the playlist positioned at the target rather
  /// than trying to distinguish "already there" from "needs a jump" —
  /// simple and always correct, at the cost of a redundant reload on the
  /// rare case both already matched.
  Future<void> playAudiobookAt(
    Work work, {
    required int fileIdx,
    required int positionMs,
  }) async {
    final gen = ++_loadGen;
    final files = await db.audiobooksDao.filesOf(work.id);
    if (files.isEmpty || gen != _loadGen) return;
    if (_current != null && _current!.id != work.id) await saveProgress();
    await _loadAudiobook(
      gen,
      work,
      files,
      startFileIdx: fileIdx,
      startMs: positionMs,
    );
  }

  Future<void> _loadAudiobook(
    int gen,
    Work work,
    List<AudiobookFileRow> files, {
    required int startFileIdx,
    required int startMs,
  }) async {
    await _awaitRelease();
    if (gen != _loadGen) return;
    final p = _ensurePlayer();
    _placeKnown = false;
    _lastSavedAtMs = null;
    _heardMs = null;
    _heardFileIdx = null;
    _snapMs = null;
    _current = work;
    _currentAudiobookFiles = files;
    _currentFeed = null;
    _pausedAtMs = null;
    _finishHandled = false;
    _playedStamped = false;
    await db.profilesDao.recordLastPlayed(profileId, work.id);
    if (gen != _loadGen) return;
    await p.setVolume(1.0); // a prior sleep-timer fade never leaks in
    // Phase 3 (ADR-0013) note: a transcribed audiobook's alignments would
    // need a cross-file axis the reader's single-file cursor law doesn't
    // have yet — left empty here on purpose, not wired.
    _alignments = const [];
    final settings = await db.audiobooksDao.audiobookOf(work.id);
    if (gen != _loadGen) return;
    _currentAudiobookSettings = settings;
    final clampedIdx = startFileIdx.clamp(0, files.length - 1);
    // Campaign 9 Phase 2e (ADR-0015 Decision 3): no album — an audiobook
    // has no feed to name one from — and no artwork source this pass
    // (Phase 5's artworkFileFor is feed-keyed; audiobooks carry none
    // today). Honest, not overclaiming: id/title alone still beat the
    // player's own generic "no title" fallback the lock screen would
    // otherwise show.
    final trackInfo = lockScreenTagFor(work);
    try {
      await p.setFilePaths(
        [for (final f in files) f.path],
        initialIndex: clampedIdx,
        initialPosition: Duration(milliseconds: startMs),
        mediaItem: trackInfo,
      );
    } catch (_) {
      if (gen != _loadGen) return;
      rethrow;
    }
    if (gen != _loadGen) return;
    // Set synchronously too — the engine's own currentIndexStream tick
    // may not have fired yet by the time a caller reads currentFileIdx
    // right after this returns.
    _currentFileIdx = clampedIdx;
    // The playlist opened at the saved place itself; no seek to wait for.
    _placeKnown = true;
    await p.setSpeed(_currentAudiobookSettings?.speedOverride ?? _speed);
    if (gen != _loadGen) return;
    await p.play();
    notifyListeners();
  }

  /// Waits out a release [stop] began, so the next player is made only once
  /// the old one is gone. The caller checks its generation after: a newer
  /// load or another X meanwhile means this load gives up.
  Future<void> _awaitRelease() async {
    final releasing = _releasing;
    if (releasing != null) await releasing;
  }

  /// Where to pick the work up: the reader's Position row projected through
  /// the alignments when they exist, else the raw player position.
  Future<int> _resumeMs(int workId) async {
    if (_alignments.isNotEmpty) {
      final pos = await db.spineDao.position(
        profileId: profileId,
        workId: workId,
      );
      if (pos == null) return 0;
      return _spine().projectAudioTime(
        core.Position(
          segmentIdx: pos.segmentIdx,
          wordIdx: pos.wordIdx,
          lastModality: core.Modality.listen,
        ),
      );
    }
    final raw = await db.feedsDao.playerPosition(
      profileId: profileId,
      workId: workId,
    );
    return raw?.tMs ?? 0;
  }

  core.Spine _spine() =>
      core.Spine(segments: const [], layers: const [], alignments: _alignments);

  /// Whether [workId] is the work loaded in the player now. Not merely
  /// [current]: a work rehydrated after a restart is current before any
  /// audio has loaded, and a seek on it would go nowhere.
  bool isLoaded(int workId) => _current?.id == workId && _player != null;

  /// Plays [work] from [at], loading it first if it isn't the work in the
  /// player: what tapping a transcript line does. Never a toggle, and a
  /// paused episode resumes from [at] itself, with no smart-resume rewind.
  Future<void> playWorkAt(Work work, Duration at) async {
    final p = _player;
    if (p == null || _current?.id != work.id) {
      return playWork(work, startAt: at);
    }
    _pausedAtMs = null;
    await _seek(p, _clamp(at));
    await saveProgress();
    if (!p.playing) await p.play();
    notifyListeners();
  }

  /// The study crown's "Listen from here" verb: starts (or, if [work] is
  /// already playing, jumps) playback at the audio time [position] projects
  /// to via the alignments. Deliberately never a toggle — unlike [playWork]
  /// re-tapped on the current work, this is always a jump, because the
  /// reader is asking to hand off its OWN cursor, not to pause the player.
  /// A work with no alignments still starts playing (the honest fallback
  /// [playWork] already has); there is simply nothing to project through,
  /// so no seek happens.
  Future<void> listenFrom(Work work, core.Position position) async {
    if (_current?.id != work.id) {
      await playWork(work);
    } else if (!(_player?.playing ?? false)) {
      await toggle();
    }
    if (_alignments.isEmpty) return;
    final tMs = _spine().projectAudioTime(position);
    await seekTo(Duration(milliseconds: tMs));
  }

  Future<void> toggle() async {
    final p = _player;
    if (p == null) {
      // Campaign 9 Phase 2: a rehydrated-but-not-yet-loaded work (see
      // [rehydrateLastPlayed]) has no live player yet — the FIRST tap of
      // Play is what actually loads it, from the position already on
      // disk. Nothing to do if [_current] is null too (the ordinary
      // "nothing has ever played" case this method always handled).
      final work = _current;
      if (work == null) return;
      if (_currentAudiobookFiles != null) {
        await playAudiobook(work);
      } else {
        await playWork(work);
      }
      return;
    }
    if (p.playing) {
      await p.pause();
      await saveProgress();
      _pausedAtMs = _nowMs;
    } else {
      final place = Duration(milliseconds: _placeMs(p));
      if (_playedOut(place.inMilliseconds, p.duration?.inMilliseconds) &&
          _atLastFile) {
        return _startOver(p);
      }
      final pausedAt = _pausedAtMs;
      if (pausedAt != null) {
        final rewind = smartResumeRewind(
          Duration(milliseconds: _nowMs - pausedAt),
        );
        await _seek(p, _clamp(place - rewind));
        _pausedAtMs = null;
      } else if (place != p.position) {
        // Stopped from outside: the engine would start again from where
        // the last stretch began.
        await _seek(p, place);
      }
      await p.play();
    }
    notifyListeners();
  }

  /// How close to the end a place counts as played out. Play there starts
  /// the work again (1.6.0, user: "clicking play on the widget doesn't
  /// always work"): it used to step two seconds back, play that tail and
  /// stop, which on the widget looked like a Play that did nothing.
  static const playedOutWithin = Duration(seconds: 1);

  bool _playedOut(int placeMs, int? totalMs) =>
      totalMs != null &&
      totalMs > playedOutWithin.inMilliseconds &&
      placeMs >= totalMs - playedOutWithin.inMilliseconds;

  /// A book's end is its last file's.
  bool get _atLastFile {
    final files = _currentAudiobookFiles;
    return files == null || (_currentFileIdx ?? 0) >= files.length - 1;
  }

  /// Play on a work that has played out: from the beginning, past the
  /// intro as any fresh start is. Its next ending is a finish again.
  Future<void> _startOver(EpisodePlayer p) async {
    final work = _current;
    if (work == null) return;
    _pausedAtMs = null;
    if (isAudiobook) {
      return playAudiobookAt(work, fileIdx: 0, positionMs: 0);
    }
    _finishHandled = false;
    final intro = _currentFeed?.skipIntroSeconds;
    await _seek(p, Duration(seconds: intro != null && intro > 0 ? intro : 0));
    await saveProgress();
    await p.play();
    notifyListeners();
  }

  Future<void> seekTo(Duration position) async {
    final p = _player;
    if (p == null) return;
    await _seek(p, _clamp(position));
    await saveProgress();
    notifyListeners();
  }

  Future<void> seekBy(Duration delta) async {
    final p = _player;
    if (p == null) return;
    await _seek(p, _clamp(Duration(milliseconds: _placeMs(p)) + delta));
    await saveProgress();
    notifyListeners();
  }

  /// This app's own seek: the place is where it was sent.
  Future<void> _seek(EpisodePlayer p, Duration to) async {
    await p.seek(to);
    if (identical(p, _player)) _hear(to.inMilliseconds);
  }

  Duration _clamp(Duration d) {
    if (d < Duration.zero) return Duration.zero;
    final max = _player?.duration;
    if (max != null && d > max) return max;
    return d;
  }

  /// The one speed setter: clamped to [minSpeed]..[maxSpeed] in tenths.
  /// ExoPlayer keeps pitch at any speed (just_audio's default), so 4× is
  /// fast, not chipmunk.
  Future<void> setSpeed(double speed) async {
    _speed = clampSpeed(speed);
    await _player?.setSpeed(_speed);
    notifyListeners();
  }

  /// The study crown, Phase 2: saves a capture (episode + position +
  /// created-at) at the CURRENT playback position — the "Capture" verb.
  /// [CapturesDao.capture] does the sentence-snap when alignments already
  /// exist; a work with no transcript yet still saves, unbound, and
  /// [CapturesDao.backfillForWork] binds it later. Null (never a throw)
  /// when nothing is playing — a capture needs a moment to capture.
  ///
  /// Campaign 7 (ADR-0013): for a multi-file audiobook, [positionMs] alone
  /// is ambiguous — it also names [_currentFileIdx], the file it's
  /// relative to.
  Future<int?> capture() async {
    final work = _current;
    final p = _player;
    if (work == null || p == null) return null;
    return db.capturesDao.capture(
      profileId: profileId,
      workId: work.id,
      positionMs: p.position.inMilliseconds,
      nowMs: _nowMs,
      fileIdx: isAudiobook ? (_currentFileIdx ?? 0) : null,
    );
  }

  /// The cursor-law write: projection when alignments exist, raw tMs
  /// (Campaign 7: file-index-tagged for an audiobook) when they don't.
  /// A no-op while a load hasn't reached the saved place yet: the player's
  /// zero then is not where the listener is. The one writer of the
  /// listening place: every save, timed or not, comes through here.
  Future<void> saveProgress() async {
    final work = _current;
    final p = _player;
    if (work == null || p == null || !_placeKnown) return;
    _lastSavedAtMs = _nowMs;
    await _writeProgress(work, _placeMs(p),
        fileIdx: isAudiobook ? (_currentFileIdx ?? 0) : null,
        alignments: _alignments);
  }

  /// [fileIdx] is non-null exactly for an audiobook. [readAtMs] (wall
  /// clock, the database's own stamp) marks a place read before an await:
  /// written only if nothing newer reached the row meanwhile.
  Future<void> _writeProgress(Work work, int tMs,
      {int? fileIdx,
      required List<core.Alignment> alignments,
      int? readAtMs}) async {
    if (fileIdx != null) {
      await db.feedsDao.savePlayerPosition(
        profileId: profileId,
        workId: work.id,
        tMs: tMs,
        fileIdx: fileIdx,
        readAtMs: readAtMs,
      );
    } else if (alignments.isNotEmpty) {
      final pos = core.Spine(
              segments: const [], layers: const [], alignments: alignments)
          .positionAtAudioTime(tMs);
      await db.spineDao.savePosition(
        profileId: profileId,
        workId: work.id,
        segmentIdx: pos.segmentIdx,
        wordIdx: 0,
        lastModality: 'listen',
        readAtMs: readAtMs,
      );
    } else {
      await db.feedsDao.savePlayerPosition(
        profileId: profileId,
        workId: work.id,
        tMs: tMs,
        readAtMs: readAtMs,
      );
    }
  }

  /// The bar's X: closes for good (1.5.9, user: "X doesn't reliably close
  /// the bar"). It used to return early when no player was loaded (a work
  /// restored at launch, "Paused at …"), so X did nothing there; a load in
  /// flight went on to play under the closed bar; the paused player kept
  /// the lock-screen controls alive; and the next launch restored the bar.
  /// Now it clears whatever is current, cancels any load, releases the
  /// player, and remembers the close until something plays.
  ///
  /// Everything the bar shows is cleared before the first await, so a Play
  /// tapped meanwhile starts a fresh load (which waits for the release)
  /// instead of toggling the player being let go.
  Future<void> stop() async {
    // Even with nothing shown yet, a load just begun is called off, and
    // so is a fetch that would have played when it landed.
    _playIntent++;
    final gen = ++_loadGen;
    if (_current == null && _player == null) return;
    final p = _player;
    final work = _current;
    // Read now: the place is the player's before anything is cleared.
    final save = p != null && work != null && _placeKnown
        ? (
            work: work,
            tMs: _placeMs(p),
            fileIdx: isAudiobook ? (_currentFileIdx ?? 0) : null,
            alignments: _alignments,
            readAtMs: DateTime.now().millisecondsSinceEpoch,
          )
        : null;
    _player = null;
    _placeKnown = false;
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    _current = null;
    _currentFeed = null;
    _alignments = const [];
    _pausedAtMs = null;
    _currentAudiobookFiles = null;
    _currentAudiobookSettings = null;
    _currentFileIdx = null;
    _rehydratedPositionMs = null;
    _rehydratedDurationMs = null;
    if (_sleepMode != null) cancelSleepTimer();
    notifyListeners();
    if (p != null) {
      final release = _release(p, save);
      _releasing = release;
      try {
        await release;
      } finally {
        if (identical(_releasing, release)) _releasing = null;
      }
    }
    // A Play tapped during the release already counts as playing again.
    if (gen == _loadGen) await db.profilesDao.recordPlayerClosed(profileId);
  }

  /// Pauses, saves the place read at the X, and disposes the player, so
  /// the next play makes a fresh one, as at launch. Disposing is what lets
  /// the lock screen and notification go.
  Future<void> _release(
    EpisodePlayer p,
    ({
      Work work,
      int tMs,
      int? fileIdx,
      List<core.Alignment> alignments,
      int readAtMs,
    })? save,
  ) async {
    try {
      if (p.playing) await p.pause();
      if (save != null) {
        await _writeProgress(save.work, save.tMs,
            fileIdx: save.fileIdx,
            alignments: save.alignments,
            readAtMs: save.readAtMs);
      }
    } finally {
      await p.dispose();
    }
  }

  /// Campaign 7 (ADR-0013): an audiobook's duration is learned per FILE,
  /// lazily, the first time each one actually plays — there is no single
  /// "the" duration for a multi-file book the way [Episodes.durationMs]
  /// is one number for one file. [Episodes] rows don't exist for an
  /// audiobook work at all, so writing there would be a silent no-op at
  /// best; this writes the right table instead of skipping the write.
  void _onDuration(Duration? d) {
    final work = _current;
    if (d != null && work != null) {
      if (isAudiobook) {
        unawaited(
          db.audiobooksDao
              .setFileDuration(work.id, _currentFileIdx ?? 0, d.inMilliseconds)
              .catchError((_) {}),
        );
      } else {
        unawaited(
          db.feedsDao
              .setDuration(work.id, d.inMilliseconds)
              .catchError((_) {}),
        );
      }
    }
    notifyListeners();
  }

  /// The "finish" hand: promote and stamp — reached either by playing to
  /// the true end (the player's own completedStream) or by crossing a
  /// feed's outro cutoff early ([_tickOutroCutoff]). Idempotent: whichever
  /// of those two producers gets there first wins, and [_finishHandled]
  /// (reset per [playWork]) makes the second one a no-op rather than a
  /// double promotion.
  ///
  /// An X (or another load) during its awaits wins: nothing advances.
  ///
  /// The engine is not paused first (1.6.0, user: "it doesn't autoplay
  /// the next episode"). It used to be, and a pause takes the playback
  /// service out of the foreground; behind another app or a dark screen
  /// Android then refuses to let it back, so the next episode started
  /// unprotected and the app was frozen ten seconds in. The app's own
  /// media session keeps saying "playing" from the end of one file
  /// through the load of the next (trellis_audio_handler.dart), so the
  /// service never leaves. The engine is paused only when nothing
  /// follows.
  Future<void> _finish() async {
    if (_finishHandled) return;
    _finishHandled = true;
    final gen = _loadGen;
    final p = _player;
    final work = _current;
    if (work != null) {
      await db.spineDao.promoteWork(work.id);
      await db.spineDao.markFinished(
        work.id,
        _nowMs ~/ Duration.millisecondsPerDay,
      );
      _playedStamped = true;
      await db.feedsDao.setFinished(work.id, _nowMs);
      await saveProgress();
    }
    if (gen != _loadGen) return;
    // An end-of-episode timer's target WAS this completion — consumed.
    // A duration timer has no such tie to any one episode; it keeps
    // running into whatever plays next (Phase 3's auto-advance).
    if (_sleepMode == SleepTimerMode.endOfEpisode) {
      await p?.setVolume(1.0);
      cancelSleepTimer();
    }
    var carriedOn = false;
    var failed = false;
    try {
      if (work != null) carriedOn = await _advanceQueue(work.id);
    } catch (e) {
      // Only a load that is still the newest throws (a superseded one
      // gives up quietly), so the engine here is still this one's.
      failed = true;
      debugPrint('Player: the next in the queue would not play: $e');
    }
    // Nothing follows: now the engine stops. Not when another load began
    // meanwhile; that one owns the engine.
    if (!carriedOn &&
        (failed || gen == _loadGen) &&
        p != null &&
        identical(p, _player) &&
        p.playing) {
      await p.pause();
    }
    notifyListeners();
  }

  /// Counts the times the player itself changed the queue (a finished
  /// episode leaving it), so the Queue tab can reload even when nothing
  /// new starts playing.
  int get queueRevision => _queueRevision;
  int _queueRevision = 0;

  /// The queue's law (P4 mercy #3): finishing removes the episode from the
  /// queue by default — a household setting can keep it instead — then
  /// auto-advances to whatever is now at the head. Playing the head goes
  /// through the ordinary [playWork], so the next episode's own per-feed
  /// settings (speed, skip-intro/outro) apply exactly as they would if the
  /// reader had tapped Play themselves.
  ///
  /// True when something was handed to the player to carry on with.
  Future<bool> _advanceQueue(int finishedWorkId) async {
    final keep = await db.profilesDao.keepFinishedInQueue(profileId);
    if (!keep) {
      await db.queueDao.remove(profileId: profileId, workId: finishedWorkId);
      _queueRevision++;
      notifyListeners();
    }
    final upcoming = await _upcomingAfter(finishedWorkId, keep: keep);
    if (upcoming == null) return false;
    final next = await db.spineDao.workById(upcoming.workId);
    if (next == null) return false;
    // Campaign 7 (ADR-0013): an audiobook work carries no sourceUrl for
    // playWork's single-file law to stream — it needs the multi-file
    // door instead.
    if (next.kind == 'audiobook') {
      await playAudiobook(next, auto: true);
    } else {
      await playWork(next, auto: true);
    }
    return true;
  }

  /// What the queue plays after [finishedWorkId], or null. A kept episode
  /// stays in the queue, possibly behind things queued while it played,
  /// so position says nothing: next is the first entry that isn't this
  /// one and isn't already played. Kept played ones are skipped, or two
  /// kept episodes would loop forever.
  Future<QueueRow?> _upcomingAfter(int finishedWorkId,
      {required bool keep}) async {
    for (final r in await db.queueDao.queueOf(profileId)) {
      if (r.workId == finishedWorkId) continue;
      if (keep) {
        final ep = await db.feedsDao.episodeOf(r.workId);
        if (ep?.finishedAtMs != null) continue;
      }
      return r;
    }
    return null;
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _disarmShakeDetector();
    _player?.dispose();
    super.dispose();
  }
}
