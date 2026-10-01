package com.openhearth.trellis

import android.content.Intent
import android.os.Bundle
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine

/// audio_service's base activity, NOT the plain FlutterActivity: it
/// overrides `provideFlutterEngine` to return the plugin's shared engine.
/// Without that, AudioServicePlugin sets `wrongEngineDetected` and throws
/// on its first method call — which is the `configure` that
/// `JustAudioBackground.init()` sends, awaited in main() before runApp().
/// A plain FlutterActivity therefore does not degrade the media session;
/// it stops the app painting a first frame at all (1.4.0's launch-logo
/// hang). Guarded by test/android_host_engine_test.dart.
class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The background feed check's scheduling door (ADR-0018).
        FeedCheckScheduler.attach(flutterEngine.dartExecutor.binaryMessenger, this)
        // Share to Trellis (1.5.5).
        ShareInbox.attach(flutterEngine.dartExecutor.binaryMessenger, this)
        // The home-screen widget (1.5.5).
        WidgetBridge.attach(flutterEngine, this)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A restored activity is handed its old intent again; that share
        // was already taken.
        if (savedInstanceState == null) {
            ShareInbox.receive(this, intent)
            WidgetBridge.receive(this, intent)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        ShareInbox.receive(this, intent)
        WidgetBridge.receive(this, intent)
    }
}
