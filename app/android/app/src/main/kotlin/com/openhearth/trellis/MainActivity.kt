package com.openhearth.trellis

import com.ryanheise.audioservice.AudioServiceActivity

/// audio_service's base activity, NOT the plain FlutterActivity: it
/// overrides `provideFlutterEngine` to return the plugin's shared engine.
/// Without that, AudioServicePlugin sets `wrongEngineDetected` and throws
/// on its first method call — which is the `configure` that
/// `JustAudioBackground.init()` sends, awaited in main() before runApp().
/// A plain FlutterActivity therefore does not degrade the media session;
/// it stops the app painting a first frame at all (1.4.0's launch-logo
/// hang). Guarded by test/android_host_engine_test.dart.
class MainActivity : AudioServiceActivity()
