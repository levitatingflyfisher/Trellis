/// Who runs a background feed check (ADR-0018). The system starts the
/// check in a second engine inside the app's process, which may or may not
/// already have the app running. Downloads must have one owner, and the
/// app's Jobs screen only sees what its own coordinator runs, so:
///
/// * app alive: the worker hands the check to the app and waits;
/// * no app: the worker runs it on its own connection;
/// * the app opens mid-check: the worker winds down (what is in flight
///   finishes, downloads pause) and says so before the app resumes jobs.
///
/// Each side registers its own name and only then looks for the other's,
/// so whichever order the two start in, at least one of them sees the
/// other; it can't happen that both miss and both run downloads.
///
/// A name can outlive its engine (the system destroys a worker engine it
/// stopped). Each side pings before it trusts a name it finds, so a dead
/// one costs a short wait, never a stuck worker or a slow app start.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'feed_check_settings.dart';

const feedCheckAppPortName = 'trellis.feed-check.app';
const feedCheckWorkerPortName = 'trellis.feed-check.worker';

/// The process-wide name table, behind a seam for tests.
abstract class PortDirectory {
  SendPort? lookup(String name);
  bool register(SendPort port, String name);
  void remove(String name);
}

class IsolatePortDirectory implements PortDirectory {
  const IsolatePortDirectory();
  @override
  SendPort? lookup(String name) => IsolateNameServer.lookupPortByName(name);
  @override
  bool register(SendPort port, String name) =>
      IsolateNameServer.registerPortWithName(port, name);
  @override
  void remove(String name) => IsolateNameServer.removePortNameMapping(name);
}

/// Sends [message] plus a reply port to [to]; null if nothing answers in
/// [timeout] (the other engine is gone, or stuck).
Future<Object?> _ask(SendPort to, List<Object?> message, Duration timeout) async {
  final reply = ReceivePort();
  try {
    to.send([...message, reply.sendPort]);
    return await reply.first.timeout(timeout, onTimeout: () => null);
  } finally {
    reply.close();
  }
}

/// The worker engine's side.
class FeedCheckWorker {
  FeedCheckWorker({
    this.directory = const IsolatePortDirectory(),
    required this.runHere,
    this.pingTimeout = const Duration(seconds: 3),
    this.delegateTimeout = const Duration(minutes: 9),
  });

  final PortDirectory directory;

  /// Runs [task] in this engine. It must watch [stop] and return soon
  /// after it is requested.
  final Future<bool> Function(FeedCheckTask task, StopSignal stop) runHere;
  final Duration pingTimeout;

  /// Under the system's ten-minute limit on a worker.
  final Duration delegateTimeout;

  final StopSignal _stop = StopSignal();
  SendPort? _delegatedTo;

  /// Names this worker's hand-over, so its stop reaches its own task and
  /// not one another worker handed over.
  final String _runId =
      '${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(Object())}';

  /// The system stopped this worker (time limit, Wi-Fi gone): wind down
  /// here, or tell the app to stop the task this worker handed it.
  void stop() {
    _stop.request();
    _delegatedTo?.send(['stop', _runId]);
  }

  /// What the system is told: true done, false try again later.
  Future<bool> run(FeedCheckTask task) async {
    final inbox = ReceivePort();
    if (!await _register(inbox.sendPort)) {
      // Another check is running in its own engine; this one comes back.
      inbox.close();
      return false;
    }
    final waiting = <SendPort>[];
    var done = false;
    inbox.listen((message) {
      switch (message) {
        case ['ping', SendPort reply]:
          reply.send(true);
        case ['yield', SendPort reply]:
          _stop.request();
          if (done) {
            reply.send(true);
          } else {
            waiting.add(reply);
          }
      }
    });
    try {
      final app = directory.lookup(feedCheckAppPortName);
      // A name that doesn't answer is left alone: the app may only be
      // slow, and its own start replaces a dead one.
      if (app != null && await _ask(app, ['ping'], pingTimeout) == true) {
        // Nothing runs here, so a yield can be answered at once.
        done = true;
        for (final w in waiting) {
          w.send(true);
        }
        waiting.clear();
        _delegatedTo = app;
        if (_stop.requested) return true;
        final result =
            await _ask(app, ['run', task.name, _runId], delegateTimeout);
        if (result == null) app.send(['stop', _runId]);
        return result is bool ? result : true;
      }
      return await runHere(task, _stop);
    } finally {
      done = true;
      _delegatedTo = null;
      for (final w in waiting) {
        w.send(true);
      }
      directory.remove(feedCheckWorkerPortName);
      inbox.close();
    }
  }

  /// Registers this worker; a name held by a worker that no longer answers
  /// is taken over.
  Future<bool> _register(SendPort port) async {
    if (directory.register(port, feedCheckWorkerPortName)) return true;
    final other = directory.lookup(feedCheckWorkerPortName);
    if (other != null && await _ask(other, ['ping'], pingTimeout) == true) {
      return false;
    }
    directory.remove(feedCheckWorkerPortName);
    return directory.register(port, feedCheckWorkerPortName);
  }
}

/// The app engine's side: answers the worker, runs what it hands over.
class FeedCheckHost {
  FeedCheckHost({
    this.directory = const IsolatePortDirectory(),
    required this.runTask,
    this.pingTimeout = const Duration(seconds: 2),
    this.yieldTimeout = const Duration(seconds: 20),
  });

  final PortDirectory directory;
  final Future<bool> Function(FeedCheckTask task, StopSignal stop) runTask;
  final Duration pingTimeout;
  final Duration yieldTimeout;

  ReceivePort? _inbox;
  Future<void> _queue = Future.value();
  final Map<String, StopSignal> _running = {};

  /// Registers, then asks a worker already running to wind down. Completes
  /// once it has, or after [yieldTimeout] if it doesn't answer. Call before
  /// resuming jobs: a download the worker still holds must not get a
  /// second owner.
  Future<void> open() async {
    final inbox = ReceivePort();
    _inbox = inbox;
    inbox.listen(_onMessage);
    directory.remove(feedCheckAppPortName);
    directory.register(inbox.sendPort, feedCheckAppPortName);
    final worker = directory.lookup(feedCheckWorkerPortName);
    if (worker == null) return;
    if (await _ask(worker, ['ping'], pingTimeout) != true) {
      // Left by a worker engine the system destroyed.
      directory.remove(feedCheckWorkerPortName);
      return;
    }
    await _ask(worker, ['yield'], yieldTimeout);
  }

  void close() {
    final inbox = _inbox;
    if (inbox == null) return;
    if (directory.lookup(feedCheckAppPortName) == inbox.sendPort) {
      directory.remove(feedCheckAppPortName);
    }
    inbox.close();
    _inbox = null;
  }

  void _onMessage(Object? message) {
    switch (message) {
      case ['ping', SendPort reply]:
        reply.send(true);
      case ['stop', String runId]:
        _running[runId]?.request();
      case ['run', String name, String runId, SendPort reply]:
        final task = FeedCheckTask.byName(name);
        if (task == null) {
          reply.send(true);
          return;
        }
        final stop = StopSignal();
        _running[runId] = stop;
        // One at a time: a periodic check and an auto-download pass can be
        // handed over together.
        final run = _queue
            .then((_) => stop.requested ? true : runTask(task, stop))
            .then((ok) => ok, onError: (Object _) => false)
            .whenComplete(() => _running.remove(runId));
        _queue = run;
        unawaited(run.then(reply.send));
    }
  }
}
