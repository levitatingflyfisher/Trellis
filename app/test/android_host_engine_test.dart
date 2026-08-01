import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Android host-class guard — the check that would have caught the
/// 1.4.0 boot brick.
///
/// `just_audio_background` (via `audio_service`) does not just need the
/// `<service>` and `<receiver>` elements in the manifest. It also needs the
/// launcher activity to hand it audio_service's *shared* FlutterEngine, by
/// extending `AudioServiceActivity`. Trellis 1.4.0 shipped the manifest half
/// and a plain `FlutterActivity`, and the result was not a broken media
/// session — it was an app that never painted a frame:
///
///   AudioServicePlugin.onAttachedToActivity() compares the activity's
///   engine against the shared one and sets `wrongEngineDetected`; the very
///   first method call then throws IllegalStateException. That first call is
///   `configure`, sent by `JustAudioBackground.init()` — which `main()`
///   awaits BEFORE `runApp()`. The throw ate the whole boot, so Android went
///   on showing `@style/LaunchTheme` — the logo — forever.
///
/// Nothing in 2000+ Dart tests could see that, because nothing in the suite
/// had ever read the Android host configuration. This is that test. It is
/// deliberately written against the *invariant* (the declared activity must
/// provide the shared engine) rather than against one file path, so pointing
/// the manifest straight at `AudioServiceActivity` would also satisfy it.
void main() {
  group('Android host activity provides audio_service the shared engine', () {
    final pubspec = File('pubspec.yaml');
    final manifest = File('android/app/src/main/AndroidManifest.xml');

    /// The two base classes audio_service ships that override
    /// `provideFlutterEngine` to return `AudioServicePlugin.getFlutterEngine`.
    const audioServiceBases = {
      'AudioServiceActivity',
      'AudioServiceFragmentActivity',
    };

    test('the guard can see its own inputs', () {
      // A check that passes because it found nothing is theatre. If either
      // input goes missing the guard must fail, not fall through.
      expect(pubspec.existsSync(), isTrue, reason: 'pubspec.yaml is missing');
      expect(manifest.existsSync(), isTrue,
          reason: '${manifest.path} is missing');
    });

    test('the declared launcher activity extends AudioServiceActivity', () {
      final pubspecText = pubspec.readAsStringSync();
      final needsSharedEngine =
          RegExp(r'^\s{2}(just_audio_background|audio_service):', multiLine: true)
              .hasMatch(pubspecText);
      if (!needsSharedEngine) {
        // Nothing to enforce: the app does not host a media session.
        return;
      }

      final manifestText = manifest.readAsStringSync();
      final declared = RegExp(r'<activity[^>]*android:name="([^"]+)"',
              multiLine: true, dotAll: true)
          .firstMatch(manifestText)
          ?.group(1);
      expect(declared, isNotNull,
          reason: 'no <activity android:name="..."> found in the manifest');

      // `.MainActivity` is shorthand for <namespace>.MainActivity.
      final namespace = RegExp(r'namespace\s*=\s*"([^"]+)"')
          .firstMatch(File('android/app/build.gradle.kts').readAsStringSync())
          ?.group(1);
      expect(namespace, isNotNull, reason: 'no namespace in build.gradle.kts');
      final fqcn =
          declared!.startsWith('.') ? '$namespace$declared' : declared;

      // Case 1: the manifest names audio_service's own activity. Nothing
      // else to check — the package provides the engine itself.
      if (audioServiceBases.contains(fqcn.split('.').last) &&
          fqcn.startsWith('com.ryanheise.audioservice')) {
        return;
      }

      // Case 2: an app-owned activity. It must exist on disk AND inherit
      // from one of audio_service's bases (or, if it ever overrides
      // provideFlutterEngine by hand, name the plugin's engine getter).
      final relative = fqcn.replaceAll('.', '/');
      final candidates = [
        File('android/app/src/main/kotlin/$relative.kt'),
        File('android/app/src/main/java/$relative.java'),
      ];
      final source = candidates.where((f) => f.existsSync()).firstOrNull;
      expect(source, isNotNull,
          reason: 'the manifest declares $fqcn but no source file exists at '
              '${candidates.map((f) => f.path).join(' or ')}');

      final code = source!.readAsStringSync();
      final extendsBase = audioServiceBases.any((base) =>
          RegExp(r'class\s+\w+\s*(:|extends)\s*' + base).hasMatch(code));
      final providesEngineByHand =
          code.contains('AudioServicePlugin.getFlutterEngine');

      expect(extendsBase || providesEngineByHand, isTrue,
          reason: '$fqcn must extend AudioServiceActivity (or provide '
              "audio_service's shared FlutterEngine itself). A plain "
              'FlutterActivity makes AudioServicePlugin set '
              'wrongEngineDetected, and the IllegalStateException it then '
              'throws on `configure` kills main() before runApp() — the app '
              'hangs on the launch logo. See ${source.path}.');
    });
  });
}
