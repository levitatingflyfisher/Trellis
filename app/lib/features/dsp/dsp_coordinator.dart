/// The offline DSP preprocess's orchestration (Campaign 6, ADR-0012):
/// eligibility (the transcript-exclusivity law) -> measure the original
/// duration -> run the filter chain -> measure + sanity-check the result
/// -> atomic promote (rename onto the SAME path `PlayerController` reads
/// and `audio_eviction.dart` deletes) -> store both durations.
///
/// Reuses the checkpointed-job row `TranscribeCoordinator` uses (same
/// `JobsTable`, kind='dsp' instead of 'transcribe') and the SAME
/// foreground gate — the fleet's one "a long job survives screen-off"
/// mechanism, not a second one. Unlike transcription's executor, a
/// single ffmpeg pass has no natural sub-unit checkpoint: cancellation
/// and resume work at the SAME granularity the decode step already
/// does — checked between stages, never preemptive mid-encode; a killed
/// or cancelled run simply re-measures and re-encodes from scratch on
/// its next start, safe because nothing is promoted until the very end.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:jobs_core/jobs_core.dart';

import '../../db/database.dart';
import '../../services/device_services.dart';
import '../transcribe/transcribe_coordinator.dart' show transcribeJobId;
import 'dsp_encoder.dart';
import 'dsp_params.dart';

String dspJobId(int workId) => 'dsp-$workId';

/// A finished run has no phase of its own — its card is removed, the
/// same law `TranscribeCoordinator`'s own success path follows; "done"
/// is read off the episode's stored `dspProcessedDurationMs`, not a
/// lingering card state.
enum DspPhase { measuring, processing, paused, failed, ineligible }

class DspCardState {
  final int workId;
  final String title;
  final DspPhase phase;
  final String? error;

  const DspCardState({
    required this.workId,
    required this.title,
    required this.phase,
    this.error,
  });

  DspCardState _with({required DspPhase phase, String? error}) =>
      DspCardState(workId: workId, title: title, phase: phase, error: error);
}

class _Flow {
  bool cancelRequested = false;
  void cancel() => cancelRequested = true;
}

class DspCoordinator extends ChangeNotifier {
  final AppDatabase db;
  final DeviceServices services;
  final DateTime Function() _now;

  /// Fired once a processed file lands and both durations are stored —
  /// the UI's hook for a "saved N minutes" toast, mirroring
  /// `TranscribeCoordinator.onTranscribed`'s own shape.
  final void Function(int workId)? onProcessed;

  final Map<int, _Flow> _flows = {};
  final Map<int, DspCardState> _cards = {};

  DspCoordinator({
    required this.db,
    required this.services,
    this.onProcessed,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  List<DspCardState> get cards => List.unmodifiable(_cards.values);
  DspCardState? stateOf(int workId) => _cards[workId];
  bool isActive(int workId) => _flows.containsKey(workId);

  /// Rebuild cards from unfinished job rows — the reopened app's
  /// resumable state, same shape as `TranscribeCoordinator.restore`.
  Future<void> restore() async {
    for (final row in await db.jobsDao.unfinished()) {
      if (row.kind != 'dsp') continue;
      final payload =
          jsonDecode(await db.jobsDao.payloadOf(row.id))
              as Map<String, dynamic>;
      final workId = (payload['workId'] as num?)?.toInt();
      if (workId == null || _cards.containsKey(workId)) continue;
      _cards[workId] = DspCardState(
        workId: workId,
        title: payload['title'] as String? ?? 'Episode',
        phase: row.state == JobState.failed.name
            ? DspPhase.failed
            : DspPhase.paused,
      );
    }
    notifyListeners();
  }

  /// The transcript-exclusivity law (ADR-0012), read fresh from the DB —
  /// never cached, since a transcript or transcribe job can appear
  /// between calls.
  Future<bool> eligibleFor(int workId) async {
    final hasTranscript = (await db.spineDao.alignmentsOf(workId)).isNotEmpty;
    final transcribeJob = await db.jobsDao.load(transcribeJobId(workId));
    final hasPendingOrFailedTranscribeJob =
        transcribeJob != null && transcribeJob.state != JobState.done;
    return dspEligible(
      hasTranscript: hasTranscript,
      hasPendingOrFailedTranscribeJob: hasPendingOrFailedTranscribeJob,
    );
  }

  Future<void> start({
    required int workId,
    required String title,
    required String url,
  }) async {
    if (_flows.containsKey(workId)) return;
    // Claimed synchronously, before any `await` — a second start() call
    // arriving before this one's first suspension point must see the
    // claim, or two fetches race the same file.
    final flow = _flows[workId] = _Flow();
    if (!await eligibleFor(workId)) {
      _flows.remove(workId);
      _cards[workId] = DspCardState(
        workId: workId,
        title: title,
        phase: DspPhase.ineligible,
      );
      notifyListeners();
      return;
    }
    final jobId = dspJobId(workId);
    final payload = jsonEncode({'workId': workId, 'title': title, 'url': url});
    if (await db.jobsDao.load(jobId) == null) {
      await db.jobsDao.save(
        Job(
          id: jobId,
          kind: 'dsp',
          state: JobState.running,
          checkpoint: null,
          totalUnits: 0,
          doneUnits: 0,
          createdAtMs: _now().millisecondsSinceEpoch,
        ),
      );
    }
    await db.jobsDao.setPayload(jobId, payload);
    _cards[workId] = DspCardState(
      workId: workId,
      title: title,
      phase: DspPhase.measuring,
    );
    notifyListeners();
    await _drive(workId, title: title, url: url, jobId: jobId, flow: flow);
  }

  /// Continue a paused/failed card — re-drives from scratch (safe: never
  /// promoted until the end, so there's nothing partial to resume byte
  /// for byte, only a whole pass to retry).
  Future<void> resume(int workId) async {
    if (_flows.containsKey(workId)) return;
    final card = _cards[workId];
    if (card == null) return;
    final flow = _flows[workId] = _Flow();
    final jobId = dspJobId(workId);
    final payload =
        jsonDecode(await db.jobsDao.payloadOf(jobId)) as Map<String, dynamic>;
    final url = payload['url'] as String;
    _cards[workId] = card._with(phase: DspPhase.measuring);
    notifyListeners();
    await _drive(workId, title: card.title, url: url, jobId: jobId, flow: flow);
  }

  /// Between-stage cancel — the same law the decode step already
  /// follows: checked before the next stage starts, never preemptive of
  /// an in-flight ffmpeg call.
  void cancel(int workId) => _flows[workId]?.cancel();

  /// Throw the job away: the row, and any working-output file an
  /// interrupted run left behind (nothing else was ever written until
  /// promote, so there is nothing else to clean up).
  Future<void> dismiss(int workId) async {
    _flows[workId]?.cancel();
    final jobId = dspJobId(workId);
    final row = await db.jobsDao.load(jobId);
    if (row != null) {
      final payload =
          jsonDecode(await db.jobsDao.payloadOf(jobId)) as Map<String, dynamic>;
      final url = payload['url'] as String?;
      if (url != null) {
        final part = File(
          dspPartPathFor(services.audioFileFor(workId, url).path),
        );
        if (part.existsSync()) part.deleteSync();
      }
      await db.jobsDao.deleteJob(jobId);
    }
    final removed = _cards.remove(workId);
    if (removed != null) notifyListeners();
  }

  Future<void> _drive(
    int workId, {
    required String title,
    required String url,
    required String jobId,
    required _Flow flow,
  }) async {
    final gate = services.foregroundGate;
    try {
      await gate.jobStarted(title, 'Measuring…');
      final audio = services.audioFileFor(workId, url);
      if (!audio.existsSync()) {
        throw DspEncodeException('no downloaded audio to process for "$title"');
      }
      if (flow.cancelRequested) return await _pause(workId, jobId);

      final originalMs = await services.dspEncoder.durationMs(audio.path);
      if (flow.cancelRequested) return await _pause(workId, jobId);

      _update(workId, (c) => c._with(phase: DspPhase.processing));
      await gate.jobProgress(title, 'Trimming silence, evening out volume…');

      final ext = _extensionOf(audio.path);
      final codec = dspCodecFor(ext);
      if (codec == null) {
        throw DspEncodeException('unrecognized audio format "$ext"');
      }
      final tempPath = dspPartPathFor(audio.path);
      await services.dspEncoder.process(
        inputPath: audio.path,
        outputPath: tempPath,
        codec: codec,
        bitrate: dspBitrateFor(codec),
      );
      if (flow.cancelRequested) {
        final temp = File(tempPath);
        if (temp.existsSync()) temp.deleteSync();
        return await _pause(workId, jobId);
      }

      final processedMs = await services.dspEncoder.durationMs(tempPath);
      final tempFile = File(tempPath);
      final sizeBytes = tempFile.existsSync() ? tempFile.lengthSync() : 0;
      if (!dspOutputSane(
        originalDurationMs: originalMs,
        processedDurationMs: processedMs,
        outputSizeBytes: sizeBytes,
      )) {
        if (tempFile.existsSync()) tempFile.deleteSync();
        throw DspEncodeException(
          'processed output failed the sanity check for "$title" — '
          'original kept',
        );
      }

      // The atomic promote: rename onto the SAME path PlayerController
      // reads and audio_eviction.dart deletes — the processed file IS
      // the episode from this point on. `renameSync`, not `rename`: a
      // real-IO Future never resolves under a widget test's fake-async
      // zone (the same law TranscribeCoordinator.dismiss's own sync
      // delete already follows), and the file is small either way.
      tempFile.renameSync(audio.path);
      await db.feedsDao.setDspResult(
        workId,
        originalDurationMs: originalMs,
        processedDurationMs: processedMs,
      );

      await db.jobsDao.deleteJob(jobId);
      _cards.remove(workId);
      notifyListeners();
      onProcessed?.call(workId);
    } catch (err) {
      await _fail(workId, jobId, err);
    } finally {
      _flows.remove(workId);
      await gate.jobFinished();
    }
  }

  Future<void> _pause(int workId, String jobId) async {
    final row = await db.jobsDao.load(jobId);
    if (row != null && row.state == JobState.running) {
      await db.jobsDao.save(row.copyWith(state: JobState.cancelled));
    }
    _update(workId, (c) => c._with(phase: DspPhase.paused));
  }

  Future<void> _fail(int workId, String jobId, Object err) async {
    final row = await db.jobsDao.load(jobId);
    if (row != null && row.state == JobState.running) {
      await db.jobsDao.save(row.copyWith(state: JobState.failed));
    }
    _update(
      workId,
      (c) => c._with(phase: DspPhase.failed, error: err.toString()),
    );
  }

  void _update(int workId, DspCardState Function(DspCardState) fn) {
    final card = _cards[workId];
    if (card == null) return;
    _cards[workId] = fn(card);
    notifyListeners();
  }
}

String _extensionOf(String path) {
  final dot = path.lastIndexOf('.');
  return dot < 0 ? '' : path.substring(dot);
}
