/// What any episode list can do with its rows: play, queue, download,
/// mark played. One home so the Inbox and the podcast page can't drift,
/// and so there is still exactly one download consent path (ADR-0003
/// law 6).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../dsp/dsp_coordinator.dart';
import '../dsp/dsp_params.dart' show effectiveDspEnabled;
import '../feeds/episode_download_coordinator.dart';
import '../models/consent.dart';
import '../player/player_controller.dart';
import '../../services/device_services.dart';

typedef EpisodeEntry = ({Work work, Episode episode});

class EpisodeActions {
  final AppDatabase db;
  final int profileId;
  final PlayerController? player;
  final EpisodeDownloadCoordinator? downloader;
  final DspCoordinator? dsp;

  /// Null on the web tier: there `existsSync` throws, so no artwork or
  /// download check may touch the disk.
  final DeviceServices? services;
  final bool localMlAvailable;
  final int Function() _nowMs;

  EpisodeActions({
    required this.db,
    required this.profileId,
    this.player,
    this.downloader,
    this.dsp,
    DeviceServices? services,
    this.localMlAvailable = true,
    int Function()? nowMs,
  }) : services = localMlAvailable ? services : null,
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  bool get canDownload => localMlAvailable && downloader != null;

  /// Disk truth; false, never a throw, where there is nothing to check.
  bool isDownloaded(Episode e) {
    final url = e.enclosureUrl;
    final d = downloader;
    if (url == null || d == null) return false;
    return d.isDownloaded(e.workId, url);
  }

  /// The episode's own artwork if it was fetched, else the show's, else
  /// none. Only ever reads files ingest already wrote. Remembered until
  /// [forgetArtwork], so a row rebuilt on scroll or by a download's
  /// progress doesn't stat the disk again: a list's rows share a handful
  /// of show images between them.
  File? artworkFor(Episode e) {
    final s = services;
    if (s == null) return null;
    final key = '${e.feedId} ${e.imageUrl ?? ''}';
    if (_artwork.containsKey(key)) return _artwork[key];
    final own = e.imageUrl;
    File? found;
    if (own != null) {
      final f = s.episodeArtworkFileFor(own);
      if (f.existsSync()) found = f;
    }
    if (found == null) {
      final show = s.artworkFileFor(e.feedId);
      if (show.existsSync()) found = show;
    }
    return _artwork[key] = found;
  }

  final _artwork = <String, File?>{};

  /// Artwork lands in the background after a refresh; a screen calls this
  /// when it reloads, so newly fetched images show from then on.
  void forgetArtwork() => _artwork.clear();

  Future<void> play(Work work) async => player?.playWork(work);

  Future<void> playNext(int workId) => db.queueDao
      .playNext(profileId: profileId, workId: workId, nowMs: _nowMs());

  Future<void> playLast(int workId) => db.queueDao
      .playLast(profileId: profileId, workId: workId, nowMs: _nowMs());

  Future<void> markPlayed(int workId) =>
      db.feedsDao.markPlayed(workId, _nowMs());

  Future<void> markUnplayed(int workId) =>
      db.feedsDao.markUnplayed(profileId: profileId, workId: workId);

  /// "Play from here": this episode and the unplayed ones after it in the
  /// order the listener is looking at go to the front of Up Next, then it
  /// plays. The listener's own act, so it isn't autoplay; the queue only
  /// holds what they just asked for.
  Future<void> playFromHere(List<EpisodeEntry> ordered, int index) async {
    final start = ordered[index];
    final ids = [
      start.work.id,
      for (final e in ordered.skip(index + 1))
        if (_playable(e)) e.work.id,
    ];
    await db.queueDao
        .playNextAll(profileId: profileId, workIds: ids, nowMs: _nowMs());
    final p = player;
    if (p == null) return;
    // playWork on the episode already playing would pause it.
    if (p.current?.id == start.work.id && p.playing) return;
    await p.playWork(start.work);
  }

  /// Appends every unplayed episode in [ordered] to Up Next, in that
  /// order. Returns how many were added.
  Future<int> addUnplayed(List<EpisodeEntry> ordered) =>
      db.queueDao.playLastAll(
          profileId: profileId,
          workIds: [
            for (final e in ordered)
              if (_playable(e)) e.work.id,
          ],
          nowMs: _nowMs());

  bool _playable(EpisodeEntry e) =>
      e.episode.enclosureUrl != null && e.episode.finishedAtMs == null;

  /// The standalone Download: the same one consent chokepoint transcribe
  /// uses, then the offline DSP pass when this show asks for it. Returns
  /// whether a download actually started.
  Future<bool> download(BuildContext context, EpisodeEntry e) async {
    final url = e.episode.enclosureUrl;
    final d = downloader;
    if (url == null || d == null) return false;
    if (d.isDownloaded(e.work.id, url)) return false;
    final ok = await confirmDownload(
      context,
      items: const [
        DownloadItem('This episode’s audio (size depends on the episode)'),
      ],
    );
    if (!ok) return false;
    await d.start(workId: e.work.id, url: url, title: e.work.title);
    await _maybeProcess(e, url);
    return true;
  }

  /// Deletes the downloaded audio of each entry and stops any download
  /// still running for it. An episode in use keeps its file: the one
  /// playing now, and any with a transcribe or DSP job (running or
  /// paused), since those read the file and would fail or resume onto
  /// nothing. The row is not marked archived: that dims it, and removing
  /// a file says nothing about whether it was listened to.
  Future<({int removed, int cancelled, int kept})> removeDownloads(
      List<EpisodeEntry> entries) async {
    final s = services;
    final d = downloader;
    if (s == null || d == null) return (removed: 0, cancelled: 0, kept: 0);
    final busy = {
      ?player?.current?.id,
      for (final j in await db.jobsDao.unfinished())
        if (j.kind == 'transcribe' || j.kind == 'dsp') ?_workIdOf(j),
    };
    final running = {for (final j in d.entries) j.workId};
    var removed = 0, cancelled = 0, kept = 0;
    for (final e in entries) {
      final url = e.episode.enclosureUrl;
      if (url == null) continue;
      final file = s.audioFileFor(e.work.id, url);
      if (busy.contains(e.work.id)) {
        if (file.existsSync() || running.contains(e.work.id)) kept++;
        continue;
      }
      // Sync on purpose: real-io futures never complete under a widget
      // test's fake-async zone.
      if (file.existsSync()) {
        if (running.contains(e.work.id)) await d.dismiss(e.work.id);
        file.deleteSync();
        removed++;
      } else if (running.contains(e.work.id)) {
        await d.dismiss(e.work.id);
        cancelled++;
      }
    }
    return (removed: removed, cancelled: cancelled, kept: kept);
  }

  static int? _workIdOf(JobRow job) {
    try {
      final payload = jsonDecode(job.payloadJson);
      return payload is Map ? (payload['workId'] as num?)?.toInt() : null;
    } on FormatException {
      return null;
    }
  }

  /// "Processed on download, on this device" (ADR-0012): only after a
  /// download that actually landed a file, and only when this show's
  /// effective setting says yes.
  Future<void> _maybeProcess(EpisodeEntry e, String url) async {
    final processor = dsp;
    final d = downloader;
    if (processor == null || d == null) return;
    if (!d.isDownloaded(e.work.id, url)) return;
    final feed = await db.feedsDao.feedById(e.episode.feedId);
    final globalDefault = await db.profilesDao.dspGlobalDefault(profileId);
    final enabled = effectiveDspEnabled(
      feedOverride: feed?.dspEnabled,
      globalDefault: globalDefault,
    );
    if (!enabled) return;
    await processor.start(workId: e.work.id, title: e.work.title, url: url);
  }

  /// The menu entries every episode row shares. Screens add their own
  /// (Keep, Play from here) around these.
  List<PopupMenuEntry<String>> commonMenuItems(EpisodeEntry e) {
    final id = e.work.id;
    if (e.episode.enclosureUrl == null) return const [];
    return [
      PopupMenuItem(
          key: Key('play-next-$id'),
          value: 'play-next',
          child: const Text('Play next')),
      PopupMenuItem(
          key: Key('play-last-$id'),
          value: 'play-last',
          child: const Text('Play last')),
      if (canDownload && !isDownloaded(e.episode))
        PopupMenuItem(
            key: Key('download-$id'),
            value: 'download',
            child: const Text('Download')),
      if (e.episode.finishedAtMs == null)
        PopupMenuItem(
            key: Key('mark-played-$id'),
            value: 'mark-played',
            child: const Text('Mark played'))
      else
        PopupMenuItem(
            key: Key('mark-unplayed-$id'),
            value: 'mark-unplayed',
            child: const Text('Mark unplayed')),
    ];
  }

  /// Runs a [commonMenuItems] choice; false when [choice] isn't one, so
  /// the screen handles it.
  Future<bool> handleCommon(
      BuildContext context, String choice, EpisodeEntry e) async {
    switch (choice) {
      case 'play-next':
        await playNext(e.work.id);
      case 'play-last':
        await playLast(e.work.id);
      case 'download':
        await download(context, e);
      case 'mark-played':
        await markPlayed(e.work.id);
      case 'mark-unplayed':
        await markUnplayed(e.work.id);
      default:
        return false;
    }
    return true;
  }
}
