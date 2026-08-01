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

import 'package:flutter/foundation.dart';
import 'package:loom_core/loom_core.dart' as core;

import '../../db/database.dart';
import 'episode_player.dart';

class PlayerController extends ChangeNotifier {
  PlayerController(
      {required this.db,
      required this.profileId,
      required EpisodePlayer Function() createPlayer,
      DateTime Function()? now})
      : _createPlayer = createPlayer,
        _now = now ?? DateTime.now;

  final AppDatabase db;
  final int profileId;
  final EpisodePlayer Function() _createPlayer;
  final DateTime Function() _now;

  static const List<double> speeds = [1.0, 1.25, 1.5, 1.75, 2.0];

  EpisodePlayer? _player;
  final List<StreamSubscription<Object?>> _subs = [];

  Work? _current;
  List<core.Alignment> _alignments = const [];
  double _speed = 1.0;

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
            segmentIdx: a.segmentIdx, tStartMs: a.tStartMs, tEndMs: a.tEndMs)
    ];
    notifyListeners();
  }

  int get _nowMs => _now().millisecondsSinceEpoch;

  EpisodePlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final p = _createPlayer();
    _player = p;
    _subs.add(p.positionStream.listen((_) => notifyListeners()));
    _subs.add(p.playingStream.listen((_) => notifyListeners()));
    _subs.add(p.durationStream.listen(_onDuration));
    _subs.add(p.completedStream.listen((_) => _onCompleted()));
    return p;
  }

  /// Play an episode work; called on the current one it toggles.
  Future<void> playWork(Work work) async {
    if (_current?.id == work.id) return toggle();
    final url = work.sourceUrl;
    if (url == null || url.isEmpty) return;

    if (_current != null) await saveProgress();
    final p = _ensurePlayer();
    _current = work;
    _alignments = [
      for (final a in await db.spineDao.alignmentsOf(work.id))
        core.Alignment(
            segmentIdx: a.segmentIdx, tStartMs: a.tStartMs, tEndMs: a.tEndMs)
    ];
    await p.setUrl(url);
    final resumeMs = await _resumeMs(work.id);
    if (resumeMs > 0) await p.seek(Duration(milliseconds: resumeMs));
    await p.setSpeed(_speed);
    await db.feedsDao.markRead(work.id, _nowMs);
    await p.play();
    notifyListeners();
  }

  /// Where to pick the work up: the reader's Position row projected through
  /// the alignments when they exist, else the raw player position.
  Future<int> _resumeMs(int workId) async {
    if (_alignments.isNotEmpty) {
      final pos =
          await db.spineDao.position(profileId: profileId, workId: workId);
      if (pos == null) return 0;
      return _spine().projectAudioTime(core.Position(
          segmentIdx: pos.segmentIdx,
          wordIdx: pos.wordIdx,
          lastModality: core.Modality.listen));
    }
    final raw = await db.feedsDao
        .playerPosition(profileId: profileId, workId: workId);
    return raw?.tMs ?? 0;
  }

  core.Spine _spine() => core.Spine(
      segments: const [], layers: const [], alignments: _alignments);

  Future<void> toggle() async {
    final p = _player;
    if (p == null) return;
    if (p.playing) {
      await p.pause();
      await saveProgress();
    } else {
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

  /// The cursor-law write: projection when alignments exist, raw tMs when
  /// they don't.
  Future<void> saveProgress() async {
    final work = _current;
    final p = _player;
    if (work == null || p == null) return;
    final tMs = p.position.inMilliseconds;
    if (_alignments.isNotEmpty) {
      final pos = _spine().positionAtAudioTime(tMs);
      await db.spineDao.savePosition(
          profileId: profileId,
          workId: work.id,
          segmentIdx: pos.segmentIdx,
          wordIdx: 0,
          lastModality: 'listen');
    } else {
      await db.feedsDao
          .savePlayerPosition(profileId: profileId, workId: work.id, tMs: tMs);
    }
  }

  Future<void> stop() async {
    final p = _player;
    if (p == null) return;
    if (p.playing) await p.pause();
    await saveProgress();
    _current = null;
    _alignments = const [];
    notifyListeners();
  }

  void _onDuration(Duration? d) {
    final work = _current;
    if (d != null && work != null) {
      unawaited(db.feedsDao
          .setDuration(work.id, d.inMilliseconds)
          .catchError((_) {}));
    }
    notifyListeners();
  }

  /// Played to the end — the "finish" hand: promote and stamp.
  Future<void> _onCompleted() async {
    final work = _current;
    if (work != null) {
      await db.spineDao.promoteWork(work.id);
      await db.spineDao
          .markFinished(work.id, _nowMs ~/ Duration.millisecondsPerDay);
      await saveProgress();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player?.dispose();
    super.dispose();
  }
}
