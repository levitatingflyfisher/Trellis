/// P4 "archive, never forget": episode ROWS are never deleted when a feed
/// drops them or storage is reclaimed — only downloaded AUDIO FILES are,
/// and only the ones a feed's own `keepLatestAudio` policy says to let go
/// of. This is deliberately narrower than ADR-0003's own age-based
/// ephemera sweep (which still deletes whole rows after the retention
/// window unless promoted) — that law is untouched; this one only ever
/// touches a file on disk plus one timestamp column.
library;

import 'dart:io';

import '../../db/database.dart';
import '../../services/device_services.dart';

/// Which of a feed's already-on-disk episodes should have their audio
/// evicted: oldest-published first, beyond [keepLatestAudio], excluding
/// anything in [immuneWorkIds] (queued, mid-listen, or currently playing).
/// Pure — the caller has already filtered [episodesWithAudio] down to ones
/// whose audio file actually exists.
List<int> audioEvictionCandidates({
  required List<({int workId, int publishedAtMs})> episodesWithAudio,
  required int? keepLatestAudio,
  required Set<int> immuneWorkIds,
}) {
  if (keepLatestAudio == null) return const [];
  final newestFirst = [...episodesWithAudio]
    ..sort((a, b) => b.publishedAtMs.compareTo(a.publishedAtMs));
  final beyondTheKeep = newestFirst.skip(keepLatestAudio);
  return [
    for (final e in beyondTheKeep)
      if (!immuneWorkIds.contains(e.workId)) e.workId
  ];
}

/// Runs the eviction for one feed: finds its episodes whose audio is
/// actually on disk, applies [audioEvictionCandidates] (excluding the
/// queue, anything mid-listen, and — when the caller knows it —
/// whatever's currently playing), deletes the evicted files, and marks
/// their rows archived. Returns how many were evicted. A no-op (0) when
/// the feed keeps everything (`keepLatestAudio` null) or has no audio on
/// disk to begin with.
Future<int> evictStaleAudio({
  required AppDatabase db,
  required DeviceServices services,
  required int feedId,
  required int nowMs,
  int? currentlyPlayingWorkId,
}) async {
  final feed = await db.feedsDao.feedById(feedId);
  if (feed == null || feed.keepLatestAudio == null) return 0;

  // Reuses the feed detail screen's own query (comms_core's paged-archive
  // campaign) rather than a second near-identical one — the Work half of
  // each pair goes unused here, but a duplicate FeedsDao method would be
  // the real cost.
  final episodes = await db.feedsDao.episodesOfFeed(feedId);
  final onDisk = <({int workId, int publishedAtMs})>[];
  final fileFor = <int, File>{};
  for (final entry in episodes) {
    final e = entry.episode;
    final url = e.enclosureUrl;
    if (url == null) continue;
    final file = services.audioFileFor(e.workId, url);
    if (!file.existsSync()) continue;
    fileFor[e.workId] = file;
    onDisk.add((workId: e.workId, publishedAtMs: e.publishedAtMs));
  }
  if (onDisk.isEmpty) return 0;

  final immune = <int>{};
  for (final row in await db.queueDao.queueOf(feed.profileId)) {
    immune.add(row.workId);
  }
  for (final pos in await db.feedsDao.allPlayerPositions()) {
    if (pos.tMs > 0) immune.add(pos.workId);
  }
  if (currentlyPlayingWorkId != null) immune.add(currentlyPlayingWorkId);

  final toEvict = audioEvictionCandidates(
      episodesWithAudio: onDisk,
      keepLatestAudio: feed.keepLatestAudio,
      immuneWorkIds: immune);

  for (final workId in toEvict) {
    fileFor[workId]!.deleteSync();
    await db.feedsDao.setArchived(workId, nowMs);
  }
  return toEvict.length;
}
