/// The transcription flow's conductor (proposal-2 §9): one card per
/// episode, driven through resumable stages —
///
///   model (ResumableTransfer, sha-pinned) → episode audio (ResumableTransfer)
///   → decode (Decoder seam) → transcribe [→ translate] (checkpointed
///   executor) → spine rows in one transaction.
///
/// Every stage is idempotent, so `resume` after a kill simply re-walks the
/// pipeline: finished stages verify their artifact and step over; the
/// executor continues from its committed checkpoint. Cancel stamps the row
/// and keeps everything; dismiss is the user's "throw it away".
///
/// Consent is NOT here: the UI passes the chokepoint dialog (ADR-0003 law
/// 6) before `start` is ever called — this class only ever continues what
/// the user's hand began.
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart' as dio;
import 'package:domovoi/domovoi.dart' show TransferOutcome;
import 'package:flutter/foundation.dart';
import 'package:jobs_core/jobs_core.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:transcribe_core/transcribe_core.dart';

import '../../db/database.dart';
import '../../services/device_services.dart';
import '../feeds/episode_download_coordinator.dart';
import '../jobs/failure_reason.dart';
import '../models/model_store.dart';
import 'foreground_gate.dart';
import 'transcribe_executor.dart';
import 'transcript_writer.dart';

String transcribeJobId(int workId) => 'transcribe-$workId';
String translateJobId(int workId) => 'translate-$workId';

enum TranscribePhase {
  fetchingModel,
  fetchingAudio,
  preparing,
  transcribing,
  translating,

  /// Interrupted by a kill and queued to pick itself back up; jobs resume
  /// one at a time so two whisper runs never fight over the CPU.
  waiting,
  paused,
  failed,
}

/// One job card's snapshot, as the UI reads it.
class TranscribeCardState {
  final int workId;
  final String title;
  final bool translate;
  final TranscribePhase phase;
  final int? doneUnits;
  final int? totalUnits;
  final int? etaMs;
  final int? receivedBytes;
  final int? totalBytes;
  final String? error;

  const TranscribeCardState({
    required this.workId,
    required this.title,
    required this.translate,
    required this.phase,
    this.doneUnits,
    this.totalUnits,
    this.etaMs,
    this.receivedBytes,
    this.totalBytes,
    this.error,
  });

  TranscribeCardState _with({
    required TranscribePhase phase,
    int? doneUnits,
    int? totalUnits,
    int? etaMs,
    int? receivedBytes,
    int? totalBytes,
    String? error,
  }) =>
      TranscribeCardState(
        workId: workId,
        title: title,
        translate: translate,
        phase: phase,
        doneUnits: doneUnits,
        totalUnits: totalUnits,
        etaMs: etaMs,
        receivedBytes: receivedBytes,
        totalBytes: totalBytes,
        error: error,
      );
}

/// What starting a transcription would download — the consent dialog's
/// evidence.
class TranscribePlan {
  final ModelSpec model;
  final bool needsModel;
  final bool needsAudio;
  const TranscribePlan(
      {required this.model, required this.needsModel, required this.needsAudio});

  bool get needsDownloads => needsModel || needsAudio;
}

class _Flow {
  bool cancelRequested = false;
  void Function()? cancelStage;
  final ended = Completer<void>();

  void cancel() {
    cancelRequested = true;
    cancelStage?.call();
  }
}

class TranscribeCoordinator extends ChangeNotifier {
  final AppDatabase db;
  final DeviceServices services;

  /// The one owner of each episode's `.part`; null keeps the old direct
  /// fetch (tests that predate the shared owner).
  final EpisodeDownloadCoordinator? downloads;

  /// Fired after a work's transcript lands (the player re-reads its
  /// alignments through this). Settable because this coordinator outlives
  /// any one reader's shell.
  void Function(int workId)? onTranscribed;

  final DateTime Function() _now;

  final Map<int, _Flow> _flows = {};
  final Map<int, TranscribeCardState> _cards = {};

  /// Cards whose row was still `running` at restore: a kill stopped them,
  /// not the user.
  final Set<int> _interrupted = {};

  TranscribeCoordinator(
      {required this.db,
      required this.services,
      this.downloads,
      this.onTranscribed,
      DateTime Function()? now})
      : _now = now ?? DateTime.now;

  List<TranscribeCardState> get cards => List.unmodifiable(_cards.values);

  bool isActive(int workId) => _flows.containsKey(workId);

  /// Rebuild cards from unfinished job rows — the reopened app's resumable
  /// state. Only the primary row of each work makes a card: the translate
  /// row shares its payload, and the person thinks of one episode, one job.
  Future<void> restore() async {
    for (final row in await db.jobsDao.unfinished()) {
      if (row.kind != 'transcribe' || !row.id.startsWith('transcribe-')) {
        continue;
      }
      final payload = jsonDecode(row.payloadJson) as Map<String, dynamic>;
      final workId = (payload['workId'] as num?)?.toInt();
      if (workId == null || _cards.containsKey(workId)) continue;
      final killed = row.state == JobState.running.name;
      if (killed) _interrupted.add(workId);
      _cards[workId] = TranscribeCardState(
        workId: workId,
        title: payload['title'] as String? ?? 'Episode',
        translate: payload['translate'] as bool? ?? false,
        phase: row.state == JobState.failed.name
            ? TranscribePhase.failed
            : killed
                ? TranscribePhase.waiting
                : TranscribePhase.paused,
        doneUnits: row.doneUnits,
        totalUnits: row.totalUnits == 0 ? null : row.totalUnits,
        error: row.state == JobState.failed.name
            ? row.failureReason ?? genericFailureReason
            : null,
      );
    }
    notifyListeners();
  }

  /// Continue every job a kill interrupted, one at a time, from its
  /// checkpoint. Paused and failed jobs wait for the user's hand.
  Future<void> resumeInterrupted() async {
    final queue = [..._interrupted];
    _interrupted.clear();
    for (final workId in queue) {
      if (_cards[workId]?.phase != TranscribePhase.waiting) continue;
      await resume(workId);
    }
  }

  /// The ASR model this device would use, and what starting would download.
  Future<TranscribePlan> planFor(
      {required int workId, required String enclosureUrl}) async {
    final model = services.registry
        .pickModel(ModelTask.asr, services.tier, langHint: null);
    if (model == null) {
      throw StateError('no ASR model in the registry for ${services.tier}');
    }
    return TranscribePlan(
      model: model,
      needsModel: !await services.modelStore.isDownloaded(model),
      needsAudio:
          !services.audioFileFor(workId, enclosureUrl).existsSync(),
    );
  }

  /// Begin (the UI has already passed the consent chokepoint when the plan
  /// needed downloads).
  Future<void> start(
      {required int workId,
      required String title,
      required String enclosureUrl,
      String? lang,
      required bool translate}) async {
    if (_flows.containsKey(workId)) return;
    final jobId = transcribeJobId(workId);
    final existing = await db.jobsDao.load(jobId);
    // Locked once, so a resume decodes in the same language. A job that
    // already exists keeps the language it has: its checkpoint holds
    // windows decoded in it, and recomputing (the feed's tag may have
    // changed since) would mix two languages in one transcript.
    Map<String, dynamic>? prior;
    if (existing != null) {
      try {
        prior = jsonDecode(await db.jobsDao.payloadOf(jobId))
            as Map<String, dynamic>;
      } catch (_) {
        prior = null;
      }
    }
    // Otherwise the work's own language, else the one its feed declares,
    // else none and the first window detects it. Only codes whisper knows
    // count.
    String? lockedLang;
    String? lockedSource;
    if (prior != null) {
      lockedLang = prior['lang'] as String?;
      lockedSource = prior['langSource'] as String?;
    } else {
      final declared = whisperLanguageOf(lang);
      final fromFeed = declared == null
          ? whisperLanguageOf(await db.feedsDao.languageOfWorkFeed(workId))
          : null;
      lockedLang = declared ?? fromFeed;
      lockedSource = declared != null
          ? 'declared'
          : fromFeed != null
              ? 'feed'
              : null;
    }
    final payload = jsonEncode({
      'workId': workId,
      'title': title,
      'url': enclosureUrl,
      'lang': lockedLang,
      'langSource': lockedSource,
      'translate': translate,
    });
    if (existing == null) {
      await db.jobsDao.save(Job(
        id: jobId,
        kind: 'transcribe',
        state: JobState.running,
        checkpoint: null,
        totalUnits: 0,
        doneUnits: 0,
        createdAtMs: _now().millisecondsSinceEpoch,
      ));
    }
    await db.jobsDao.setPayload(jobId, payload);
    _cards[workId] = TranscribeCardState(
        workId: workId,
        title: title,
        translate: translate,
        phase: TranscribePhase.preparing);
    notifyListeners();
    await _drive(workId);
  }

  /// Continue a paused/failed card from its checkpoint.
  Future<void> resume(int workId) async {
    if (_flows.containsKey(workId)) return;
    final card = _cards[workId];
    if (card == null) return;
    _cards[workId] = card._with(phase: TranscribePhase.preparing);
    notifyListeners();
    await _drive(workId);
  }

  /// Pause: the running stage stops at its next safe point; every committed
  /// byte and checkpoint stays.
  void cancel(int workId) {
    final flow = _flows[workId];
    if (flow != null) return flow.cancel();
    if (_cards[workId]?.phase == TranscribePhase.waiting) {
      _interrupted.remove(workId);
      unawaited(_pause(workId));
    }
  }

  /// Throw the job away: rows, checkpoint, decoded PCM and any partial
  /// audio download it left.
  Future<void> dismiss(int workId) async {
    _flows[workId]?.cancel();
    _interrupted.remove(workId);
    final dl = downloads;
    if (dl != null && dl.entries.any((e) => e.workId == workId)) {
      await dl.dismiss(workId);
    }
    await db.jobsDao.deleteJob(transcribeJobId(workId));
    await db.jobsDao.deleteJob(translateJobId(workId));
    final payloadless = _cards.remove(workId);
    final pcm = services.pcmFileFor(workId);
    // Sync delete on purpose: real-io futures never complete under widget
    // fake-async zones, and the file is small.
    if (pcm.existsSync()) pcm.deleteSync();
    if (payloadless != null) notifyListeners();
  }

  // ── the pipeline ──

  Future<void> _drive(int workId) async {
    final jobId = transcribeJobId(workId);
    // Registered before the first await, so stopAll can always see it.
    final flow = _Flow();
    _flows[workId] = flow;
    final String payloadJson;
    try {
      payloadJson = await db.jobsDao.payloadOf(jobId);
    } catch (_) {
      _flows.remove(workId);
      flow.ended.complete();
      rethrow;
    }
    final payload = jsonDecode(payloadJson) as Map<String, dynamic>;
    final title = payload['title'] as String? ?? 'Episode';
    final url = payload['url'] as String;
    // Normalized again: a job queued before 1.5.3 stored the work's
    // language as given.
    final lang = whisperLanguageOf(payload['lang'] as String?);
    final langSource = lang == null
        ? null
        : payload['langSource'] as String? ?? 'declared';
    final translate = payload['translate'] as bool? ?? false;

    final gate = services.foregroundGate;
    var holdsGate = false;

    try {
      await gate.jobStarted(title, 'Preparing…');
      holdsGate = true;

      // 1. The model (sha-pinned, resumable, cancel keeps the .part).
      final model = services.registry
          .pickModel(ModelTask.asr, services.tier, langHint: null);
      if (model == null) {
        throw StateError('no ASR model in the registry for ${services.tier}');
      }
      if (!await services.modelStore.isDownloaded(model)) {
        _update(workId, (c) => c._with(
            phase: TranscribePhase.fetchingModel,
            receivedBytes: 0,
            totalBytes: model.sizeBytes));
        final download = services.modelStore.download(model);
        flow.cancelStage = download.cancel;
        final sub = download.progress.listen((p) {
          _update(
              workId,
              (c) => c._with(
                  phase: TranscribePhase.fetchingModel,
                  receivedBytes: p.receivedBytes,
                  totalBytes: p.totalBytes,
                  etaMs: p.etaMs));
        });
        final outcome = await download.done;
        // Never awaited: cancel() of a finished stream returns the root-zone
        // null future, which a widget test's fake clock can never resume.
        unawaited(sub.cancel());
        flow.cancelStage = null;
        if (outcome == ModelInstallOutcome.cancelled) {
          return await _pause(workId);
        }
      }
      if (flow.cancelRequested) return await _pause(workId);

      // 2. The episode's audio (resumable; no pinned hash exists for it).
      final audio = services.audioFileFor(workId, url);
      final dl = downloads;
      if (!audio.existsSync() && dl != null) {
        _update(workId,
            (c) => c._with(phase: TranscribePhase.fetchingAudio));
        void mirror() {
          final s = dl.stateOf(workId);
          if (_cards[workId]?.phase != TranscribePhase.fetchingAudio) return;
          _update(workId, (c) => c._with(
              phase: TranscribePhase.fetchingAudio,
              receivedBytes: s.receivedBytes,
              totalBytes: s.totalBytes));
        }

        dl.addListener(mirror);
        flow.cancelStage = () => dl.cancel(workId);
        final DownloadOutcome outcome;
        try {
          outcome = await dl.start(workId: workId, url: url, title: title);
        } finally {
          dl.removeListener(mirror);
          flow.cancelStage = null;
        }
        if (outcome == DownloadOutcome.paused) return await _pause(workId);
        if (outcome == DownloadOutcome.failed) {
          final failed = dl.stateOf(workId);
          final reason = failed.error ?? genericFailureReason;
          // The failure now belongs to this job's card; one episode, one
          // line saying what went wrong.
          if (!failed.retriesOnLaunch) await dl.dismissKeepingPartial(workId);
          return await _fail(workId, JobGaveUp(reason),
              retriesOnLaunch: failed.retriesOnLaunch);
        }
      } else if (!audio.existsSync()) {
        _update(workId,
            (c) => c._with(phase: TranscribePhase.fetchingAudio));
        final token = dio.CancelToken();
        flow.cancelStage = () {
          if (!token.isCancelled) token.cancel();
        };
        final outcome = await services.audioFetcher
            .fetch(url, audio, cancelToken: token);
        flow.cancelStage = null;
        if (outcome == TransferOutcome.cancelled) {
          return await _pause(workId);
        }
        // P4 "archive, never forget": the audio is back on disk, so a
        // stale archived mark (from an earlier eviction) would be a lie.
        await db.feedsDao.setArchived(workId, null);
      }
      if (flow.cancelRequested) return await _pause(workId);

      // 3. Decode → 16kHz mono PCM file (checkpoint: the file exists).
      final pcm = services.pcmFileFor(workId);
      if (!pcm.existsSync()) {
        _update(workId, (c) => c._with(phase: TranscribePhase.preparing));
        await services.decoder.decodeToPcm16kMono(audio.path, pcm.path);
      }
      if (flow.cancelRequested) return await _pause(workId);

      // 4. Transcribe (and 5. translate) as checkpointed executor runs.
      final modelPath =
          services.modelStore.pathOf(model, model.files.first);
      final first = await _runStage(
        flow: flow,
        gate: gate,
        title: title,
        workId: workId,
        jobId: jobId,
        pcmPath: pcm.path,
        modelPath: modelPath,
        task: WhisperTask.transcribe,
        lang: lang,
        langSource: langSource,
        phase: TranscribePhase.transcribing,
      );
      if (first.state != JobState.done) {
        return await _afterStoppedStage(workId, first.state);
      }

      TranscriptionResult? mt;
      if (translate) {
        final detected = await _lockedLangOf(jobId);
        final secondId = translateJobId(workId);
        if (await db.jobsDao.load(secondId) == null) {
          await db.jobsDao.save(Job(
            id: secondId,
            kind: 'transcribe',
            state: JobState.running,
            checkpoint: null,
            totalUnits: 0,
            doneUnits: 0,
            createdAtMs: _now().millisecondsSinceEpoch,
          ));
          await db.jobsDao.setPayload(secondId, payloadJson);
        }
        final second = await _runStage(
          flow: flow,
          gate: gate,
          title: title,
          workId: workId,
          jobId: secondId,
          pcmPath: pcm.path,
          modelPath: modelPath,
          task: WhisperTask.translate,
          // Transcription already settled the language; detecting it
          // again would cost the same second encoder pass per window.
          lang: lang ?? detected,
          langSource: lang != null
              ? langSource
              : detected != null
                  ? 'detected'
                  : null,
          phase: TranscribePhase.translating,
        );
        if (second.state != JobState.done) {
          return await _afterStoppedStage(workId, second.state);
        }
        mt = second.result;
      }

      // 6. The spine rows, in one transaction; then the job is over.
      await writeTranscript(
          db: db,
          workId: workId,
          result: first.result!,
          translation: mt,
          langSource: langSource);
      // Here rather than in a shell's callback: a resumed job can land
      // before any reader is open.
      await db.capturesDao.backfillForWork(workId);
      // Sync delete on purpose (see dismiss).
      if (pcm.existsSync()) pcm.deleteSync();
      await db.jobsDao.deleteJob(jobId);
      await db.jobsDao.deleteJob(translateJobId(workId));
      _cards.remove(workId);
      notifyListeners();
      onTranscribed?.call(workId);
    } catch (err) {
      await _fail(workId, err);
    } finally {
      _flows.remove(workId);
      if (holdsGate) await gate.jobFinished();
      flow.ended.complete();
    }
  }

  Future<TranscribeOutcome> _runStage({
    required _Flow flow,
    required JobForegroundGate gate,
    required String title,
    required int workId,
    required String jobId,
    required String pcmPath,
    required String modelPath,
    required WhisperTask task,
    required String? lang,
    required String? langSource,
    required TranscribePhase phase,
  }) async {
    final run = services.executor.start(
      TranscribeSpec(
        jobId: jobId,
        pcmPath: pcmPath,
        task: task,
        lang: lang,
        langSource: langSource,
        engine: services.engineFor(modelPath),
      ),
      db.jobsDao.store,
    );
    flow.cancelStage = run.cancel;
    if (flow.cancelRequested) run.cancel();
    final sub = run.progress.listen((p) {
      _update(
          workId,
          (c) => c._with(
              phase: phase,
              doneUnits: p.doneUnits,
              totalUnits: p.totalUnits,
              etaMs: p.etaMs));
      unawaited(gate.jobProgress(
          title, '${p.doneUnits} of ${p.totalUnits} parts done'));
    });
    try {
      return await run.done;
    } finally {
      // Never awaited (see the model stage): the stream is already done.
      unawaited(sub.cancel());
      flow.cancelStage = null;
    }
  }

  /// The language a finished stage detected and locked, read off its
  /// checkpoint (the transcript itself is labelled only by a hint).
  Future<String?> _lockedLangOf(String jobId) async {
    final checkpoint = (await db.jobsDao.load(jobId))?.checkpoint;
    if (checkpoint == null) return null;
    final lang = (jsonDecode(checkpoint) as Map<String, dynamic>)['lang'];
    return whisperLanguageOf(lang as String?);
  }

  Future<void> _afterStoppedStage(int workId, JobState state) async {
    if (state == JobState.cancelled) return _pause(workId);
    await _fail(
        workId,
        const JobGaveUp(
            'Transcription kept stopping partway, even after several tries. '
            'Your progress is saved.'));
  }

  Future<void> _pause(int workId) async {
    // Stamp the primary row so a reopened app reads an honest state; the
    // checkpoint is untouched — cancel is a pause you can walk away from.
    final row = await db.jobsDao.load(transcribeJobId(workId));
    if (row != null && row.state == JobState.running) {
      await db.jobsDao.save(row.copyWith(state: JobState.cancelled));
    }
    _update(workId, (c) => c._with(
        phase: TranscribePhase.paused,
        doneUnits: c.doneUnits,
        totalUnits: c.totalUnits));
  }

  /// [retriesOnLaunch] (or a lost connection) leaves the row `running`,
  /// so the next launch carries on by itself.
  Future<void> _fail(int workId, Object err,
      {bool retriesOnLaunch = false}) async {
    final reason = plainFailureReason(err);
    final jobId = transcribeJobId(workId);
    final row = await db.jobsDao.load(jobId);
    final keepResumable = retriesOnLaunch || isTransientFailure(err);
    if (row != null && !keepResumable) {
      if (row.state == JobState.running) {
        await db.jobsDao.save(row.copyWith(state: JobState.failed));
      }
      await db.jobsDao.setFailureReason(jobId, reason);
    }
    _update(workId, (c) => c._with(
        phase: TranscribePhase.failed,
        doneUnits: c.doneUnits,
        totalUnits: c.totalUnits,
        error: reason));
  }

  /// Pause every running job and wait until each has let go; queued
  /// resumes are dropped so none starts afterwards.
  Future<void> stopAll() async {
    _interrupted.clear();
    for (final id in [..._cards.keys]) {
      if (_cards[id]?.phase == TranscribePhase.waiting) {
        _cards[id] = _cards[id]!._with(phase: TranscribePhase.paused);
      }
    }
    final flows = [..._flows.values];
    for (final f in flows) {
      f.cancel();
    }
    await Future.wait([for (final f in flows) f.ended.future]);
  }

  /// After a backup restore: forget every card and its decoded audio,
  /// whose ids now name other works. Call after [stopAll].
  void discardAll() {
    for (final id in _cards.keys) {
      final pcm = services.pcmFileFor(id);
      if (pcm.existsSync()) pcm.deleteSync();
    }
    _cards.clear();
    notifyListeners();
  }

  void _update(
      int workId, TranscribeCardState Function(TranscribeCardState) fn) {
    final card = _cards[workId];
    if (card == null) return;
    _cards[workId] = fn(card);
    notifyListeners();
  }
}
