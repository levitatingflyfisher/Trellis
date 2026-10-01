package com.openhearth.trellis

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

/// The home-screen widget's door to Dart (1.5.5). Dart writes the card's
/// snapshot here (SharedPreferences, so the provider can draw it in a
/// process where Dart never started); taps come back as actions that wait
/// until Dart takes them, the way ShareInbox holds shares. What a tap does
/// is decided in Dart (home_shell.dart), where it is tested.
object WidgetBridge {
    const val CHANNEL = "com.openhearth.trellis/widget"
    private const val PREFS = "trellis_widget"
    private const val KEY_SNAPSHOT = "snapshot"

    /// Activity intents the widget sends; the action names the tap.
    const val ACTION_PLAY = "com.openhearth.trellis.widget.PLAY"
    const val ACTION_OPEN_WORK = "com.openhearth.trellis.widget.OPEN_WORK"
    const val ACTION_READ = "com.openhearth.trellis.widget.READ"
    const val EXTRA_WORK_ID = "workId"
    const val EXTRA_PROFILE_ID = "profileId"

    private val pending = mutableListOf<Map<String, Any?>>()
    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null

    /// The engine the channel was opened on. audio_service may later cache
    /// a different, headless engine under the same id (a Bluetooth Play
    /// after this one died), which never opens this channel, so "an engine
    /// is cached" alone is not "Dart can hear the widget".
    private var engine: FlutterEngine? = null

    fun attach(flutterEngine: FlutterEngine, context: Context) {
        val app = context.applicationContext
        if (engine !== flutterEngine) {
            engine = flutterEngine
            // audio_service destroys its engine when the playback service
            // ends (paused, then swiped away). The card is redrawn at once
            // as a cold one, so its Play is the plain open-the-app launch
            // rather than a tap into a Dart that is gone.
            flutterEngine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
                override fun onPreEngineRestart() {}
                override fun onEngineWillDestroy() {
                    if (engine === flutterEngine) {
                        engine = null
                        channel = null
                    }
                    main.post { TrellisWidget.refresh(app) }
                }
            })
        }
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "update" -> {
                        save(app, call.argument<String>("snapshot"))
                        TrellisWidget.refresh(app)
                        result.success(null)
                    }
                    "takePending" -> result.success(drain())
                    else -> result.notImplemented()
                }
            }
        }
    }

    /// Whether Dart is running in this process and can take a tap without
    /// the app's screen: audio_service's cached engine is the very one this
    /// channel was opened on. False in a process started just for the
    /// widget, and once that engine is destroyed.
    fun dartAlive(): Boolean {
        val attached = engine ?: return false
        return channel != null &&
            FlutterEngineCache.getInstance().get(AudioServicePlugin.getFlutterEngineId()) === attached
    }

    fun snapshot(context: Context): String? =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_SNAPSHOT, null)

    fun save(context: Context, json: String?) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_SNAPSHOT, json).apply()
    }

    /// The stored snapshot with its player facts cleared: playing and
    /// loaded both false. Everything else (titles, place, reading) stays.
    fun markCold(context: Context) {
        val json = snapshot(context) ?: return
        try {
            val o = org.json.JSONObject(json)
            val audio = o.optJSONObject("audio") ?: return
            if (!audio.optBoolean("playing") && !audio.optBoolean("loaded")) return
            audio.put("playing", false)
            audio.put("loaded", false)
            save(context, o.toString())
        } catch (e: Exception) {
            // An unreadable snapshot draws the empty card anyway.
        }
    }

    fun deliver(kind: String, workId: Long? = null, profileId: Long? = null) {
        synchronized(pending) {
            pending.add(mapOf("kind" to kind, "workId" to workId, "profileId" to profileId))
        }
        main.post { channel?.invokeMethod("actionArrived", null) }
    }

    private fun drain(): List<Map<String, Any?>> = synchronized(pending) {
        val all = pending.toList()
        pending.clear()
        all
    }

    /// A widget tap that opened the app.
    fun receive(activity: Activity, intent: Intent?) {
        if (intent == null) return
        // Reopened from Recents, the old tap comes back with it.
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
        val kind = when (intent.action) {
            ACTION_PLAY -> "play"
            ACTION_OPEN_WORK -> "openWork"
            ACTION_READ -> "read"
            else -> return
        }
        val work = intent.getLongExtra(EXTRA_WORK_ID, 0L).takeIf { it > 0 }
        val profile = intent.getLongExtra(EXTRA_PROFILE_ID, 0L).takeIf { it > 0 }
        deliver(kind, work, profile)
    }
}
