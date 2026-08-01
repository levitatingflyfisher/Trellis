/// The notification-backed foreground service seam (proposal-2 §9: a
/// 40-minute episode on a phone survives screen-off).
///
/// Android-only by guard: [AndroidJobForegroundGate] talks to
/// flutter_foreground_task and is inert everywhere else; every other
/// surface (and every test) holds [NoopJobForegroundGate] or a recording
/// fake. The notification it raises is live job progress — the ONLY
/// notification this app ships (ADR-0003 law 5).
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

abstract class JobForegroundGate {
  Future<void> jobStarted(String title, String text);
  Future<void> jobProgress(String title, String text);
  Future<void> jobFinished();
}

class NoopJobForegroundGate implements JobForegroundGate {
  @override
  Future<void> jobStarted(String title, String text) async {}
  @override
  Future<void> jobProgress(String title, String text) async {}
  @override
  Future<void> jobFinished() async {}
}

class AndroidJobForegroundGate implements JobForegroundGate {
  bool _initialized = false;
  bool _running = false;

  bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  void _ensureInit() {
    if (_initialized) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'trellis_jobs',
        channelName: 'Background jobs',
        channelDescription: 'Live progress of transcription jobs',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false, playSound: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
      ),
    );
    _initialized = true;
  }

  @override
  Future<void> jobStarted(String title, String text) async {
    if (!_isAndroid) return;
    _ensureInit();
    if (_running) return jobProgress(title, text);
    final result = await FlutterForegroundTask.startService(
      serviceTypes: const [ForegroundServiceTypes.dataSync],
      notificationTitle: title,
      notificationText: text,
    );
    _running = result is ServiceRequestSuccess;
  }

  @override
  Future<void> jobProgress(String title, String text) async {
    if (!_isAndroid || !_running) return;
    await FlutterForegroundTask.updateService(
        notificationTitle: title, notificationText: text);
  }

  @override
  Future<void> jobFinished() async {
    if (!_isAndroid || !_running) return;
    _running = false;
    await FlutterForegroundTask.stopService();
  }
}
