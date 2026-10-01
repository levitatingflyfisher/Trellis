/// "Check feeds in the background" (ADR-0018): the device's two switches,
/// what they ask of the system scheduler, and the seam that asks.
library;

import 'package:flutter/foundation.dart';

import '../../../db/database.dart';

enum FeedCheckTask {
  /// The periodic check: every reader's feeds, then an auto-download
  /// request if anything new is wanted.
  check,

  /// One auto-download pass, which the system only starts on an
  /// unmetered network.
  autoDownload;

  static FeedCheckTask? byName(String name) =>
      values.where((t) => t.name == name).firstOrNull;
}

/// Set when a running check should wind down: the app opened, the system
/// stopped the worker, or its time budget ran out.
class StopSignal {
  bool _requested = false;
  final List<void Function()> _listeners = [];
  bool get requested => _requested;

  /// Runs [listener] once, when the stop comes (at once if it already has):
  /// a download in flight has to be interrupted, not just not followed.
  void onRequest(void Function() listener) {
    if (_requested) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void request() {
    if (_requested) return;
    _requested = true;
    for (final l in _listeners) {
      l();
    }
    _listeners.clear();
  }
}

/// How often the system is asked to run a check. It picks the moment
/// within its own window, so this is a rhythm, not a clock.
const feedCheckEvery = Duration(hours: 4);

/// What a periodic check needs before the system may run it. Battery-low
/// always waits; charging never matters, since a phone that only charges
/// overnight would otherwise check once a day.
@immutable
class FeedCheckConstraints {
  const FeedCheckConstraints({required this.unmeteredOnly});

  final bool unmeteredOnly;
  bool get batteryNotLow => true;
  bool get charging => false;

  @override
  bool operator ==(Object other) =>
      other is FeedCheckConstraints && other.unmeteredOnly == unmeteredOnly;
  @override
  int get hashCode => unmeteredOnly.hashCode;
  @override
  String toString() => 'FeedCheckConstraints(unmeteredOnly: $unmeteredOnly)';
}

FeedCheckConstraints constraintsFor({required bool wifiOnly}) =>
    FeedCheckConstraints(unmeteredOnly: wifiOnly);

/// The system scheduler, behind a seam so tests see what was asked.
abstract class FeedCheckScheduler {
  /// False where nothing can run in the background (the web build): the
  /// settings are hidden and nothing is ever asked.
  bool get available;

  /// Keeps a periodic check scheduled. [replace] false leaves an existing
  /// one alone, so a launch never resets the system's rhythm; true swaps
  /// in new constraints.
  Future<void> schedulePeriodic(FeedCheckConstraints constraints,
      {required bool replace});

  Future<void> cancelPeriodic();

  /// One auto-download pass, run by the system once the network is
  /// unmetered: right away on Wi-Fi, later on mobile data.
  Future<void> requestAutoDownload();

  /// Drops a pass that is waiting for Wi-Fi.
  Future<void> cancelAutoDownload();
}

class UnavailableFeedCheckScheduler implements FeedCheckScheduler {
  const UnavailableFeedCheckScheduler();
  @override
  bool get available => false;
  @override
  Future<void> schedulePeriodic(FeedCheckConstraints constraints,
      {required bool replace}) async {}
  @override
  Future<void> cancelPeriodic() async {}
  @override
  Future<void> requestAutoDownload() async {}
  @override
  Future<void> cancelAutoDownload() async {}
}

/// The two switches, kept in [DeviceSettings]: the device checks, not a
/// reader. Both default on.
class FeedCheckSettings extends ChangeNotifier {
  FeedCheckSettings(this.db, this.scheduler);

  final AppDatabase db;
  final FeedCheckScheduler scheduler;

  static const backgroundKey = 'feed_check_background';
  static const wifiOnlyKey = 'feed_check_wifi_only';

  bool _background = true;
  bool _wifiOnly = true;
  bool get background => _background;
  bool get wifiOnly => _wifiOnly;

  Future<void> load() async {
    _background = await _readFlag(backgroundKey);
    _wifiOnly = await _readFlag(wifiOnlyKey);
    notifyListeners();
  }

  /// At launch: the system may have dropped the work (an update, a force
  /// stop), and with boot receivers stripped this is when it comes back.
  Future<void> applyAtLaunch() async {
    if (!scheduler.available) return;
    await load();
    if (_background) {
      await scheduler.schedulePeriodic(constraintsFor(wifiOnly: _wifiOnly),
          replace: false);
    } else {
      await scheduler.cancelPeriodic();
      await scheduler.cancelAutoDownload();
    }
  }

  Future<void> setBackground(bool on) async {
    _background = on;
    notifyListeners();
    await db.deviceSettingsDao.write(backgroundKey, on ? 'on' : 'off');
    if (!scheduler.available) return;
    if (on) {
      await scheduler.schedulePeriodic(constraintsFor(wifiOnly: _wifiOnly),
          replace: false);
    } else {
      await scheduler.cancelPeriodic();
      await scheduler.cancelAutoDownload();
    }
  }

  Future<void> setWifiOnly(bool on) async {
    _wifiOnly = on;
    notifyListeners();
    await db.deviceSettingsDao.write(wifiOnlyKey, on ? 'on' : 'off');
    if (!scheduler.available || !_background) return;
    await scheduler.schedulePeriodic(constraintsFor(wifiOnly: on),
        replace: true);
  }

  Future<bool> _readFlag(String key) async =>
      await db.deviceSettingsDao.read(key) != 'off';

  static Future<bool> backgroundOn(AppDatabase db) async =>
      await db.deviceSettingsDao.read(backgroundKey) != 'off';
}

/// When a reader's feeds were last checked, by hand or in the background.
String lastCheckedKey(int profileId) => 'feeds_last_checked:$profileId';

Future<int?> readLastChecked(AppDatabase db, int profileId) async =>
    int.tryParse(await db.deviceSettingsDao.read(lastCheckedKey(profileId)) ?? '');

/// The Subscriptions header line. Rounded down, so it never claims a
/// fresher check than happened.
String lastCheckedLabel({required int? lastMs, required int nowMs}) {
  if (lastMs == null) return 'Not checked yet';
  final ago = Duration(milliseconds: nowMs - lastMs);
  if (ago.inMinutes < 1) return 'Last checked just now';
  if (ago.inHours < 1) return 'Last checked ${ago.inMinutes} min ago';
  if (ago.inDays < 1) return 'Last checked ${ago.inHours} h ago';
  final days = ago.inDays;
  return 'Last checked $days ${days == 1 ? 'day' : 'days'} ago';
}
