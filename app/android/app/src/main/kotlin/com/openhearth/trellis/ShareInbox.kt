package com.openhearth.trellis

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/// Share to Trellis (1.5.5): the share sheet's door. Kotlin only reads the
/// intent and copies shared files into the app's cache; what a share
/// becomes is decided in Dart (lib/features/intake/share_intake.dart),
/// where it is tested, and Dart keeps every share it has taken on disk
/// until it is saved (share_queue.dart).
///
/// A share waits here only until Dart takes it, which it does as soon as
/// the app is running: the engine is audio_service's cached one and can
/// outlive this activity, so a share may arrive in a fresh onCreate while
/// Dart has long since started, and Dart is told when one arrives.
object ShareInbox {
    const val CHANNEL = "com.openhearth.trellis/share"

    /// Books and audio are copied whole; text is read whole into memory
    /// on the Dart side, so it gets far less room. Anything else is never
    /// copied at all.
    private const val MAX_MEDIA_BYTES = 200L * 1024 * 1024
    private const val MAX_TEXT_BYTES = 8L * 1024 * 1024

    /// A provider that sends nothing for this long has stalled; a slow but
    /// moving one (a big file from cloud storage) is left to finish.
    private const val STALL_MS = 30_000L

    /// A copy younger than this may still be on its way to Dart.
    private const val SWEEP_AGE_MS = 10L * 60 * 1000

    private val pending = mutableListOf<Map<String, Any?>>()
    private val workers = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var cacheDir: File? = null

    fun attach(messenger: BinaryMessenger, context: Context) {
        cacheDir = File(context.cacheDir, "shared")
        channel = MethodChannel(messenger, CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "takePending" -> result.success(drain())
                    "sweep" -> {
                        val keep = (call.argument<List<String>>("keep") ?: emptyList()).toSet()
                        workers.execute { sweep(keep) }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun drain(): List<Map<String, Any?>> = synchronized(pending) {
        val all = pending.toList()
        pending.clear()
        all
    }

    private fun deliver(payload: Map<String, Any?>) {
        synchronized(pending) { pending.add(payload) }
        main.post { channel?.invokeMethod("shareArrived", null) }
    }

    fun receive(activity: Activity, intent: Intent?) {
        if (intent == null) return
        val action = intent.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return
        // Reopened from Recents, the old share intent comes back with it.
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
        val app = activity.applicationContext
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)
        val source = sourceAppOf(activity)
        val streams = streamsOf(intent, action)
        val type = intent.type
        fun payload(files: List<Map<String, Any?>>, refused: List<Map<String, Any?>>) = mapOf(
            "text" to text,
            "subject" to subject,
            "sourceApp" to source,
            "files" to files,
            "refused" to refused,
        )
        if (streams.isEmpty()) {
            // Text alone needs no copying, so it never waits behind a file.
            if (!text.isNullOrBlank()) deliver(payload(emptyList(), emptyList()))
            return
        }
        // Read now, while the share's URI grant is surely alive, but off
        // the main thread, and each share on its own worker so one slow
        // provider holds up only its own share. A refused file is still
        // delivered, as its reason, so the person hears why.
        workers.execute {
            val files = mutableListOf<Map<String, Any?>>()
            val refused = mutableListOf<Map<String, Any?>>()
            for (uri in streams) {
                when (val got = copyWatched(app, uri, type)) {
                    is Copied -> files.add(got.file)
                    is Refused -> refused.add(got.why)
                }
            }
            deliver(payload(files, refused))
        }
    }

    @Suppress("DEPRECATION")
    private fun streamsOf(intent: Intent, action: String): List<Uri> =
        if (action == Intent.ACTION_SEND_MULTIPLE) {
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM) ?: emptyList()
        } else {
            listOfNotNull(intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
        }

    /// The sharing app's name, from the referrer Android records. A label
    /// to show, not provenance: a sender can set EXTRA_REFERRER itself.
    private fun sourceAppOf(activity: Activity): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP_MR1) return null
        val referrer = activity.referrer ?: return null
        if (referrer.scheme != "android-app") return null
        val pkg = referrer.host ?: return null
        if (pkg == activity.packageName) return null
        return try {
            val pm = activity.packageManager
            pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
                .takeIf { it.isNotBlank() }
        } catch (e: Exception) {
            null
        }
    }

    /// How much of a stream may be copied, by its own type and name; null
    /// for a kind Trellis can't open, which is never copied.
    private fun capFor(mime: String?, name: String): Long? {
        val m = (mime ?: "").lowercase()
        val ext = name.substringAfterLast('.', "").lowercase()
        return when {
            m == "application/epub+zip" || ext == "epub" -> MAX_MEDIA_BYTES
            m.startsWith("audio/") ||
                ext in setOf("mp3", "m4a", "m4b", "ogg", "opus", "flac") -> MAX_MEDIA_BYTES
            m in setOf("text/plain", "text/markdown", "text/x-markdown", "text/html") ||
                ext in setOf("txt", "md", "markdown", "html", "htm") -> MAX_TEXT_BYTES
            else -> null
        }
    }

    private sealed class Copy
    private class Copied(val file: Map<String, Any?>) : Copy()
    private class Refused(val why: Map<String, Any?>) : Copy()

    private fun refusal(name: String, reason: String, bytes: Long? = null, limit: Long? = null) =
        Refused(mapOf("name" to name, "reason" to reason, "bytes" to bytes, "limit" to limit))

    /// One copy's state, read by the watchdog on another thread.
    private class Progress {
        @Volatile var input: InputStream? = null
        @Volatile var dest: File? = null
        @Volatile var lastByteAt: Long = System.currentTimeMillis()
    }

    /// [copy] under a watchdog: given up only when no byte has arrived for
    /// [STALL_MS], however long a moving copy takes.
    private fun copyWatched(context: Context, uri: Uri, intentType: String?): Copy {
        val progress = Progress()
        val job = workers.submit<Copy> { copy(context, uri, intentType, progress) }
        while (true) {
            try {
                return job.get(1, TimeUnit.SECONDS)
            } catch (e: TimeoutException) {
                if (System.currentTimeMillis() - progress.lastByteAt < STALL_MS) continue
            } catch (e: Exception) {
                progress.dest?.delete()
                return refusal(uri.lastPathSegment ?: "shared", "failed")
            }
            job.cancel(true)
            // Closing the stream is what unblocks a read stuck in a provider.
            try { progress.input?.close() } catch (_: Exception) {}
            progress.dest?.delete()
            return refusal(displayNameOf(context, uri), "stalled")
        }
    }

    /// One shared file into cache/shared/<random>-<name>, within its cap.
    /// Only content:// is taken: a file:// path could name this app's own
    /// private files, and neither is a URI of this app's own provider.
    private fun copy(context: Context, uri: Uri, intentType: String?, progress: Progress): Copy {
        val display = displayNameOf(context, uri)
        if (uri.scheme != "content") return refusal(display, "unsupported")
        if (uri.authority?.startsWith(context.packageName) == true) {
            return refusal(display, "unsupported")
        }
        val resolver = context.contentResolver
        val mime = resolver.getType(uri) ?: intentType
        val cap = capFor(mime, display) ?: return refusal(display, "unsupported")
        // A sender that states the size is refused before a byte is copied.
        val stated = sizeOf(context, uri)
        if (stated != null && stated > cap) return refusal(display, "tooBig", stated, cap)
        val dir = File(context.cacheDir, "shared")
        dir.mkdirs()
        val dest = File(dir, "${UUID.randomUUID()}-${safeName(display)}")
        progress.dest = dest
        return try {
            val src = resolver.openInputStream(uri) ?: return refusal(display, "failed")
            progress.input = src
            var total = 0L
            src.use { from ->
                dest.outputStream().use { to ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val n = from.read(buffer)
                        if (n < 0) break
                        total += n
                        progress.lastByteAt = System.currentTimeMillis()
                        if (total > cap) break
                        to.write(buffer, 0, n)
                    }
                }
            }
            if (total > cap) {
                dest.delete()
                refusal(display, "tooBig", stated, cap)
            } else {
                Copied(mapOf("path" to dest.absolutePath, "name" to display, "mimeType" to mime))
            }
        } catch (e: Exception) {
            dest.delete()
            refusal(display, "failed")
        }
    }

    private fun sizeOf(context: Context, uri: Uri): Long? = try {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)
            ?.use { c -> if (c.moveToFirst() && !c.isNull(0)) c.getLong(0) else null }
    } catch (e: Exception) {
        null
    }

    /// The name the sender gave, as people read it (any script): only path
    /// separators and control characters go, and it is kept short.
    private fun displayNameOf(context: Context, uri: Uri): String {
        val raw = try {
            context.contentResolver.query(
                uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null,
            )?.use { c ->
                if (c.moveToFirst() && !c.isNull(0)) c.getString(0) else null
            }
        } catch (e: Exception) {
            null
        } ?: uri.lastPathSegment ?: ""
        val shown = raw.substringAfterLast('/').substringAfterLast('\\')
            .filter { !it.isISOControl() }.trim().take(200)
        return shown.ifEmpty { "shared" }
    }

    /// The on-disk name: a sender names the file; it must not name where
    /// it goes.
    private fun safeName(raw: String): String {
        val clean = raw.replace(Regex("[^A-Za-z0-9._ -]"), "_").trim().trimStart('.')
        return clean.take(120).ifEmpty { "shared" }
    }

    /// Copies no waiting share needs: a share refused, a copy cut short by
    /// a killed process.
    private fun sweep(keep: Set<String>) {
        val now = System.currentTimeMillis()
        cacheDir?.listFiles()?.forEach { f ->
            if (f.absolutePath !in keep && now - f.lastModified() > SWEEP_AGE_MS) {
                f.deleteRecursively()
            }
        }
    }
}
