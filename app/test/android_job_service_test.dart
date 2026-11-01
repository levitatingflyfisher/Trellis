import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The jobs' foreground service must exist in the manifest.
///
/// Downloads, transcriptions and DSP keep the process alive behind the
/// screen through `AndroidJobForegroundGate`, which asks
/// flutter_foreground_task to start its `ForegroundService` as a dataSync
/// service. The plugin does NOT declare that service in its own manifest:
/// the app must (its README, "Android"). Trellis never did, so every
/// `startService` returned a `ServiceRequestFailure` the gate swallowed
/// ("Unable to start service Intent { cmp=com.openhearth.trellis/t2.a }:
/// not found" in logcat, t2.a being R8's name for it), from the August
/// 2026 commit that added the gate (21f51f1) through 1.5.9. A job only went
/// on behind the screen while something else held the process up (an
/// episode playing); once the app was cached, Android froze it mid-job.
///
/// Read against the source manifest, like android_host_engine_test.dart:
/// no Dart test can see the Android host otherwise.
void main() {
  final pubspec = File('pubspec.yaml');
  final manifest = File('android/app/src/main/AndroidManifest.xml');
  final gate = File('lib/features/transcribe/foreground_gate.dart');

  test('the guard can see its own inputs', () {
    expect(pubspec.existsSync(), isTrue);
    expect(manifest.existsSync(), isTrue);
    expect(gate.existsSync(), isTrue);
  });

  group('flutter_foreground_task service', () {
    const name = 'com.pravera.flutter_foreground_task.service.ForegroundService';

    String? serviceElement() {
      final text = manifest.readAsStringSync();
      for (final m in RegExp(r'<service\b[^>]*>', dotAll: true)
          .allMatches(text)) {
        if (m.group(0)!.contains('android:name="$name"')) return m.group(0);
      }
      return null;
    }

    bool usesPlugin() => RegExp(r'^\s{2}flutter_foreground_task:',
            multiLine: true)
        .hasMatch(pubspec.readAsStringSync());

    test('is declared, since the plugin leaves that to the app', () {
      if (!usesPlugin()) return;
      expect(serviceElement(), isNotNull,
          reason: 'AndroidManifest.xml has no <service android:name="$name">; '
              'every job foreground-service start is refused as not found');
    });

    test('declares every type the gate starts it with', () {
      if (!usesPlugin()) return;
      final element = serviceElement();
      expect(element, isNotNull);
      final declared = RegExp(r'android:foregroundServiceType="([^"]*)"')
              .firstMatch(element!)
              ?.group(1)
              ?.split('|')
              .toSet() ??
          const <String>{};
      // ForegroundServiceTypes.dataSync → "dataSync", and so on.
      final started = RegExp(r'ForegroundServiceTypes\.(\w+)')
          .allMatches(gate.readAsStringSync())
          .map((m) => m.group(1)!)
          .toSet();
      expect(started, isNotEmpty, reason: 'the gate starts no typed service?');
      expect(declared.containsAll(started), isTrue,
          reason: 'gate starts $started, manifest declares $declared');
      // Android 14 also wants the matching permission for each type.
      final text = manifest.readAsStringSync();
      for (final type in started) {
        final perm = 'android.permission.FOREGROUND_SERVICE_'
            '${type.replaceAllMapped(RegExp(r'[A-Z]'), (m) => '_${m[0]}').toUpperCase()}';
        expect(text, contains('"$perm"'), reason: '$perm is not declared');
      }
    });

    test('is not exported: only this app starts it', () {
      if (!usesPlugin()) return;
      expect(serviceElement(), contains('android:exported="false"'));
    });
  });
}
