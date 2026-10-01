/// Keeps the home-screen widget's snapshot current (1.5.5) without
/// waking it on every player tick: the player notifies about five times a
/// second, and a widget redraw is a cross-process call the launcher pays
/// for. So a track change and play/pause go out at once, the position only
/// every [positionEvery] of wall time while playing, and reading progress
/// at most once per [readingEvery], its last change always landing.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../db/database.dart';
import '../player/player_controller.dart';
import 'home_widget_host.dart';
import 'widget_snapshot.dart';

class WidgetSnapshotWriter {
  WidgetSnapshotWriter({
    required this.db,
    required this.profileId,
    required this.player,
    required this.host,
    File Function(int feedId)? artworkFileFor,
    DateTime Function()? now,
    this.positionEvery = const Duration(seconds: 30),
    this.readingEvery = const Duration(seconds: 10),
  }) : _artworkFileFor = artworkFileFor,
       _now = now ?? DateTime.now;

  final AppDatabase db;
  final int profileId;
  final PlayerController player;
  final HomeWidgetHost host;
  final Duration positionEvery;
  final Duration readingEvery;
  final File Function(int feedId)? _artworkFileFor;
  final DateTime Function() _now;

  AudioCard? _audio;
  ReadingCard? _reading;

  /// What the current work's card needs beyond the player's own state,
  /// read once per work.
  ({int workId, String title, String? show, String? art, int? durationMs})?
  _meta;
  int _metaGeneration = 0;
  int? _loadingFor;
  DateTime? _lastAudioWrite;
  String? _lastPushed;

  StreamSubscription<void>? _positionsSub;
  Timer? _readingTimer;
  DateTime? _lastReadingRead;
  bool _disposed = false;

  Future<void> start() async {
    if (!host.available) return;
    player.addListener(_onPlayer);
    await _loadMeta();
    _audio = _cardFromPlayer();
    _reading = await _readReading();
    _lastReadingRead = _now();
    if (_disposed) return;
    _lastAudioWrite = _now();
    _push();
    _positionsSub = db.spineDao.positionsMoved().listen(
      (_) => _onReadingMoved(),
    );
  }

  void dispose() {
    _disposed = true;
    player.removeListener(_onPlayer);
    unawaited(_positionsSub?.cancel());
    _readingTimer?.cancel();
  }

  void _onPlayer() {
    if (_disposed) return;
    final work = player.current;
    if (work != null && work.id != _meta?.workId) {
      if (_loadingFor != work.id) {
        _loadingFor = work.id;
        unawaited(_loadMeta().then((_) => _writeAudio()));
      }
      return;
    }
    final card = _cardFromPlayer();
    final before = _audio;
    if (before == null ||
        card == null ||
        card.playing != before.playing ||
        card.loaded != before.loaded ||
        card.workId != before.workId) {
      _writeAudio(card);
      return;
    }
    if (!card.playing) {
      // A seek while paused moves the bar; nothing ticks while paused, so
      // this is rare and cheap.
      if (card.positionMs != before.positionMs) _writeAudio(card);
      return;
    }
    final last = _lastAudioWrite;
    if (last == null || _now().difference(last) >= positionEvery) {
      _writeAudio(card);
    }
  }

  void _writeAudio([AudioCard? card]) {
    if (_disposed) return;
    _audio = card ?? _cardFromPlayer();
    _lastAudioWrite = _now();
    _push();
  }

  /// The current work's card, or the last one shown, paused: the widget
  /// keeps showing what was last played after the bar is closed.
  AudioCard? _cardFromPlayer() {
    final work = player.current;
    final meta = _meta;
    if (work == null || meta == null || meta.workId != work.id) {
      final last = _audio;
      return last == null || (!last.playing && !last.loaded)
          ? last
          : AudioCard(
              workId: last.workId,
              title: last.title,
              show: last.show,
              artPath: last.artPath,
              positionMs: last.positionMs,
              durationMs: last.durationMs,
              playing: false,
              loaded: false,
            );
    }
    return AudioCard(
      workId: work.id,
      title: meta.title,
      show: meta.show,
      artPath: meta.art,
      positionMs: player.rehydratedPositionMs ?? player.position.inMilliseconds,
      durationMs:
          player.rehydratedDurationMs ??
          player.duration?.inMilliseconds ??
          meta.durationMs,
      playing: player.playing,
      loaded: player.isLoaded(work.id),
    );
  }

  Future<void> _loadMeta() async {
    final work = player.current;
    if (work == null) return;
    final generation = ++_metaGeneration;
    final episode = await db.feedsDao.episodeOf(work.id);
    final feed = episode == null
        ? null
        : await db.feedsDao.feedById(episode.feedId);
    String? art;
    if (episode != null) {
      // existsSync, not exists: an await on real IO never resolves under
      // a widget test's fake-async zone (the player's own rule).
      final file = _artworkFileFor?.call(episode.feedId);
      if (file != null && file.existsSync()) art = file.path;
    }
    if (generation != _metaGeneration) return;
    final show = feed?.title;
    _meta = (
      workId: work.id,
      title: work.title,
      show: show == null || show.isEmpty ? null : show,
      art: art,
      durationMs: episode?.durationMs,
    );
  }

  void _onReadingMoved() {
    if (_disposed || _readingTimer != null) return;
    final last = _lastReadingRead;
    final wait = last == null
        ? Duration.zero
        : readingEvery - _now().difference(last);
    _readingTimer = Timer(wait.isNegative ? Duration.zero : wait, () async {
      _lastReadingRead = _now();
      // Cleared before the read, so a change landing during it arms the
      // next one instead of being lost.
      _readingTimer = null;
      final reading = await _readReading();
      if (_disposed) return;
      _reading = reading;
      _push();
    });
  }

  Future<ReadingCard?> _readReading() async {
    final last = await db.spineDao.lastReadText(profileId);
    if (last == null) return null;
    final count = last.segmentCount;
    return ReadingCard(
      workId: last.work.id,
      title: last.work.title,
      progress: count <= 0
          ? 0
          : (last.position.segmentIdx / count).clamp(0.0, 1.0).toDouble(),
    );
  }

  void _push() {
    final snapshot = WidgetSnapshot(
      profileId: profileId,
      audio: _audio,
      reading: _reading,
    );
    final json = jsonEncode(snapshot.toJson());
    if (json == _lastPushed) return;
    _lastPushed = json;
    unawaited(host.push(snapshot));
  }
}
