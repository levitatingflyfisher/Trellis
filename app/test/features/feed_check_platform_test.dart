import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/feeds/background/feed_check_platform_io.dart';
import 'package:trellis/features/feeds/background/feed_check_settings.dart';

void main() {
  test('Wi-Fi only asks for an unmetered network, otherwise any connection; '
      'battery-low waits, charging never matters, every 4 hours', () {
    final wifi = periodicRequest(constraintsFor(wifiOnly: true), replace: false);
    final any = periodicRequest(constraintsFor(wifiOnly: false), replace: false);
    expect(wifi['unmeteredOnly'], isTrue);
    expect(any['unmeteredOnly'], isFalse);
    for (final r in [wifi, any]) {
      expect(r['batteryNotLow'], isTrue);
      expect(r['charging'], isFalse);
      expect(r['everyMinutes'], 240);
    }
  });

  test('an auto-download pass waits for an unmetered network, whatever the '
      'check was allowed', () {
    expect(autoDownloadRequest()['unmeteredOnly'], isTrue);
    expect(autoDownloadRequest()['batteryNotLow'], isTrue);
  });

  test('a make-ahead pass waits for both Wi-Fi and charging', () {
    expect(makeAheadRequest()['unmeteredOnly'], isTrue);
    expect(makeAheadRequest()['charging'], isTrue);
  });

  test('launch keeps the schedule; a changed switch updates it; nothing '
      'replaces it', () {
    final c = constraintsFor(wifiOnly: true);
    expect(periodicRequest(c, replace: false)['policy'], 'keep');
    expect(periodicRequest(c, replace: true)['policy'], 'update');
  });

  group('the Kotlin side', () {
    final worker = File(
        'android/app/src/main/kotlin/com/openhearth/trellis/FeedCheckWorker.kt');
    final scheduler = File(
        'android/app/src/main/kotlin/com/openhearth/trellis/FeedCheckScheduler.kt');

    test('the worker engine registers no plugin by itself, and none of the '
        'audio or foreground-service ones (the 1.4.0 hang)', () {
      // Code only: the file's comments name the plugins it keeps out.
      final src = worker
          .readAsLinesSync()
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(src, contains('FlutterEngine(applicationContext, null, false)'));
      for (final banned in [
        'audioservice',
        'audio_session',
        'just_audio',
        'flutter_foreground_task',
        'GeneratedPluginRegistrant',
      ]) {
        expect(src, isNot(contains(banned)), reason: banned);
      }
    });

    test('reads exactly the keys Dart sends', () {
      final src = scheduler.readAsStringSync();
      final keys = {
        ...periodicRequest(constraintsFor(wifiOnly: true), replace: true).keys,
        ...autoDownloadRequest().keys,
        ...makeAheadRequest().keys,
      };
      for (final k in keys) {
        expect(src, contains('args["$k"]'), reason: k);
      }
      expect(src, contains('"update"'));
    });

    test('make ahead has its own pass, and reads charging from the '
        'battery with no permission of its own', () {
      final src = scheduler.readAsStringSync();
      expect(src, contains('"requestMakeAhead"'));
      expect(src, contains('task("makeAhead")'));
      expect(src, contains('"isCharging"'));
      expect(src, contains('ACTION_BATTERY_CHANGED'));
    });

    test('answers whether the network is metered from the connectivity '
        'service (1.6.0)', () {
      final src = scheduler.readAsStringSync();
      expect(src, contains('"isMetered"'));
      expect(src, contains('isActiveNetworkMetered'));
    });
  });

  group('whether the network is metered (1.6.0)', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('com.openhearth.trellis/feed_check');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('asks Android, and says what it says', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'isMetered');
        return true;
      });
      expect(await const ChannelFeedCheckScheduler().isMetered(), isTrue);

      messenger.setMockMethodCallHandler(channel, (_) async => false);
      expect(await const ChannelFeedCheckScheduler().isMetered(), isFalse);
    });

    test('when Android cannot say, the network counts as metered: a '
        'download told to wait for Wi-Fi is not started on a guess',
        () async {
      messenger.setMockMethodCallHandler(
          channel, (_) async => throw PlatformException(code: 'unavailable'));
      expect(await const ChannelFeedCheckScheduler().isMetered(), isTrue);
    });

    test('where it cannot be known at all, nothing is made to wait', () async {
      expect(await const UnknownNetworkMeter().isMetered(), isFalse);
    });
  });
}
