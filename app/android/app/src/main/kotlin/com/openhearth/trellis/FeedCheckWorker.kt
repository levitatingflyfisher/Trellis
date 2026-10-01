package com.openhearth.trellis

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/// Runs one feed check in a Flutter engine of its own (ADR-0018).
///
/// The engine registers no plugins by itself, and only the three the check
/// reaches are added: jni and jni_flutter (path_provider's Android side)
/// and sqlite3_flutter_libs. audio_service, just_audio and
/// flutter_foreground_task never attach here, so their engine checks (the
/// 1.4.0 launch hang) can't fire, and nothing can post a notification.
class FeedCheckWorker(context: Context, params: WorkerParameters) :
    Worker(context, params) {

    private val main = Handler(Looper.getMainLooper())
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private val outcome = AtomicReference<Result?>(null)
    private val finished = CountDownLatch(1)
    private val finish: (Result) -> Unit = { result ->
        if (outcome.compareAndSet(null, result)) {
            destroyEngine()
            finished.countDown()
        }
    }

    /// WorkManager's own thread waits here while the engine runs on the
    /// main thread; the engine is never touched off it.
    override fun doWork(): Result {
        main.post { start() }
        if (!finished.await(MAX_RUN_MS, TimeUnit.MILLISECONDS)) {
            finish(Result.retry())
        }
        return outcome.get() ?: Result.retry()
    }

    private fun start() {
        val task = inputData.getString(FeedCheckScheduler.TASK_KEY)
        if (task == null) {
            finish(Result.success())
            return
        }
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(applicationContext)
        loader.ensureInitializationCompleteAsync(applicationContext, null, main) {
            if (isStopped) {
                finish(Result.success())
                return@ensureInitializationCompleteAsync
            }
            val e = FlutterEngine(applicationContext, null, false)
            engine = e
            e.plugins.add(com.github.dart_lang.jni.JniPlugin())
            e.plugins.add(com.github.dart_lang.jni_flutter.JniFlutterPlugin())
            e.plugins.add(eu.simonbinder.sqlite3_flutter_libs.Sqlite3FlutterLibsPlugin())
            val ch = MethodChannel(e.dartExecutor.binaryMessenger, CHANNEL)
            channel = ch
            ch.setMethodCallHandler { call, result ->
                if (call.method == "done") {
                    result.success(null)
                    val ok = call.arguments as? Boolean ?: false
                    finish(if (ok) Result.success() else Result.retry())
                } else {
                    result.notImplemented()
                }
            }
            e.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), ENTRYPOINT),
                listOf(task),
            )
        }
    }

    /// WorkManager stopped the work (time limit, Wi-Fi gone). The engine
    /// is torn down only once Dart has wound down: downloads paused, its
    /// port name released, its connection closed.
    override fun onStopped() {
        main.post {
            val ch = channel
            if (ch == null) {
                finish(Result.retry())
                return@post
            }
            val giveUp = Runnable { finish(Result.retry()) }
            main.postDelayed(giveUp, STOP_GRACE_MS)
            ch.invokeMethod("stop", null, object : MethodChannel.Result {
                override fun success(result: Any?) = done()
                override fun error(code: String, msg: String?, details: Any?) = done()
                override fun notImplemented() = done()
                private fun done() {
                    main.removeCallbacks(giveUp)
                    finish(Result.retry())
                }
            })
        }
    }

    private fun destroyEngine() {
        main.post {
            channel?.setMethodCallHandler(null)
            channel = null
            engine?.destroy()
            engine = null
        }
    }

    companion object {
        const val CHANNEL = "com.openhearth.trellis/feed_check_worker"
        const val ENTRYPOINT = "feedCheckMain"
        private const val STOP_GRACE_MS = 9_000L

        /// Past the system's own ten minutes, which stops the work first.
        private const val MAX_RUN_MS = 11 * 60_000L
    }
}
