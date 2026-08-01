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
  }) : _createPlayer = createPlayer,
       _now = now ?? DateTime.now,
       _haptic = haptic ?? HapticFeedback.mediumImpact,
       _accelerometerSamples = accelerometerSamples,
       _localAudioFileFor = localAudioFileFor,
       _artworkFileFor = artworkFileFor;

  final AppDatabase db;
  final int profileId;
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

  static const List<double> speeds = [1.0, 1.25, 1.5, 1.75, 2.0];

  EpisodePlayer? _player;
  final List<StreamSubscription<Object?>> _subs = [];

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
  /// [hasAlignments] gates the karaoke door.
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
  bool get playing => _player?.playing ?? false;
  Duration get position => _player?.position ?? Duration.zero;
  Duration? get duration => _player?.duration;
  double get speed => _speed;

  /// Whether the current work has synced text (karaoke is possible).
  bool get hasAlignments => _alignments.isNotEmpty;

  /// The current work's alignments — the karaoke view projects through
  /// these.
  List<core.Alignment> get alignments => _alignments;

  /// Re-read the current work's alignments — called when a transcription
  /// lands mid-playback so the karaoke door opens without a restart.
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
    _subs.add(
      p.positionStream.listen((_) {
        unawaited(_tickSleepTimer());
        unawaited(_tickOutroCutoff());
        notifyListeners();
      }),
    );
    _subs.add(p.playingStream.listen((_) => notifyListeners()));
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
    final outroSeconds = _currentFeed?.skipOutroSeconds;
    if (outroSeconds == null || outroSeconds <= 0) return;
    final p = _player;
    final dur = p?.duration;
    if (p == null || dur == null) return;
    final cutoff = dur - Duration(seconds: outroSeconds);
    if (p.position >= cutoff) await _finish();
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
  /// A pref naming a work that no longer exists is the ORDINARY case, not
  /// an edge one — this app deletes ephemera on a decay timer — so it is
  /// cleared rather than left to dangle and re-fail every future boot.
  ///
  /// A no-op if something is already current (a normal play already
  /// happened this session; there is nothing stale to rehydrate over).
  Future<void> rehydrateLastPlayed() async {
    if (_current != null) return;
    final prefs = await db.profilesDao.readerPrefs(profileId);
    final workId = prefs.lastPlayedWorkId;
    if (workId == null) return;
    final work = await db.spineDao.workById(workId);
    if (work == null) {
      await db.profilesDao.setReaderPrefs(
          profileId, prefs.copyWith(clearLastPlayedWorkId: true));
      return;
    }
    _current = work;
    _pausedAtMs = null;
    _finishHandled = false;
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
    } else {
      _rehydratedPositionMs = await _resumeMs(work.id);
    }
    notifyListeners();
  }

  /// Play an episode work; called on the current one it toggles. The
  /// `_player != null` half of the guard (Campaign 9 Phase 2) is what lets
  /// [toggle]'s own rehydrated-work fallback reach this body instead of
  /// bouncing back into itself: [rehydrateLastPlayed] can set [_current]
  /// without ever creating a player, so `_current?.id == work.id` alone is
  /// no longer proof that toggling (rather than loading) is the right verb.
  Future<void> playWork(Work work) async {
    if (_current?.id == work.id && _player != null) return toggle();
    final url = work.sourceUrl;
    if (url == null || url.isEmpty) return;

    if (_current != null) await saveProgress();
    final p = _ensurePlayer();
    _current = work;
    _pausedAtMs = null;
    await db.profilesDao.recordLastPlayed(profileId, work.id);
    _finishHandled = false;
    // Campaign 7 (ADR-0013): a previous audiobook load's state must never
    // leak into an episode/text-work load — this IS the mode switch every
    // audiobook-aware method below reads.
    _currentAudiobookFiles = null;
    _currentAudiobookSettings = null;
    _currentFileIdx = null;
    await p.setVolume(1.0); // a prior sleep-timer fade never leaks in
    _alignments = [
      for (final a in await db.spineDao.alignmentsOf(work.id))
        core.Alignment(
          segmentIdx: a.segmentIdx,
          tStartMs: a.tStartMs,
          tEndMs: a.tEndMs,
        ),
    ];
    final episode = await db.feedsDao.episodeOf(work.id);
    _currentFeed = episode == null
        ? null
        : await db.feedsDao.feedById(episode.feedId);
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
    if (local != null && local.existsSync()) {
      await p.setFilePath(local.path, mediaItem: trackInfo);
    } else {
      await p.setUrl(url, mediaItem: trackInfo);
    }
    final resumeMs = await _resumeMs(work.id);
    final introSeconds = _currentFeed?.skipIntroSeconds;
    if (resumeMs > 0) {
      await p.seek(Duration(milliseconds: resumeMs));
    } else if (introSeconds != null && introSeconds > 0) {
      // Only on a fresh start — never re-applied on a resume, so pausing
      // partway through the intro and coming back doesn't re-skip it.
      await p.seek(Duration(seconds: introSeconds));
    }
    await p.setSpeed(_currentFeed?.speedOverride ?? _speed);
    await db.feedsDao.markRead(work.id, _nowMs);
    await p.play();
    notifyListeners();
  }

  /// Play (or, if already current, toggle) an audiobook — the multi-file
  /// counterpart to [playWork] (Campaign 7, ADR-0013). Loads the WHOLE
  /// file list as one gapless playlist ([EpisodePlayer.setFilePaths]);
  /// from there the engine advances through files on its own — see that
  /// method's own doc comment for what that means for [position]/
  /// [duration]/[completedStream]. Resumes from the stored (fileIdx, tMs)
  /// position, or file 0 offset 0 for a book never opened before.
  Future<void> playAudiobook(Work work) async {
    if (_current?.id == work.id && _player != null) return toggle();
    final files = await db.audiobooksDao.filesOf(work.id);
    if (files.isEmpty) return;
    if (_current != null) await saveProgress();
    final resume = await db.feedsDao.playerPosition(
      profileId: profileId,
      workId: work.id,
    );
    await _loadAudiobook(
      work,
      files,
      startFileIdx: resume?.fileIdx ?? 0,
      startMs: resume?.tMs ?? 0,
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
    final files = await db.audiobooksDao.filesOf(work.id);
    if (files.isEmpty) return;
    if (_current != null && _current!.id != work.id) await saveProgress();
    await _loadAudiobook(
      work,
      files,
      startFileIdx: fileIdx,
      startMs: positionMs,
    );
  }

  Future<void> _loadAudiobook(
    Work work,
    List<AudiobookFileRow> files, {
    required int startFileIdx,
    required int startMs,
  }) async {
    final p = _ensurePlayer();
    _current = work;
    _currentAudiobookFiles = files;
    _currentFeed = null;
    _pausedAtMs = null;
    _finishHandled = false;
    await db.profilesDao.recordLastPlayed(profileId, work.id);
    await p.setVolume(1.0); // a prior sleep-timer fade never leaks in
    // Phase 3 (ADR-0013) note: a transcribed audiobook's alignments would
    // need a cross-file axis the reader's single-file cursor law doesn't
    // have yet — left empty here on purpose, not wired.
    _alignments = const [];
    _currentAudiobookSettings = await db.audiobooksDao.audiobookOf(work.id);
    final clampedIdx = startFileIdx.clamp(0, files.length - 1);
    // Campaign 9 Phase 2e (ADR-0015 Decision 3): no album — an audiobook
    // has no feed to name one from — and no artwork source this pass
    // (Phase 5's artworkFileFor is feed-keyed; audiobooks carry none
    // today). Honest, not overclaiming: id/title alone still beat the
    // player's own generic "no title" fallback the lock screen would
    // otherwise show.
    final trackInfo = lockScreenTagFor(work);
    await p.setFilePaths(
      [for (final f in files) f.path],
      initialIndex: clampedIdx,
      initialPosition: Duration(milliseconds: startMs),
      mediaItem: trackInfo,
    );
    // Set synchronously too — the engine's own currentIndexStream tick
    // may not have fired yet by the time a caller reads currentFileIdx
    // right after this returns.
    _currentFileIdx = clampedIdx;
    await p.setSpeed(_currentAudiobookSettings?.speedOverride ?? _speed);
    await p.play();
    notifyListeners();
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
      final pausedAt = _pausedAtMs;
      if (pausedAt != null) {
        final rewind = smartResumeRewind(
          Duration(milliseconds: _nowMs - pausedAt),
        );
        await p.seek(_clamp(p.position - rewind));
        _pausedAtMs = null;
      }
      await p.play();
    }
    notifyListeners();
  }

  Future<void> seekTo(Duration position) async {
    final p = _player;
    if (p == null) return;
    await p.seek(_clamp(position));
    notifyListeners();
  }

  Future<void> seekBy(Duration delta) async {
    final p = _player;
    if (p == null) return;
    await p.seek(_clamp(p.position + delta));
    notifyListeners();
  }

  Duration _clamp(Duration d) {
    if (d < Duration.zero) return Duration.zero;
    final max = _player?.duration;
    if (max != null && d > max) return max;
    return d;
  }

  Future<void> cycleSpeed() async {
    _speed = speeds[(speeds.indexOf(_speed) + 1) % speeds.length];
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
  Future<void> saveProgress() async {
    final work = _current;
    final p = _player;
    if (work == null || p == null) return;
    final tMs = p.position.inMilliseconds;
    if (isAudiobook) {
      await db.feedsDao.savePlayerPosition(
        profileId: profileId,
        workId: work.id,
        tMs: tMs,
        fileIdx: _currentFileIdx ?? 0,
      );
    } else if (_alignments.isNotEmpty) {
      final pos = _spine().positionAtAudioTime(tMs);
      await db.spineDao.savePosition(
        profileId: profileId,
        workId: work.id,
        segmentIdx: pos.segmentIdx,
        wordIdx: 0,
        lastModality: 'listen',
      );
    } else {
      await db.feedsDao.savePlayerPosition(
        profileId: profileId,
        workId: work.id,
        tMs: tMs,
      );
    }
  }

  Future<void> stop() async {
    final p = _player;
    if (p == null) return;
    if (p.playing) await p.pause();
    await saveProgress();
    _current = null;
    _alignments = const [];
    _pausedAtMs = null;
    _currentAudiobookFiles = null;
    _currentAudiobookSettings = null;
    _currentFileIdx = null;
    notifyListeners();
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
  Future<void> _finish() async {
    if (_finishHandled) return;
    _finishHandled = true;
    final p = _player;
    if (p != null && p.playing) await p.pause();
    final work = _current;
    if (work != null) {
      await db.spineDao.promoteWork(work.id);
      await db.spineDao.markFinished(
        work.id,
        _nowMs ~/ Duration.millisecondsPerDay,
      );
      await saveProgress();
    }
    // An end-of-episode timer's target WAS this completion — consumed.
    // A duration timer has no such tie to any one episode; it keeps
    // running into whatever plays next (Phase 3's auto-advance).
    if (_sleepMode == SleepTimerMode.endOfEpisode) {
      await p?.setVolume(1.0);
      cancelSleepTimer();
    }
    if (work != null) await _advanceQueue(work.id);
    notifyListeners();
  }

  /// The Up Next law (P4 mercy #3): finishing removes the episode from the
  /// queue by default — a household setting can keep it instead — then
  /// auto-advances to whatever is now at the head. Playing the head goes
  /// through the ordinary [playWork], so the next episode's own per-feed
  /// settings (speed, skip-intro/outro) apply exactly as they would if the
  /// reader had tapped Play themselves.
  Future<void> _advanceQueue(int finishedWorkId) async {
    final keep = await db.profilesDao.keepFinishedInQueue(profileId);
    if (!keep) {
      await db.queueDao.remove(profileId: profileId, workId: finishedWorkId);
    }
    final head = await db.queueDao.headOf(profileId);
    if (head == null) return;
    final next = await db.spineDao.workById(head.workId);
    if (next == null) return;
    // Campaign 7 (ADR-0013): an audiobook work carries no sourceUrl for
    // playWork's single-file law to stream — it needs the multi-file
    // door instead.
    if (next.kind == 'audiobook') {
      await playAudiobook(next);
    } else {
      await playWork(next);
    }
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
