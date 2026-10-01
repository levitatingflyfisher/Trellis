/// What any list of works can do with its rows: play, queue, download,
/// mark played or finished, transcribe, share. One home so every list
/// offers the same things for the same kind of work, and so there is
/// still exactly one download consent path (ADR-0003 law 6).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../dsp/dsp_coordinator.dart';
import '../dsp/dsp_params.dart' show effectiveDspEnabled;
import '../feeds/episode_download_coordinator.dart';
import '../intake/paste_intake.dart' show epochDayUtcNow;
import '../models/consent.dart';
import '../models/format.dart' show formatBytes;
import '../models/models_screen.dart' show modelLabel;
import '../player/player_controller.dart';
import '../search/search_store.dart' show SearchItem;
import '../search/share_item.dart';
import '../transcribe/job_cards.dart';
import '../transcribe/transcribe_coordinator.dart';
import '../works/device_hooks.dart' show deviceTranscribeRate;
import '../works/work_row.dart' show WorkEntry;
import '../../services/device_services.dart';

typedef EpisodeEntry = ({Work work, Episode episode});

/// Opens a show's page. Needs the feeds repository and the player's kit,
/// which only the screens that own them can build.
typedef ShowOpener = Future<void> Function(BuildContext context, Feed feed);

class EpisodeActions {
  final AppDatabase db;
  final int profileId;
  final PlayerController? player;
  final EpisodeDownloadCoordinator? downloader;
  final DspCoordinator? dsp;

  /// Runs Transcribe and Translate; null where this tier can't.
  final TranscribeCoordinator? transcriber;

  /// The platform share; null copies to the clipboard instead.
  final ShareText? shareText;

  /// Null on the web tier: there `existsSync` throws, so no artwork or
  /// download check may touch the disk.
  final DeviceServices? services;
  final bool localMlAvailable;

  /// Opens the show a feed item came from (the work page's "From …");
  /// null where the screen can't build the show page.
  final ShowOpener? openShow;
  final int Function() _nowMs;

  /// The share of an episode's length transcribing takes here, for the
  /// "about N min" when a transcription starts; null when unknown.
  final double? Function() transcribeRate;

  EpisodeActions({
    required this.db,
    required this.profileId,
    this.player,
    this.downloader,
    this.dsp,
    this.transcriber,
    ShareText? shareText,
    bool useDefaultShare = true,
    DeviceServices? services,
    this.localMlAvailable = true,
    this.openShow,
    int Function()? nowMs,
    this.transcribeRate = deviceTranscribeRate,
  }) : services = localMlAvailable ? services : null,
       shareText = shareText ?? (useDefaultShare ? defaultShareText : null),
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  bool get canDownload => localMlAvailable && downloader != null;

  /// Disk truth; false, never a throw, where there is nothing to check.
  /// Remembered until the downloader changes or [forgetArtwork], so a
  /// list's rebuild doesn't stat a file per row.
  bool isDownloaded(Episode e) {
    final url = e.enclosureUrl;
    final d = downloader;
    if (url == null || d == null) return false;
    if (d.revision != _downloadedRevision) {
      _downloaded.clear();
      _downloadedRevision = d.revision;
    }
    return _downloaded[e.workId] ??= d.isDownloaded(e.workId, url);
  }

  final _downloaded = <int, bool>{};
  int _downloadedRevision = -1;

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
  void forgetArtwork() {
    _artwork.clear();
    _downloaded.clear();
  }

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
  /// order the listener is looking at go to the front of the queue, then it
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

  /// Appends every unplayed episode in [ordered] to the queue, in that
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
    _downloaded.clear();
    // Every list sharing the downloader offers Download again; a removed
    // file alone moves nothing they watch.
    if (removed > 0) d.notifyListeners();
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

  /// Deletes a removed audiobook's copied files (ADR-0013: removing the
  /// rows never touches disk). A no-op where there is no disk (the web).
  void deleteAudiobookFiles(int workId) {
    // Sync on purpose, as in removeDownloads: real-io futures never
    // complete under a widget test's fake-async zone.
    final dir = services?.audiobookDirFor(workId);
    if (dir != null && dir.existsSync()) dir.deleteSync(recursive: true);
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

  bool get canTranscribe => localMlAvailable && transcriber != null;

  /// Everything the ⋮ menu offers for this kind of work on every screen.
  /// Audio: queue, download, played, transcribe, share. A text (a book,
  /// an article, a feed's text item) or an audiobook: finished, share.
  /// Screens add only their own items after these.
  List<PopupMenuEntry<String>> sharedMenuItems(WorkEntry e,
      {bool transcribed = false, String? sourceLang}) {
    final id = e.work.id;
    final episode = e.episode;
    final share = PopupMenuItem<String>(
        key: Key('share-$id'), value: 'share', child: const Text('Share'));
    if (episode != null && episode.enclosureUrl != null) {
      return [
        ...commonMenuItems((work: e.work, episode: episode)),
        if (canTranscribe) ...[
          PopupMenuItem(
              key: Key('transcribe-$id'),
              value: 'transcribe',
              child: Text(episode.archivedAtMs != null
                  ? 'Re-download audio'
                  : transcribed
                      ? 'Transcribe again'
                      : 'Transcribe')),
          if (offersEnglishTranslate(
              transcribed: transcribed, sourceLang: sourceLang))
            PopupMenuItem(
                key: Key('translate-$id'),
                value: 'translate',
                child: const Text('Transcribe + translate to English')),
        ],
        share,
      ];
    }
    final finished =
        e.work.finishedEpochDay != null || episode?.finishedAtMs != null;
    return [
      finished
          ? PopupMenuItem(
              key: Key('mark-unfinished-$id'),
              value: 'mark-unfinished',
              child: const Text('Mark unfinished'))
          : PopupMenuItem(
              key: Key('mark-finished-$id'),
              value: 'mark-finished',
              child: const Text('Mark finished')),
      share,
    ];
  }

  /// Runs a [sharedMenuItems] choice; false when [choice] isn't one, so
  /// the screen handles it. [showTitle] goes into what is shared.
  Future<bool> handleShared(BuildContext context, String choice, WorkEntry e,
      {String? showTitle}) async {
    final episode = e.episode;
    if (episode != null && commonChoices.contains(choice)) {
      return handleCommon(context, choice, (work: e.work, episode: episode));
    }
    switch (choice) {
      case 'share':
        await shareItem(
            context, SearchItem(e.work, episode, showTitle), shareText);
        return true;
      case 'transcribe' || 'translate':
        if (episode == null) return true;
        await transcribe(context, (work: e.work, episode: episode),
            translate: choice == 'translate');
        return true;
      case 'mark-finished':
        // Marking, like Mark played, doesn't promote: clearing a backlog
        // must not keep all of it.
        await db.spineDao.markFinished(e.work.id, epochDayUtcNow());
        return true;
      case 'mark-unfinished':
        await db.spineDao.markUnfinished(e.work.id);
        return true;
    }
    return false;
  }

  static const commonChoices = {
    'play-next',
    'play-last',
    'download',
    'mark-played',
    'mark-unplayed',
  };

  /// The transcribe entry: plan, then the ONE consent chokepoint when
  /// anything would download (ADR-0003 law 6), then the coordinator's
  /// flow.
  Future<void> transcribe(BuildContext context, EpisodeEntry e,
      {required bool translate}) async {
    final url = e.episode.enclosureUrl;
    final coordinator = transcriber;
    if (url == null || coordinator == null) return;
    final plan =
        await coordinator.planFor(workId: e.work.id, enclosureUrl: url);
    if (!context.mounted) return;
    if (plan.needsDownloads) {
      final ok = await confirmDownload(
        context,
        items: [
          if (plan.needsModel)
            DownloadItem(
              '${modelLabel(plan.model.id)} '
              '(${formatBytes(plan.model.sizeBytes)}), one time',
            ),
          if (plan.needsAudio)
            DownloadItem('This episode’s audio (size depends on the episode)'),
        ],
      );
      if (!ok) return;
    }
    unawaited(coordinator.start(
      workId: e.work.id,
      title: e.work.title,
      enclosureUrl: url,
      lang: e.work.lang,
      translate: translate,
    ));
    // Said at once, wherever the tap was (user: "it wasn't obvious it had
    // started"); the action shows this job's card right here.
    if (!context.mounted) return;
    final estimate = transcribeEstimate(e.episode.durationMs, transcribeRate());
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        // A convenience: the job also shows on the page and in Jobs.
        persist: false,
        content: Text(estimate == 'time unknown'
            ? 'Transcribing…'
            : 'Transcribing… $estimate'),
        action: SnackBarAction(
          label: 'See progress',
          onPressed: () {
            if (!context.mounted) return;
            showModalBottomSheet<void>(
              context: context,
              showDragHandle: true,
              builder: (_) => SafeArea(
                child: TranscribeJobCards(
                    coordinator: coordinator, workId: e.work.id),
              ),
            );
          },
        ),
      ));
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

/// Whisper's translate needs no text but can only write English, so it
/// waits for a transcript as the reader's Translate does, and is never
/// offered for an English work. An unknown language is not assumed
/// English. One rule for every row's ⋮ and the work page's.
bool offersEnglishTranslate(
    {required bool transcribed, required String? sourceLang}) {
  if (!transcribed) return false;
  final base =
      sourceLang?.trim().toLowerCase().split(RegExp('[-_]')).first;
  return base != 'en';
}
