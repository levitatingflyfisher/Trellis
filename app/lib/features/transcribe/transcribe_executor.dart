/// The transcription executor seam (proposal-2 §9).
///
/// One shared core — jobs_core's `JobRunner` driving transcribe_core's
/// `TranscribeEpisodeTask` over a `FilePcmSource` — behind two front doors:
///
///  * [InlineTranscribeExecutor] runs it on the calling isolate. Widget
///    tests drive this with `ml_runtime`'s scripted engine.
///  * [IsolateTranscribeExecutor] runs it in a REAL background isolate (a
///    40-minute whisper run must never block a frame) with the `JobStore`
///    proxied back over ports — Drift never leaves the main isolate, and
///    the checkpoint law (commit after every unit) crosses the port intact.
///
/// Engines are named by [TranscribeEngineSpec] — plain sendable data,
/// because the isolate must build its own engine on the far side.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:jobs_core/jobs_core.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:transcribe_core/transcribe_core.dart';
import 'package:whisper_ffi/whisper_ffi.dart';

import 'file_pcm_source.dart';

/// Which engine the far side should build. Sendable data only.
sealed class TranscribeEngineSpec {
  Map<String, Object?> toMap();

  static TranscribeEngineSpec fromMap(Map<String, Object?> m) =>
      switch (m['engine'] as String) {
        'whisper' => WhisperEngineSpec(
            modelPath: m['modelPath'] as String,
            libraryPath: m['libraryPath'] as String),
        'scripted' => ScriptedEngineSpec(
            chunkJsons: (m['chunks'] as List).cast<String>()),
        final other => throw ArgumentError('unknown engine "$other"'),
      };

  Transcriber build();
}

/// whisper.cpp: the model file installed by the model manager plus the
/// native shim library.
class WhisperEngineSpec extends TranscribeEngineSpec {
  final String modelPath;
  final String libraryPath;
  WhisperEngineSpec({required this.modelPath, required this.libraryPath});

  @override
  Map<String, Object?> toMap() => {
        'engine': 'whisper',
        'modelPath': modelPath,
        'libraryPath': libraryPath,
      };

  @override
  Transcriber build() => WhisperTranscriber(
      bindings: WhisperBindings.open(libraryPath), modelPath: modelPath);
}

/// ml_runtime's deterministic scripted engine, named by its chunk JSONs —
/// how tests (and only tests) run the full executor path without natives.
class ScriptedEngineSpec extends TranscribeEngineSpec {
  final List<String> chunkJsons;
  ScriptedEngineSpec({required this.chunkJsons});

  @override
  Map<String, Object?> toMap() =>
      {'engine': 'scripted', 'chunks': chunkJsons};

  @override
  Transcriber build() => FakeTranscriber([
        for (final j in chunkJsons)
          _chunkFromJson(jsonDecode(j) as Map<String, dynamic>)
      ]);
}

TranscriptChunk _chunkFromJson(Map<String, dynamic> m) => TranscriptChunk(
      text: m['text'] as String,
      tStartMs: (m['t0'] as num).toInt(),
      tEndMs: (m['t1'] as num).toInt(),
      words: m['words'] == null
          ? null
          : [
              for (final w in m['words'] as List)
                WordTiming(
                    word: (w as List)[0] as String,
                    tStartMs: (w[1] as num).toInt(),
                    tEndMs: (w[2] as num).toInt())
            ],
    );

/// Everything a run needs, sendable across an isolate boundary.
class TranscribeSpec {
  final String jobId;
  final String pcmPath;
  final WhisperTask task;
  final String? lang;
  final TranscribeEngineSpec engine;
  final int windowMs;
  final int overlapMs;

  TranscribeSpec({
    required this.jobId,
    required this.pcmPath,
    required this.task,
    required this.engine,
    this.lang,
    this.windowMs = 30000,
    this.overlapMs = 5000,
  });

  Map<String, Object?> toMap() => {
        'jobId': jobId,
        'pcmPath': pcmPath,
        'task': task.name,
        'lang': lang,
        'engine': engine.toMap(),
        'windowMs': windowMs,
        'overlapMs': overlapMs,
      };

  static TranscribeSpec fromMap(Map<String, Object?> m) => TranscribeSpec(
        jobId: m['jobId'] as String,
        pcmPath: m['pcmPath'] as String,
        task: WhisperTask.values.byName(m['task'] as String),
        lang: m['lang'] as String?,
        engine: TranscribeEngineSpec.fromMap(
            (m['engine'] as Map).cast<String, Object?>()),
        windowMs: (m['windowMs'] as num).toInt(),
        overlapMs: (m['overlapMs'] as num).toInt(),
      );
}

/// One progress beat: committed windows and the runner's honest ETA.
class TranscribeProgress {
  final int doneUnits;
  final int totalUnits;
  final int? etaMs;
  const TranscribeProgress(
      {required this.doneUnits, required this.totalUnits, this.etaMs});
}

/// How a run ended. [result] is present exactly when [state] is done — a
/// partial transcript never travels.
class TranscribeOutcome {
  final JobState state;
  final TranscriptionResult? result;
  const TranscribeOutcome(this.state, this.result);
}

/// A running transcription.
class TranscribeRun {
  final Stream<TranscribeProgress> progress;
  final Future<TranscribeOutcome> done;
  final void Function() _cancel;
  TranscribeRun._(this.progress, this.done, this._cancel);

  /// Lands at the next unit boundary; the committed checkpoint stays.
  void cancel() => _cancel();
}

abstract class TranscribeExecutor {
  TranscribeRun start(TranscribeSpec spec, JobStore store);
}

/// The shared core both executors run.
Future<TranscribeOutcome> _runCore({
  required TranscribeSpec spec,
  required JobStore store,
  required void Function(TranscribeProgress) onProgress,
  required CancelToken cancelToken,
}) async {
  final task = TranscribeEpisodeTask(
    source: FilePcmSource(File(spec.pcmPath)),
    transcriber: spec.engine.build(),
    task: spec.task,
    lang: spec.lang,
    plan: WindowPlan(windowMs: spec.windowMs, overlapMs: spec.overlapMs),
  );

  final existing = await store.load(spec.jobId);
  if (existing != null && existing.state == JobState.done) {
    // Results are written outside the row (by the caller); a done row with
    // its checkpoint can still hand them over without re-running.
    final cp = existing.checkpoint;
    if (cp != null) task.restore(cp);
    return TranscribeOutcome(JobState.done, task.buildResult());
  }
  if (existing != null &&
      existing.totalUnits == 0 &&
      existing.doneUnits == 0) {
    // A placeholder row created before decode revealed the plan: size it
    // now, or the runner would refuse the shape.
    await store.save(Job(
        id: existing.id,
        kind: existing.kind,
        state: existing.state,
        checkpoint: existing.checkpoint,
        totalUnits: task.totalUnits,
        doneUnits: 0,
        createdAtMs: existing.createdAtMs));
  }

  final runner = JobRunner(
    store: store,
    now: () => DateTime.now().millisecondsSinceEpoch,
    sleep: (ms) => Future<void>.delayed(Duration(milliseconds: ms)),
    onProgress: (p) => onProgress(TranscribeProgress(
        doneUnits: p.doneUnits, totalUnits: p.totalUnits, etaMs: p.etaMs)),
  );
  final row = await runner.run(
      jobId: spec.jobId,
      kind: 'transcribe',
      task: task,
      cancelToken: cancelToken);
  return TranscribeOutcome(
      row.state, row.state == JobState.done ? task.buildResult() : null);
}

/// Runs the core on the calling isolate.
class InlineTranscribeExecutor implements TranscribeExecutor {
  @override
  TranscribeRun start(TranscribeSpec spec, JobStore store) {
    final controller = StreamController<TranscribeProgress>.broadcast();
    final token = CancelToken();
    final done = () async {
      try {
        return await _runCore(
            spec: spec,
            store: store,
            onProgress: (p) {
              if (!controller.isClosed) controller.add(p);
            },
            cancelToken: token);
      } finally {
        unawaited(controller.close());
      }
    }();
    return TranscribeRun._(controller.stream, done, token.cancel);
  }
}

/// Runs the core in a background isolate; the store stays HERE and answers
/// over ports.
class IsolateTranscribeExecutor implements TranscribeExecutor {
  @override
  TranscribeRun start(TranscribeSpec spec, JobStore store) {
    final controller = StreamController<TranscribeProgress>.broadcast();
    final outcome = Completer<TranscribeOutcome>();
    final receive = ReceivePort();
    final exit = ReceivePort();
    SendPort? commands;
    var cancelWanted = false;

    void finish(TranscribeOutcome o) {
      if (!outcome.isCompleted) outcome.complete(o);
    }

    void fail(Object err, [StackTrace? stack]) {
      if (!outcome.isCompleted) {
        outcome.completeError(err, stack ?? StackTrace.current);
      }
    }

    exit.listen((_) {
      // A crash (or kill) before the outcome message: surface it rather
      // than hanging forever. The store's committed checkpoints survive.
      fail(StateError('transcription isolate exited without an outcome'));
      receive.close();
      exit.close();
      unawaited(controller.close());
    });

    receive.listen((message) async {
      final m = (message as Map).cast<String, Object?>();
      switch (m['t'] as String) {
        case 'ready':
          commands = m['port'] as SendPort;
          if (cancelWanted) commands!.send(const {'t': 'cancel'});
        case 'progress':
          if (!controller.isClosed) {
            controller.add(TranscribeProgress(
                doneUnits: (m['done'] as num).toInt(),
                totalUnits: (m['total'] as num).toInt(),
                etaMs: (m['eta'] as num?)?.toInt()));
          }
        case 'store':
          await _serveStore(store, m, commands!);
        case 'outcome':
          final resultJson = m['result'] as String?;
          finish(TranscribeOutcome(
              JobState.values.byName(m['state'] as String),
              resultJson == null
                  ? null
                  : TranscriptionResult.fromJson(
                      jsonDecode(resultJson) as Map<String, dynamic>)));
        case 'error':
          fail(RemoteTranscribeError(
              m['error'] as String, m['stack'] as String?));
      }
    });

    unawaited(Isolate.spawn(
      transcribeIsolateEntry,
      (receive.sendPort, spec.toMap()),
      onExit: exit.sendPort,
      debugName: 'transcribe-${spec.jobId}',
    ).catchError((Object err, StackTrace stack) {
      fail(err, stack);
      throw err; // satisfy the Isolate return type; already surfaced
    }));

    final done = outcome.future.whenComplete(() {
      receive.close();
      exit.close();
      unawaited(controller.close());
    });

    return TranscribeRun._(controller.stream, done, () {
      cancelWanted = true;
      commands?.send(const {'t': 'cancel'});
    });
  }

  Future<void> _serveStore(
      JobStore store, Map<String, Object?> m, SendPort reply) async {
    final id = m['id'] as int;
    try {
      Object? result;
      switch (m['op'] as String) {
        case 'load':
          final job = await store.load(m['jobId'] as String);
          result = job == null ? null : _jobToMap(job);
        case 'save':
          await store
              .save(_jobFromMap((m['job'] as Map).cast<String, Object?>()));
        case 'checkpoint':
          await store.saveCheckpoint(m['jobId'] as String,
              m['checkpoint'] as String, (m['doneUnits'] as num).toInt());
        case 'delete':
          await store.delete(m['jobId'] as String);
      }
      reply.send({'t': 'storeReply', 'id': id, 'result': result});
    } catch (err) {
      reply.send({'t': 'storeErr', 'id': id, 'error': err.toString()});
    }
  }
}

/// An error thrown on the far side, carried home as text.
class RemoteTranscribeError implements Exception {
  final String message;
  final String? remoteStack;
  RemoteTranscribeError(this.message, this.remoteStack);

  @override
  String toString() => 'RemoteTranscribeError: $message';
}

Map<String, Object?> _jobToMap(Job j) => {
      'id': j.id,
      'kind': j.kind,
      'state': j.state.name,
      'checkpoint': j.checkpoint,
      'totalUnits': j.totalUnits,
      'doneUnits': j.doneUnits,
      'createdAtMs': j.createdAtMs,
    };

Job _jobFromMap(Map<String, Object?> m) => Job(
      id: m['id'] as String,
      kind: m['kind'] as String,
      state: JobState.values.byName(m['state'] as String),
      checkpoint: m['checkpoint'] as String?,
      totalUnits: (m['totalUnits'] as num).toInt(),
      doneUnits: (m['doneUnits'] as num).toInt(),
      createdAtMs: (m['createdAtMs'] as num).toInt(),
    );

/// The far side. Top-level so `Isolate.spawn` can take it.
Future<void> transcribeIsolateEntry(
    (SendPort, Map<String, Object?>) args) async {
  final (home, specMap) = args;
  final spec = TranscribeSpec.fromMap(specMap);
  final commands = ReceivePort();
  final token = CancelToken();
  final store = _PortJobStore(home);

  commands.listen((message) {
    final m = (message as Map).cast<String, Object?>();
    switch (m['t'] as String) {
      case 'cancel':
        token.cancel();
      case 'storeReply':
      case 'storeErr':
        store.handleReply(m);
    }
  });
  home.send({'t': 'ready', 'port': commands.sendPort});

  try {
    final outcome = await _runCore(
        spec: spec,
        store: store,
        onProgress: (p) => home.send({
              't': 'progress',
              'done': p.doneUnits,
              'total': p.totalUnits,
              'eta': p.etaMs,
            }),
        cancelToken: token);
    home.send({
      't': 'outcome',
      'state': outcome.state.name,
      'result':
          outcome.result == null ? null : jsonEncode(outcome.result!.toJson()),
    });
  } catch (err, stack) {
    home.send({'t': 'error', 'error': err.toString(), 'stack': '$stack'});
  } finally {
    commands.close();
  }
}

/// The isolate-side JobStore: every call is a request over [home], answered
/// through [handleReply]. Ordering is preserved per call site because each
/// caller awaits its own future — the checkpoint law is untouched.
class _PortJobStore implements JobStore {
  final SendPort home;
  final Map<int, Completer<Object?>> _pending = {};
  var _nextId = 0;

  _PortJobStore(this.home);

  void handleReply(Map<String, Object?> m) {
    final completer = _pending.remove((m['id'] as num).toInt());
    if (completer == null) return;
    if (m['t'] == 'storeErr') {
      completer.completeError(StateError(m['error'] as String? ?? 'store error'));
    } else {
      completer.complete(m['result']);
    }
  }

  Future<Object?> _ask(Map<String, Object?> request) {
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    home.send({'t': 'store', 'id': id, ...request});
    return completer.future;
  }

  @override
  Future<Job?> load(String jobId) async {
    final m = await _ask({'op': 'load', 'jobId': jobId});
    return m == null ? null : _jobFromMap((m as Map).cast<String, Object?>());
  }

  @override
  Future<void> save(Job job) => _ask({'op': 'save', 'job': _jobToMap(job)});

  @override
  Future<void> saveCheckpoint(String jobId, String checkpoint, int doneUnits) =>
      _ask({
        'op': 'checkpoint',
        'jobId': jobId,
        'checkpoint': checkpoint,
        'doneUnits': doneUnits,
      });

  @override
  Future<void> delete(String jobId) => _ask({'op': 'delete', 'jobId': jobId});
}
