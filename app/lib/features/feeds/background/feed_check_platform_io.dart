/// WorkManager on Android (ADR-0018), through the app's own small Worker
/// (`android/.../FeedCheckWorker.kt`) rather than a plugin. Dart decides
/// every constraint and policy here, where it is tested; Kotlin only hands
/// them on. The Worker starts [runFeedCheckWorker] in an engine of its
/// own, and [FeedCheckWorker] decides whether that engine does the work or
/// hands it to the app.
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../../../bootstrap/bootstrap_io.dart' show createDb;
import '../../../net/io_fetcher.dart';
import '../../../services/device_services.dart';
import '../episode_download_coordinator.dart';
import '../feeds_repository.dart';
import 'feed_check_handoff.dart';
import 'feed_check_runner.dart';
import 'feed_check_settings.dart';

const _schedulerChannel = MethodChannel('com.openhearth.trellis/feed_check');
const _workerChannel =
    MethodChannel('com.openhearth.trellis/feed_check_worker');

/// Under the system's ten minutes, leaving room to pause and close.
const _headlessBudget = Duration(minutes: 8);

FeedCheckScheduler createFeedCheckScheduler() => Platform.isAndroid
    ? const ChannelFeedCheckScheduler()
    : const UnavailableFeedCheckScheduler();

/// What the periodic check asks of WorkManager. Keep at launch, so opening
/// the app never restarts the period; update when the Wi-Fi switch changes
/// what the check waits for. Never replace, which restarts the period.
Map<String, Object> periodicRequest(FeedCheckConstraints c,
        {required bool replace}) =>
    {
      'everyMinutes': feedCheckEvery.inMinutes,
      'unmeteredOnly': c.unmeteredOnly,
      'batteryNotLow': c.batteryNotLow,
      'charging': c.charging,
      'policy': replace ? 'update' : 'keep',
    };

/// Audio only ever comes over an unmetered network, whatever the check
/// itself was allowed to use.
Map<String, Object> autoDownloadRequest() => const {
      'unmeteredOnly': true,
      'batteryNotLow': true,
      'charging': false,
    };

class ChannelFeedCheckScheduler implements FeedCheckScheduler {
  const ChannelFeedCheckScheduler();

  @override
  bool get available => true;

  @override
  Future<void> schedulePeriodic(FeedCheckConstraints c,
          {required bool replace}) =>
      _schedulerChannel.invokeMethod<void>(
          'schedulePeriodic', periodicRequest(c, replace: replace));

  @override
  Future<void> cancelPeriodic() =>
      _schedulerChannel.invokeMethod<void>('cancelPeriodic');

  @override
  Future<void> requestAutoDownload() => _schedulerChannel.invokeMethod<void>(
      'requestAutoDownload', autoDownloadRequest());

  @override
  Future<void> cancelAutoDownload() =>
      _schedulerChannel.invokeMethod<void>('cancelAutoDownload');
}

/// Starts answering the worker engine and returns how to stop. Completes
/// once a check already running headless has wound down, so the caller can
/// resume jobs without giving a download a second owner.
Future<void Function()> openFeedCheckHost(
    Future<bool> Function(FeedCheckTask task, StopSignal stop) runTask) async {
  final host = FeedCheckHost(runTask: runTask);
  await host.open();
  return host.close;
}

/// The worker engine's entrypoint (main.dart's `feedCheckMain`). Tells the
/// Worker the outcome: true done, false try again later.
Future<void> runFeedCheckWorker(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final task = args.isEmpty ? null : FeedCheckTask.byName(args.first);
  if (task == null) {
    await _workerChannel.invokeMethod<void>('done', true);
    return;
  }
  final worker = FeedCheckWorker(runHere: _runHeadless);
  final run = worker.run(task);
  // The Worker destroys this engine once the stop is answered, so the
  // answer waits until the run has wound down.
  _workerChannel.setMethodCallHandler((call) async {
    if (call.method != 'stop') return null;
    worker.stop();
    await run.timeout(const Duration(seconds: 8), onTimeout: () => false);
    return null;
  });
  final ok = await run.catchError((Object _) => false);
  await _workerChannel.invokeMethod<void>('done', ok);
}

/// The check with no app open: its own connection, its own coordinator,
/// the app's files. When the app opens or the system stops it, it pauses
/// its downloads and closes its connection within a few seconds, so it
/// never writes once the app has started writing (ADR-0018). Refreshes
/// still in flight then fail against the closed connection and are
/// retried by the next check.
Future<bool> _runHeadless(FeedCheckTask task, StopSignal stop) async {
  final services =
      DeviceServices.background(await getApplicationSupportDirectory());
  final db = createDb();
  final downloads = EpisodeDownloadCoordinator(services: services, db: db);
  final repository =
      FeedsRepository(db: db, fetcher: IoHttpFetcher(), services: services);
  final runner = FeedCheckRunner.withCoordinator(
    db: db,
    repository: repository,
    scheduler: const ChannelFeedCheckScheduler(),
    downloads: downloads,
  );
  final budget = Timer(_headlessBudget, stop.request);
  final stopped = Completer<void>();
  stop.onRequest(stopped.complete);
  final run = runner.run(task, stop: stop).catchError((Object _) => false);
  try {
    return await Future.any([
      run,
      stopped.future.then((_) => run.timeout(const Duration(seconds: 3),
          onTimeout: () => false)),
    ]);
  } finally {
    budget.cancel();
    await downloads.stopAll().timeout(const Duration(seconds: 2),
        onTimeout: () {});
    await db.close();
  }
}
