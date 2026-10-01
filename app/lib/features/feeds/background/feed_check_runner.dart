/// What a feed check does, wherever it runs (ADR-0018): the app's own
/// engine when it is open, the worker's when it isn't. The same steps a
/// pull-to-refresh takes, so backoff, per-host caps and dedup all hold.
library;

import '../../../db/database.dart';
import '../auto_download.dart';
import '../episode_download_coordinator.dart';
import '../feeds_repository.dart';
import 'feed_check_settings.dart';

class FeedCheckRunner {
  FeedCheckRunner({
    required this.db,
    required this.repository,
    required this.scheduler,
    required this.onDisk,
    required this.startDownload,
    this.cancelDownload,
    Future<Object?> Function(AutoDownloadPick pick)? queueDownload,
    this.requeueDownload,
  }) : queueDownload = queueDownload ??
            ((p) => recordQueuedAutoDownload(
                db, p, DateTime.now().millisecondsSinceEpoch));

  /// The one wiring both engines use, the app's and the worker's, so a
  /// pass behaves the same wherever it runs: picks queue as rows on the
  /// Jobs screen, fetches are marked auto (never resumed on a launch), and
  /// a stop hands the interrupted one back to the queue. Also sets the
  /// repository's afterCheck to ask for a pass when one has work.
  factory FeedCheckRunner.withCoordinator({
    required AppDatabase db,
    required FeedsRepository repository,
    required FeedCheckScheduler scheduler,
    required EpisodeDownloadCoordinator downloads,
  }) {
    final runner = FeedCheckRunner(
      db: db,
      repository: repository,
      scheduler: scheduler,
      onDisk: downloads.isDownloaded,
      startDownload: (p) => downloads.start(
          workId: p.workId, url: p.url, title: p.title, auto: true),
      cancelDownload: downloads.cancel,
      queueDownload: (p) =>
          downloads.queueAuto(workId: p.workId, url: p.url, title: p.title),
      requeueDownload: downloads.requeue,
    );
    repository.afterCheck = runner.requestAutoDownloadIfPending;
    return runner;
  }

  final AppDatabase db;
  final FeedsRepository repository;
  final FeedCheckScheduler scheduler;
  final bool Function(int workId, String url) onDisk;

  /// The download coordinator's start, so a fetch gets a job row, shows on
  /// the Jobs screen and resumes from its partial like a tapped one.
  final Future<Object?> Function(AutoDownloadPick pick) startDownload;

  /// Pauses one download this pass started. A stop cancels only those, so
  /// a download the listener tapped keeps going.
  final void Function(int workId)? cancelDownload;

  /// The coordinator's queueAuto: a pick becomes a paused row on the Jobs
  /// screen before anything is fetched.
  final Future<Object?> Function(AutoDownloadPick pick) queueDownload;

  /// The coordinator's requeue, for a download this pass's stop paused.
  final Future<void> Function(int workId)? requeueDownload;

  Future<bool> run(FeedCheckTask task, {StopSignal? stop}) async {
    bool stopping() => stop?.requested ?? false;
    switch (task) {
      case FeedCheckTask.check:
        await checkAll(shouldStop: stopping);
        return true;
      case FeedCheckTask.autoDownload:
        int? current;
        stop?.onRequest(() {
          final id = current;
          if (id != null) cancelDownload?.call(id);
        });
        return runAutoDownloadPass(db,
            onDisk: onDisk,
            shouldStop: stopping,
            queue: queueDownload,
            requeue: (id) async => requeueDownload?.call(id),
            start: (pick) async {
              current = pick.workId;
              try {
                return await startDownload(pick);
              } finally {
                current = null;
              }
            });
    }
  }

  /// Every reader's feeds, never forced: a feed in backoff waits its turn.
  /// One reader at a time, since the dedup pass is per reader.
  Future<void> checkAll({bool Function()? shouldStop}) async {
    for (final profile in await db.profilesDao.all()) {
      if (shouldStop?.call() ?? false) return;
      await repository.refreshAll(profile.id, shouldStop: shouldStop);
    }
  }

  /// After any finished check: ask the system for a pass, which it starts
  /// once the network is unmetered. Nothing is fetched here, so a check on
  /// mobile data never spends it on audio.
  Future<void> requestAutoDownloadIfPending() async {
    if (!scheduler.available) return;
    // Switched off means nothing runs in the background, passes included.
    if (!await FeedCheckSettings.backgroundOn(db)) return;
    if (await autoDownloadsPending(db, onDisk: onDisk)) {
      await scheduler.requestAutoDownload();
    }
  }
}
