import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/feeds/background/feed_check_settings.dart';

class FakeScheduler implements FeedCheckScheduler {
  FakeScheduler({this.available = true});
  @override
  final bool available;
  final List<String> calls = [];

  @override
  Future<void> schedulePeriodic(FeedCheckConstraints constraints,
          {required bool replace}) async =>
      calls.add('schedule unmetered=${constraints.unmeteredOnly} '
          'replace=$replace');
  @override
  Future<void> cancelPeriodic() async => calls.add('cancel');
  @override
  Future<void> requestAutoDownload() async => calls.add('auto-download');
  @override
  Future<void> cancelAutoDownload() async => calls.add('cancel-auto');
}

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('the constraints: Wi-Fi only maps to unmetered; battery-low always '
      'waits; charging never matters', () {
    final wifi = constraintsFor(wifiOnly: true);
    final any = constraintsFor(wifiOnly: false);
    expect(wifi.unmeteredOnly, isTrue);
    expect(any.unmeteredOnly, isFalse);
    for (final c in [wifi, any]) {
      expect(c.batteryNotLow, isTrue);
      expect(c.charging, isFalse);
    }
    expect(feedCheckEvery, const Duration(hours: 4));
  });

  test('both switches default on, and launch keeps the existing schedule',
      () async {
    final s = FakeScheduler();
    final settings = FeedCheckSettings(db, s);
    await settings.applyAtLaunch();
    expect(settings.background, isTrue);
    expect(settings.wifiOnly, isTrue);
    expect(s.calls, ['schedule unmetered=true replace=false']);
  });

  test('turning background checks off cancels the work, and launch keeps '
      'it cancelled', () async {
    final s = FakeScheduler();
    final settings = FeedCheckSettings(db, s);
    await settings.load();
    await settings.setBackground(false);
    expect(s.calls, ['cancel', 'cancel-auto'],
        reason: 'a pass waiting for Wi-Fi goes too');

    final next = FakeScheduler();
    await FeedCheckSettings(db, next).applyAtLaunch();
    expect(next.calls, ['cancel', 'cancel-auto']);
  });

  test('turning it back on schedules again', () async {
    final s = FakeScheduler();
    final settings = FeedCheckSettings(db, s);
    await settings.setBackground(false);
    await settings.setBackground(true);
    expect(s.calls.last, 'schedule unmetered=true replace=false');
  });

  test('changing Wi-Fi only swaps the constraints in; while checks are off '
      'it only remembers', () async {
    final s = FakeScheduler();
    final settings = FeedCheckSettings(db, s);
    await settings.load();
    await settings.setWifiOnly(false);
    expect(s.calls, ['schedule unmetered=false replace=true']);

    await settings.setBackground(false);
    s.calls.clear();
    await settings.setWifiOnly(true);
    expect(s.calls, isEmpty);
    await settings.load();
    expect(settings.wifiOnly, isTrue);
  });

  test('where nothing can run in the background, nothing is asked',
      () async {
    final s = FakeScheduler(available: false);
    final settings = FeedCheckSettings(db, s);
    await settings.applyAtLaunch();
    await settings.setBackground(false);
    await settings.setWifiOnly(false);
    expect(s.calls, isEmpty);
  });

  test('the last-checked line', () {
    const h = 3600 * 1000;
    expect(lastCheckedLabel(lastMs: null, nowMs: 0), 'Not checked yet');
    expect(lastCheckedLabel(lastMs: 0, nowMs: 30 * 1000),
        'Last checked just now');
    expect(lastCheckedLabel(lastMs: 0, nowMs: 59 * 60 * 1000),
        'Last checked 59 min ago');
    expect(lastCheckedLabel(lastMs: 0, nowMs: 2 * h + 59 * 60 * 1000),
        'Last checked 2 h ago');
    expect(lastCheckedLabel(lastMs: 0, nowMs: 30 * h),
        'Last checked 1 day ago');
    expect(lastCheckedLabel(lastMs: 0, nowMs: 72 * h),
        'Last checked 3 days ago');
  });
}
