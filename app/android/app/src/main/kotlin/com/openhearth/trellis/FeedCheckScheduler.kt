package com.openhearth.trellis

import android.content.Context
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.PeriodicWorkRequest
import androidx.work.WorkManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.TimeUnit

/// The background feed check's scheduling door (ADR-0018). Dart decides
/// every constraint and policy (lib/features/feeds/background/
/// feed_check_platform_io.dart, where the mapping is tested); this only
/// hands them to WorkManager.
object FeedCheckScheduler {
    const val CHANNEL = "com.openhearth.trellis/feed_check"
    const val TASK_KEY = "task"
    private const val PERIODIC = "trellis-feed-check"
    private const val AUTO_DOWNLOAD = "trellis-auto-download"

    fun attach(messenger: BinaryMessenger, context: Context) {
        val app = context.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            val work = WorkManager.getInstance(app)
            val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
            when (call.method) {
                "schedulePeriodic" -> {
                    val minutes = (args["everyMinutes"] as Number).toLong()
                    val request = PeriodicWorkRequest.Builder(
                        FeedCheckWorker::class.java, minutes, TimeUnit.MINUTES,
                    )
                        .setConstraints(constraints(args))
                        .setInputData(task("check"))
                        .build()
                    val policy = if (args["policy"] == "update") {
                        ExistingPeriodicWorkPolicy.UPDATE
                    } else {
                        ExistingPeriodicWorkPolicy.KEEP
                    }
                    work.enqueueUniquePeriodicWork(PERIODIC, policy, request)
                    result.success(null)
                }
                "cancelPeriodic" -> {
                    work.cancelUniqueWork(PERIODIC)
                    result.success(null)
                }
                "requestAutoDownload" -> {
                    val request = OneTimeWorkRequest.Builder(FeedCheckWorker::class.java)
                        .setConstraints(constraints(args))
                        .setInputData(task("autoDownload"))
                        .build()
                    work.enqueueUniqueWork(AUTO_DOWNLOAD, ExistingWorkPolicy.KEEP, request)
                    result.success(null)
                }
                "cancelAutoDownload" -> {
                    work.cancelUniqueWork(AUTO_DOWNLOAD)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun task(name: String): Data = Data.Builder().putString(TASK_KEY, name).build()

    private fun constraints(args: Map<*, *>): Constraints = Constraints.Builder()
        .setRequiredNetworkType(
            if (args["unmeteredOnly"] == true) NetworkType.UNMETERED else NetworkType.CONNECTED,
        )
        .setRequiresBatteryNotLow(args["batteryNotLow"] == true)
        .setRequiresCharging(args["charging"] == true)
        .build()
}
