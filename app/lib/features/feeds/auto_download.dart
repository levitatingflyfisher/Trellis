/// Auto-download (ADR-0018): for a show the listener opted in, the newest
/// few episodes that arrived since the last pass, fetched on an unmetered
/// network through the same coordinator as a tapped Download, so they show
/// on the Jobs screen and fall under the show's keep-latest eviction.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:jobs_core/jobs_core.dart';

import '../../db/database.dart';
import 'episode_download_coordinator.dart' show downloadJobId, downloadPayload;

/// At most this many per show per pass. A show that dumps a season at once
/// shouldn't fill the phone overnight.
const autoDownloadPerFeedCap = 3;

/// Never more than the show keeps: downloading three when it keeps one
/// means the next refresh evicts two, and the pass after fetches them again.
int autoDownloadCapFor(int? keepLatestAudio) => keepLatestAudio == null
    ? autoDownloadPerFeedCap
    : math.max(0, math.min(autoDownloadPerFeedCap, keepLatestAudio));

typedef AutoDownloadPick = ({int workId, String url, String title});

/// Which of [episodes] (one show's, any order) to fetch. A row is new
/// when it is above [afterWorkId] (work ids only grow, so the mark is the
/// last pass's newest row) AND published no earlier than the newest row at
/// or below the mark. A tie counts as new: some feeds stamp every item
/// with one date, and they must keep working as they did on ids alone. The id alone is not enough: a full re-parse (schema v28's)
/// re-adds back-catalogue items an old sweep deleted, with fresh ids and
/// old dates. The bound is what the feed already had at the last pass, so
/// it needs no clock and no new state; an item with no date was stamped
/// with its arrival time, so it still counts as new. Skipped: no audio,
/// already on disk, evicted by keep-latest (fetching it again fights the
/// eviction), played, or hidden as a duplicate.
List<AutoDownloadPick> pickAutoDownloads(
  List<({Work work, Episode episode})> episodes, {
  required int afterWorkId,
  required int cap,
  required bool Function(int workId, String url) onDisk,
}) {
  int? knownNewestMs;
  for (final e in episodes) {
    if (e.work.id <= afterWorkId) {
      knownNewestMs = math.max(knownNewestMs ?? e.episode.publishedAtMs,
          e.episode.publishedAtMs);
    }
  }
  final fresh = [
    for (final e in episodes)
      if (e.work.id > afterWorkId &&
          (knownNewestMs == null ||
              e.episode.publishedAtMs >= knownNewestMs) &&
          e.episode.enclosureUrl != null &&
          e.episode.archivedAtMs == null &&
          e.episode.finishedAtMs == null &&
          e.episode.dedupReason == null &&
          !onDisk(e.work.id, e.episode.enclosureUrl!))
        e,
  ]..sort((a, b) => b.episode.publishedAtMs.compareTo(a.episode.publishedAtMs));
  return [
    for (final e in fresh.take(cap))
      (workId: e.work.id, url: e.episode.enclosureUrl!, title: e.work.title),
  ];
}

/// Per-show marks, one device setting each. They belong to this device
/// (it is this device that downloads), and one row per show means two
/// connections writing marks never overwrite each other's.
class AutoDownloadMarks {
  AutoDownloadMarks(this.db);
  final AppDatabase db;

  static String keyFor(int feedId) => 'auto_download_after:$feedId';

  Future<int?> read(int feedId) async =>
      int.tryParse(await db.deviceSettingsDao.read(keyFor(feedId)) ?? '');

  Future<void> write(int feedId, int workId) =>
      db.deviceSettingsDao.write(keyFor(feedId), '$workId');

  /// The show's newest row today, so turning auto-download on fetches only
  /// what arrives from now on, never the back catalogue.
  Future<void> startFromNow(int feedId) async =>
      write(feedId, await newestWorkIdOf(feedId));

  Future<int> newestWorkIdOf(int feedId) async {
    var newest = 0;
    for (final e in await db.feedsDao.episodesOfFeed(feedId)) {
      newest = math.max(newest, e.work.id);
    }
    return newest;
  }
}

/// Turns a show's auto-download on or off. On starts the show's mark at its
/// newest row; see [AutoDownloadMarks.startFromNow].
Future<void> setFeedAutoDownload(AppDatabase db, int feedId, bool on) async {
  if (on) await AutoDownloadMarks(db).startFromNow(feedId);
  await db.feedsDao.setAutoDownload(feedId, on);
}

/// Everything one pass would fetch, show by show. A show with no mark (it
/// was opted in some way that skipped [setFeedAutoDownload], e.g. a
/// restore) gets one starting now and fetches nothing this time.
Future<List<({int feedId, int newestWorkId, List<AutoDownloadPick> picks})>>
    planAutoDownloads(AppDatabase db,
        {required bool Function(int workId, String url) onDisk}) async {
  final marks = AutoDownloadMarks(db);
  final plan = <({int feedId, int newestWorkId, List<AutoDownloadPick> picks})>[];
  for (final feed in await db.feedsDao.autoDownloadFeeds()) {
    final episodes = await db.feedsDao.episodesOfFeed(feed.id);
    var newest = 0;
    for (final e in episodes) {
      newest = math.max(newest, e.work.id);
    }
    final mark = await marks.read(feed.id);
    plan.add((
      feedId: feed.id,
      newestWorkId: newest,
      picks: mark == null
          ? const []
          : pickAutoDownloads(episodes,
              afterWorkId: mark,
              cap: autoDownloadCapFor(feed.keepLatestAudio),
              onDisk: onDisk),
    ));
  }
  return plan;
}

/// Writes [pick] as a paused, queued auto-download row, unless the
/// episode already has one. The coordinator's [queueAuto] is this plus its
/// in-memory card; tests and a pass share the row shape through here.
Future<bool> recordQueuedAutoDownload(
    AppDatabase db, AutoDownloadPick pick, int nowMs) async {
  final jobId = downloadJobId(pick.workId);
  if (await db.jobsDao.load(jobId) != null) return false;
  await db.jobsDao.save(Job(
    id: jobId,
    kind: 'download',
    state: JobState.cancelled,
    checkpoint: null,
    totalUnits: 0,
    doneUnits: 0,
    createdAtMs: nowMs,
  ));
  await db.jobsDao.setPayload(
      jobId,
      downloadPayload(
          workId: pick.workId,
          title: pick.title,
          url: pick.url,
          auto: true,
          queued: true));
  return true;
}

/// The rows the next pass owns, oldest first: picked and not started, or
/// stopped by the system rather than by the listener.
Future<List<AutoDownloadPick>> queuedAutoDownloads(AppDatabase db) async {
  final queued = <AutoDownloadPick>[];
  for (final row in await db.jobsDao.unfinished()) {
    if (row.kind != 'download' || row.state != JobState.cancelled.name) {
      continue;
    }
    final p = jsonDecode(row.payloadJson);
    if (p case {
          'workId': final int workId,
          'url': final String url,
          'auto': true,
          'queued': true,
        }) {
      queued.add((
        workId: workId,
        url: url,
        title: p['title'] as String? ?? 'Episode',
      ));
    }
  }
  return queued;
}

/// Whether a pass would fetch anything right now, so a refresh only asks
/// for one when there is work for it.
Future<bool> autoDownloadsPending(AppDatabase db,
    {required bool Function(int workId, String url) onDisk}) async {
  if ((await queuedAutoDownloads(db)).any((q) => !onDisk(q.workId, q.url))) {
    return true;
  }
  return (await planAutoDownloads(db, onDisk: onDisk))
      .any((p) => p.picks.isNotEmpty);
}

/// One pass. New picks become queued rows first, then every show's mark
/// moves to its newest row, so a pass the system kills partway neither
/// loses a pick nor picks the same row twice. Then every queued row is
/// fetched, one at a time, politely. [shouldStop] ends the pass between
/// downloads; one it stopped mid-fetch goes back in the queue. Returns
/// false while queued rows remain, which tells the system to try again.
Future<bool> runAutoDownloadPass(
  AppDatabase db, {
  required bool Function(int workId, String url) onDisk,
  required Future<Object?> Function(AutoDownloadPick pick) queue,
  required Future<Object?> Function(AutoDownloadPick pick) start,
  required Future<void> Function(int workId) requeue,
  bool Function() shouldStop = _never,
}) async {
  final plan = await planAutoDownloads(db, onDisk: onDisk);
  for (final pick in [for (final show in plan) ...show.picks]) {
    await queue(pick);
  }
  final marks = AutoDownloadMarks(db);
  for (final show in plan) {
    await marks.write(show.feedId, show.newestWorkId);
  }
  for (final pick in await queuedAutoDownloads(db)) {
    if (onDisk(pick.workId, pick.url)) continue;
    if (shouldStop()) return false;
    await start(pick);
    if (shouldStop() && !onDisk(pick.workId, pick.url)) {
      await requeue(pick.workId);
      return false;
    }
  }
  return true;
}

bool _never() => false;
