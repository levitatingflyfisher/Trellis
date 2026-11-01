/// The standalone "Download" door (Campaign 6, Part 2): onto disk without
/// requesting a transcript, over the SAME resolver `PlayerController`
/// prefers and `audio_eviction.dart` deletes from. It is also the one
/// owner of an episode's `.part`: transcription's audio stage asks this
/// coordinator rather than racing it for the same file.
///
/// One consent chokepoint (the UI calls `confirmDownload` before ever
/// calling [EpisodeDownloadCoordinator.start], ADR-0003 law 6), the fleet's
/// one download engine (`AudioFetcher`). The `.part` file is the byte
/// checkpoint (HTTP Range resumes it); the `download-<workId>` job row is
/// what remembers that a download was under way at all, so a killed app
/// finds it again instead of forgetting it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart' as dio;
import 'package:domovoi/domovoi.dart' show TransferOutcome;
import 'package:flutter/foundation.dart';
import 'package:jobs_core/jobs_core.dart';

import '../../db/database.dart';
import '../../services/device_services.dart';
import '../jobs/failure_reason.dart';
import 'auto_download.dart' show recordQueuedAutoDownload;

String downloadJobId(int workId) => 'download-$workId';

/// A download row's payload. Auto-downloads (ADR-0018) carry `auto`, and
/// `queued` while the next auto-download pass owns them: picked but not
/// started, or stopped by the system rather than by the listener. `hand`
/// marks one the listener started that waits for Wi-Fi (1.6.0): the pass
/// owns it like any queued row, but it was asked for, not picked.
String downloadPayload(
        {required int workId,
        required String title,
        required String url,
        bool auto = false,
        bool queued = false,
        bool hand = false}) =>
    jsonEncode({
      'workId': workId,
      'title': title,
      'url': url,
      if (auto) 'auto': true,
      if (queued) 'queued': true,
      if (hand) 'hand': true,
    });

enum DownloadOutcome { done, paused, failed }

/// One episode's download snapshot, as the UI reads it. The absence of an
/// entry (see [EpisodeDownloadCoordinator.stateOf]'s default) means "no
/// download job", so this type needs no idle variant.
/// How far a download has got, 0 to 1; null while one runs whose size
/// is not known yet.
double? downloadFraction(EpisodeDownloadState s) {
  final total = s.totalBytes;
  if (total == null || total == 0) return s.downloading ? null : 0;
  return ((s.receivedBytes ?? 0) / total).clamp(0, 1).toDouble();
}

/// "Downloading, 40%", or "Downloading" while the size is unknown: the
/// words where Play is while an episode downloads.
String downloadingWords(EpisodeDownloadState s) {
  final f = downloadFraction(s);
  return f == null ? 'Downloading' : 'Downloading, ${(f * 100).floor()}%';
}

class EpisodeDownloadState {
  final String title;
  final bool downloading;
  final bool paused;
  final int? receivedBytes;
  final int? totalBytes;

  /// The plain-language failure reason; set only when the download failed.
  final String? error;

  /// The failure was a lost connection: the row stays resumable, so the
  /// next launch carries on without a tap.
  final bool retriesOnLaunch;

  /// Started by hand on a metered network with "Download only on Wi-Fi"
  /// on (1.6.0): paused, and the next Wi-Fi pass will fetch it.
  final bool waitingForWifi;

  const EpisodeDownloadState({
    this.title = 'Episode',
    this.downloading = false,
    this.paused = false,
    this.receivedBytes,
    this.totalBytes,
    this.error,
    this.retriesOnLaunch = false,
    this.waitingForWifi = false,
  });

  bool get failed => error != null;
}

class _Entry {
  final String url;
  EpisodeDownloadState state;

  /// The row was still `running` at restore: a kill stopped it, not the
  /// user, so it may resume on its own.
  bool interrupted;

  /// Fetched by an auto-download pass, which only runs on an unmetered
  /// network: never resumed by a launch, which may be on mobile data.
  final bool auto;

  /// Started by the listener and left to the Wi-Fi pass ("Download only
  /// on Wi-Fi"). Kept through the pass's own fetch, so a pass the system
  /// stops hands it back still marked as asked for.
  final bool hand;
  _Entry(this.url, this.state,
      {this.interrupted = false, this.auto = false, this.hand = false});
}

class EpisodeDownloadCoordinator extends ChangeNotifier {
  final DeviceServices services;
  final AppDatabase db;
  final DateTime Function() _now;

  EpisodeDownloadCoordinator(
      {required this.services, required this.db, DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final Map<int, _Entry> _entries = {};
  final Map<int, dio.CancelToken> _tokens = {};
  final Map<int, Future<DownloadOutcome>> _inFlight = {};

  /// Bumped on every change, so a list that remembers what's on disk
  /// knows when to look again.
  int get revision => _revision;
  int _revision = 0;

  @override
  void notifyListeners() {
    _revision++;
    super.notifyListeners();
  }

  EpisodeDownloadState stateOf(int workId) =>
      _entries[workId]?.state ?? const EpisodeDownloadState();

  /// Every download job this coordinator knows of, oldest first.
  List<({int workId, EpisodeDownloadState state})> get entries => [
        for (final e in _entries.entries) (workId: e.key, state: e.value.state)
      ];

  /// Disk truth, not cached state — the same check `PlayerController` and
  /// `audio_eviction.dart` make, so this never drifts from what plays.
  bool isDownloaded(int workId, String url) =>
      services.audioFileFor(workId, url).existsSync();

  File _partOf(int workId, String url) =>
      File('${services.audioFileFor(workId, url).path}.part');

  /// The partial and the engine's `.validator` sidecar beside it, which
  /// names the bytes in the partial for If-Range: a sidecar left behind
  /// would vouch for bytes that are gone.
  void _deletePartial(int workId, String url) {
    final part = _partOf(workId, url);
    for (final f in [part, File('${part.path}.validator')]) {
      if (f.existsSync()) f.deleteSync();
    }
  }

  /// Rebuild entries from unfinished download rows. Bytes come from the
  /// `.part` on disk, the same truth the engine resumes from.
  Future<void> restore() async {
    for (final row in await db.jobsDao.unfinished()) {
      if (row.kind != 'download') continue;
      final payload = jsonDecode(row.payloadJson) as Map<String, dynamic>;
      final workId = (payload['workId'] as num?)?.toInt();
      final url = payload['url'] as String?;
      if (workId == null || url == null || _entries.containsKey(workId)) {
        continue;
      }
      final part = _partOf(workId, url);
      final failed = row.state == JobState.failed.name;
      final auto = payload['auto'] == true;
      final hand = payload['hand'] == true;
      final killed = row.state == JobState.running.name;
      if (auto && killed) {
        // Whatever stopped it, the next pass (unmetered) carries it on.
        await db.jobsDao.save(Job(
            id: row.id,
            kind: row.kind,
            state: JobState.cancelled,
            checkpoint: row.checkpoint,
            totalUnits: row.totalUnits,
            doneUnits: row.doneUnits,
            createdAtMs: row.createdAtMs));
        await db.jobsDao.setPayload(
            row.id,
            downloadPayload(
                workId: workId,
                title: payload['title'] as String? ?? 'Episode',
                url: url,
                auto: true,
                queued: true,
                hand: hand));
      }
      _entries[workId] = _Entry(
        url,
        EpisodeDownloadState(
          title: payload['title'] as String? ?? 'Episode',
          paused: !failed,
          receivedBytes: part.existsSync() ? part.lengthSync() : 0,
          totalBytes: row.totalUnits == 0 ? null : row.totalUnits,
          error: failed
              ? row.failureReason ?? genericFailureReason
              : null,
          // Handed to the pass and not failed: still waiting for Wi-Fi.
          waitingForWifi: hand &&
              !failed &&
              (killed || payload['queued'] == true),
        ),
        interrupted: killed && !auto,
        auto: auto,
        hand: hand,
      );
    }
    notifyListeners();
  }

  /// Continue every download a kill interrupted. Paused and failed ones
  /// wait for the user's hand.
  Future<void> resumeInterrupted() async {
    final killed = [
      for (final e in _entries.entries)
        if (e.value.interrupted) e.key
    ];
    await Future.wait([for (final id in killed) resume(id)]);
  }

  /// "Download only on Wi-Fi" (1.6.0, user: "download on WiFi or not" was
  /// missing). Set by the app: whether a download the listener starts
  /// must wait right now (the setting is on and the network is metered).
  /// Null, as in tests, the worker and the web build, nothing ever waits.
  Future<bool> Function()? mustWaitForWifi;

  /// Asks the system for a pass, which it runs once the network is
  /// unmetered. The same pass auto-downloads use.
  Future<void> Function()? requestWifiPass;

  Future<bool> _mustWait() async {
    try {
      return await mustWaitForWifi?.call() ?? false;
    } catch (e) {
      debugPrint('Download: could not tell whether to wait for Wi-Fi: $e');
      return false;
    }
  }

  /// Whether a download of [workId] asked for now would wait for Wi-Fi
  /// instead of starting: what [startByHand] decides by, for a caller
  /// (Play with "Download first") that has to know before it waits on
  /// the fetch.
  Future<bool> waitsForWifi(int workId, String url) async =>
      !_inFlight.containsKey(workId) &&
      !isDownloaded(workId, url) &&
      await _mustWait();

  /// A download the listener asks for. Where it must wait for Wi-Fi it
  /// becomes a queued row the next pass fetches, and nothing is fetched
  /// now; otherwise it is [start].
  Future<DownloadOutcome> startByHand(
      {required int workId,
      required String url,
      String title = 'Episode'}) async {
    if (await waitsForWifi(workId, url)) {
      return _waitForWifi(workId, url, title);
    }
    return start(workId: workId, url: url, title: title);
  }

  /// Leaves [workId] to the next Wi-Fi pass: a queued row (kept if there
  /// is one, with whatever it has fetched), and a pass asked for.
  Future<DownloadOutcome> _waitForWifi(
      int workId, String url, String title) async {
    final jobId = downloadJobId(workId);
    final row = await db.jobsDao.load(jobId);
    await db.jobsDao.save(row?.copyWith(state: JobState.cancelled) ??
        Job(
          id: jobId,
          kind: 'download',
          state: JobState.cancelled,
          checkpoint: null,
          totalUnits: 0,
          doneUnits: 0,
          createdAtMs: _now().millisecondsSinceEpoch,
        ));
    await db.jobsDao.setPayload(
        jobId,
        downloadPayload(
            workId: workId,
            title: title,
            url: url,
            auto: true,
            queued: true,
            hand: true));
    final part = _partOf(workId, url);
    _entries[workId] = _Entry(
        url,
        EpisodeDownloadState(
            title: title,
            paused: true,
            waitingForWifi: true,
            receivedBytes: part.existsSync() ? part.lengthSync() : 0,
            totalBytes: _entries[workId]?.state.totalBytes),
        auto: true,
        hand: true);
    notifyListeners();
    try {
      await requestWifiPass?.call();
    } catch (e) {
      // The row stands; the next launch asks again.
      debugPrint('Download: asking for a Wi-Fi pass failed: $e');
    }
    return DownloadOutcome.paused;
  }

  /// "Download now": this one download, whatever the network.
  Future<DownloadOutcome> startNow(int workId) {
    final entry = _entries[workId];
    if (entry == null) return Future.value(DownloadOutcome.failed);
    return start(workId: workId, url: entry.url, title: entry.state.title);
  }

  /// Continue a known download from its partial. Where a download by
  /// hand must wait for Wi-Fi, a resume waits too: the launch that
  /// resumes interrupted downloads may be on mobile data.
  Future<DownloadOutcome> resume(int workId) async {
    final entry = _entries[workId];
    if (entry == null) return DownloadOutcome.failed;
    if (!_inFlight.containsKey(workId) &&
        !isDownloaded(workId, entry.url) &&
        await _mustWait()) {
      return _waitForWifi(workId, entry.url, entry.state.title);
    }
    return start(
        workId: workId,
        url: entry.url,
        title: entry.state.title,
        auto: entry.auto);
  }

  /// Records an auto-download pick as a paused row before anything is
  /// fetched, so it shows on the Jobs screen at once and survives a pass
  /// the system stops. False when the episode already has a row or a file.
  Future<bool> queueAuto(
      {required int workId, required String url, required String title}) async {
    if (_entries.containsKey(workId) || isDownloaded(workId, url)) {
      return false;
    }
    if (!await recordQueuedAutoDownload(
        db, (workId: workId, url: url, title: title),
        _now().millisecondsSinceEpoch)) {
      return false;
    }
    final part = _partOf(workId, url);
    _entries[workId] = _Entry(
        url,
        EpisodeDownloadState(
            title: title,
            paused: true,
            receivedBytes: part.existsSync() ? part.lengthSync() : 0),
        auto: true);
    notifyListeners();
    return true;
  }

  /// Hands a download a pass stopped back to the next pass.
  Future<void> requeue(int workId) async {
    final entry = _entries[workId];
    final jobId = downloadJobId(workId);
    final row = await db.jobsDao.load(jobId);
    if (entry == null || row == null || isDownloaded(workId, entry.url)) return;
    await db.jobsDao.save(row.copyWith(state: JobState.cancelled));
    await db.jobsDao.setPayload(
        jobId,
        downloadPayload(
            workId: workId,
            title: entry.state.title,
            url: entry.url,
            auto: true,
            queued: true,
            hand: entry.hand));
    if (entry.hand) {
      _set(workId, (s) => EpisodeDownloadState(
          title: s.title,
          paused: true,
          waitingForWifi: true,
          receivedBytes: s.receivedBytes,
          totalBytes: s.totalBytes));
    }
  }

  /// Fetches [url] to `services.audioFileFor(workId, url)`. Already on
  /// disk completes at once; already in flight joins that run, so the
  /// button can be tapped freely and transcription can wait on the same
  /// fetch.
  Future<DownloadOutcome> start(
      {required int workId,
      required String url,
      String title = 'Episode',
      bool auto = false}) {
    final running = _inFlight[workId];
    if (running != null) return running;
    if (isDownloaded(workId, url)) return _alreadyHere(workId);
    final token = dio.CancelToken();
    _tokens[workId] = token;
    final part = _partOf(workId, url);
    final known = _entries[workId]?.state;
    // A pass fetching what the listener left waiting: still theirs.
    final hand = auto && (_entries[workId]?.hand ?? false);
    _entries[workId] = _Entry(
      url,
      EpisodeDownloadState(
        title: title,
        downloading: true,
        receivedBytes: part.existsSync() ? part.lengthSync() : null,
        totalBytes: known?.totalBytes,
      ),
      auto: auto,
      hand: hand,
    );
    notifyListeners();
    final future = _run(workId, url, title, token, auto: auto, hand: hand);
    _inFlight[workId] = future;
    return future;
  }

  /// The file landed but a kill beat the row's deletion: clear the ghost
  /// so it can't sit "paused" forever.
  Future<DownloadOutcome> _alreadyHere(int workId) async {
    if (_entries.remove(workId) != null) notifyListeners();
    await db.jobsDao.deleteJob(downloadJobId(workId));
    return DownloadOutcome.done;
  }

  Future<DownloadOutcome> _run(
      int workId, String url, String title, dio.CancelToken token,
      {bool auto = false, bool hand = false}) async {
    final jobId = downloadJobId(workId);
    final gate = services.foregroundGate;
    var totalSaved = false;
    var holdsGate = false;
    int? lastStep;
    try {
      final existing = await db.jobsDao.load(jobId);
      await db.jobsDao.save(Job(
        id: jobId,
        kind: 'download',
        state: JobState.running,
        checkpoint: null,
        totalUnits: existing?.totalUnits ?? 0,
        doneUnits: 0,
        createdAtMs: existing?.createdAtMs ?? _now().millisecondsSinceEpoch,
      ));
      await db.jobsDao.setPayload(
          jobId,
          downloadPayload(
              workId: workId, title: title, url: url, auto: auto, hand: hand));
      await gate.jobStarted(title, 'Downloading…');
      holdsGate = true;

      final outcome = await services.audioFetcher.fetch(
        url,
        services.audioFileFor(workId, url),
        cancelToken: token,
        onProgress: (received, total) {
          // Only the size is persisted, once; bytes live in the `.part`.
          if (!totalSaved && total != null) {
            totalSaved = true;
            unawaited(db.jobsDao.setTotalUnits(jobId, total));
          }
          // Thousands of chunks per episode: rebuild on each whole
          // percent (or each 256 kB when the size is unknown), not each
          // chunk.
          final step = total != null && total > 0
              ? received * 100 ~/ total
              : received >> 18;
          final entry = _entries[workId];
          if (entry == null) return;
          entry.state = EpisodeDownloadState(
              title: entry.state.title,
              downloading: true,
              receivedBytes: received,
              totalBytes: total ?? entry.state.totalBytes);
          entry.interrupted = false;
          if (step != lastStep) {
            lastStep = step;
            notifyListeners();
          }
        },
      );
      if (outcome == TransferOutcome.cancelled) {
        final row = await db.jobsDao.load(jobId);
        if (row != null) {
          await db.jobsDao.save(row.copyWith(state: JobState.cancelled));
        }
        _set(workId, (s) => EpisodeDownloadState(
            title: s.title,
            paused: true,
            receivedBytes: s.receivedBytes,
            totalBytes: s.totalBytes));
        return DownloadOutcome.paused;
      }
      await db.jobsDao.deleteJob(jobId);
      // P4 "archive, never forget": the audio is back on disk, so a stale
      // archived mark from an earlier eviction would be a lie.
      await db.feedsDao.setArchived(workId, null);
      _entries.remove(workId);
      return DownloadOutcome.done;
    } catch (err) {
      final reason = plainFailureReason(err);
      final transient = isTransientFailure(err);
      try {
        final row = await db.jobsDao.load(jobId);
        // A lost connection leaves a tapped download `running`, which is
        // what the next launch resumes. An auto-download goes back to the
        // pass instead, which waits for an unmetered network.
        if (row != null && transient && auto) {
          await db.jobsDao.save(row.copyWith(state: JobState.cancelled));
          await db.jobsDao.setPayload(
              jobId,
              downloadPayload(
                  workId: workId,
                  title: title,
                  url: url,
                  auto: true,
                  queued: true,
                  hand: hand));
        } else if (row != null && !transient) {
          await db.jobsDao.save(row.copyWith(state: JobState.failed));
          await db.jobsDao.setFailureReason(jobId, reason);
        }
      } catch (_) {
        // The database may be what failed; the card still says so.
      }
      if (transient && auto) {
        _set(workId, (s) => EpisodeDownloadState(
            title: s.title,
            paused: true,
            waitingForWifi: hand,
            receivedBytes: s.receivedBytes,
            totalBytes: s.totalBytes));
        return DownloadOutcome.paused;
      }
      _set(workId, (s) => EpisodeDownloadState(
          title: s.title,
          receivedBytes: s.receivedBytes,
          totalBytes: s.totalBytes,
          error: reason,
          retriesOnLaunch: transient));
      return DownloadOutcome.failed;
    } finally {
      _tokens.remove(workId);
      _inFlight.remove(workId);
      notifyListeners();
      if (holdsGate) await gate.jobFinished();
    }
  }

  /// Pause: the partial stays beside the target for a later resume.
  void cancel(int workId) {
    final token = _tokens[workId];
    if (token != null && !token.isCancelled) token.cancel();
  }

  /// Throw the download away: its row and its partial bytes.
  Future<void> dismiss(int workId) async {
    final entry = _entries.remove(workId);
    final running = _inFlight[workId];
    cancel(workId);
    if (running != null) await running;
    _entries.remove(workId);
    await db.jobsDao.deleteJob(downloadJobId(workId));
    if (entry != null) {
      // Sync on purpose: real-io futures never complete under a widget
      // test's fake-async zone.
      _deletePartial(workId, entry.url);
    }
    notifyListeners();
  }

  /// Forget the job but keep its bytes: a caller that takes over the
  /// failure (transcription's card) still resumes from the partial later.
  Future<void> dismissKeepingPartial(int workId) async {
    if (_inFlight.containsKey(workId)) return;
    _entries.remove(workId);
    await db.jobsDao.deleteJob(downloadJobId(workId));
    notifyListeners();
  }

  /// Pause everything in flight and wait until it has let go.
  Future<void> stopAll() async {
    for (final id in [..._tokens.keys]) {
      cancel(id);
    }
    await Future.wait([..._inFlight.values]);
  }

  /// After a backup restore: the restored ids name other works, so the
  /// partials are deleted, never appended to. Call after [stopAll].
  void discardAll() {
    for (final e in _entries.entries) {
      _deletePartial(e.key, e.value.url);
    }
    _entries.clear();
    notifyListeners();
  }

  void _set(
      int workId, EpisodeDownloadState Function(EpisodeDownloadState) fn) {
    final entry = _entries[workId];
    if (entry == null) return;
    entry.state = fn(entry.state);
    entry.interrupted = false;
    notifyListeners();
  }
}
