package com.openhearth.trellis

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Bundle
import android.util.SizeF
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject

/// The home-screen widget (1.5.5): last played with Play/Pause (and the
/// player bar's own Back 15 s / Forward 30 s where they fit), and the text
/// last read. It draws only from the snapshot Dart left in WidgetBridge,
/// so it works in a process that started just for it.
///
/// Play/Pause goes to Dart, not to the media session: the player is
/// created on the first Play, so before that a media key reaches nothing,
/// and Dart's toggle is what keeps the place saved and the smart-resume
/// rewind. The rule for a tap that plays without the app's screen:
///  - only when Dart is running AND the player already holds the work's
///    audio (the snapshot's `loaded`). Playing then is a resume of a ready
///    player, done well inside the moment Android lets a background app
///    start its playback service after a widget tap;
///  - otherwise Play opens the app, which loads and resumes the work in
///    the foreground. Loading a stream can take seconds, long enough for a
///    background start of the playback service to be refused and the app
///    to crash out of sight, so it never happens behind the screen.
/// Pause needs no such care. The taps go to WidgetTapReceiver, which no
/// other app can reach; only this provider is exported, for the
/// launcher's APPWIDGET_UPDATE.
class TrellisWidget : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) render(context, manager, id)
    }

    override fun onAppWidgetOptionsChanged(
        context: Context, manager: AppWidgetManager, id: Int, options: Bundle,
    ) {
        render(context, manager, id)
    }

    /// The parsed snapshot. Kept to plain org.json reads so there is
    /// nothing here to test that Dart's own writer tests don't pin.
    data class Audio(
        val workId: Long, val title: String, val show: String?, val art: String?,
        val positionMs: Long, val durationMs: Long?, val playing: Boolean,
        val loaded: Boolean,
    )

    data class Reading(val workId: Long, val title: String, val progress: Double)

    data class Snapshot(val profileId: Long, val audio: Audio?, val reading: Reading?) {
        companion object {
            fun parse(json: String?): Snapshot? = try {
                if (json == null) null else {
                    val o = JSONObject(json)
                    val a = o.optJSONObject("audio")
                    val r = o.optJSONObject("reading")
                    Snapshot(
                        profileId = o.optLong("profileId"),
                        audio = a?.let {
                            Audio(
                                workId = it.getLong("workId"),
                                title = it.getString("title"),
                                show = it.stringOrNull("show"),
                                art = it.stringOrNull("art"),
                                positionMs = it.optLong("positionMs"),
                                durationMs = if (it.isNull("durationMs")) null else it.getLong("durationMs"),
                                playing = it.optBoolean("playing"),
                                loaded = it.optBoolean("loaded"),
                            )
                        },
                        reading = r?.let {
                            Reading(it.getLong("workId"), it.getString("title"), it.optDouble("progress", 0.0))
                        },
                    )
                }
            } catch (e: Exception) {
                null
            }

            private fun JSONObject.stringOrNull(key: String): String? =
                if (isNull(key)) null else optString(key).ifEmpty { null }
        }
    }

    companion object {
        const val TAP_PLAY = "com.openhearth.trellis.widget.TAP_PLAY"
        const val TAP_PAUSE = "com.openhearth.trellis.widget.TAP_PAUSE"
        const val TAP_BACK = "com.openhearth.trellis.widget.TAP_BACK"
        const val TAP_FORWARD = "com.openhearth.trellis.widget.TAP_FORWARD"

        /// Size breakpoints in dp. Width: under 180 the art gives the
        /// title its room; from 250 the skips or the reading card fit
        /// beside Play; from 380 both. Height: the player row is 48dp, so
        /// with the card's 4dp padding it needs 56, which is the provider's
        /// minHeight and minResizeHeight, so the card is never placed
        /// shorter; two rows need 4 + 48 + 48 + 4 = 104.
        private const val NARROW = 180f
        private const val WIDE = 250f
        private const val WIDER = 380f
        private const val ROOMY = 56f
        private const val TALL = 104f
        private const val ART_PX = 128

        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, TrellisWidget::class.java))
            for (id in ids) render(context, manager, id)
        }

        private fun render(context: Context, manager: AppWidgetManager, id: Int) {
            val snap = Snapshot.parse(WidgetBridge.snapshot(context))
            val alive = WidgetBridge.dartAlive()
            val art = snap?.audio?.art?.let { decodeArt(it) }
            val views = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val widths = listOf(110f, NARROW, WIDE, WIDER)
                val sizes = widths.map { SizeF(it, ROOMY) } +
                    listOf(SizeF(110f, TALL), SizeF(NARROW, TALL), SizeF(WIDE, TALL))
                RemoteViews(sizes.associateWith { build(context, snap, alive, art, it.width, it.height) })
            } else {
                val o = manager.getAppWidgetOptions(id)
                // Portrait: the narrowest width and the tallest height.
                val w = o.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, WIDE.toInt())
                val h = o.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 40)
                build(context, snap, alive, art, w.toFloat(), h.toFloat())
            }
            manager.updateAppWidget(id, views)
        }

        private fun build(
            context: Context, snap: Snapshot?, alive: Boolean, art: Bitmap?, w: Float, h: Float,
        ): RemoteViews {
            val v = RemoteViews(context.packageName, R.layout.widget_trellis)
            val audio = snap?.audio
            val reading = snap?.reading
            val profileId = snap?.profileId ?: 0L
            val tall = h >= TALL
            val wide = w >= WIDE
            val readingSide = reading != null && !tall && wide
            val readingBelow = reading != null && tall
            // A skip or a headless Play needs a loaded player in a live app.
            val ready = alive && audio?.loaded == true
            val skips = ready &&
                if (tall) wide else (w >= WIDER || (wide && reading == null))
            val px = context.resources.displayMetrics.density
            v.setViewVisibility(R.id.widget_art, if (w >= NARROW) View.VISIBLE else View.GONE)
            // Every branch sets the art's inset: a redraw reapplies onto the
            // views already shown, so an inset cleared for a cover would
            // otherwise stay cleared for the glyph.
            val glyphInset = (8 * px).toInt()

            if (audio == null) {
                v.setTextViewText(R.id.widget_title, context.getString(R.string.widget_nothing_playing))
                v.setViewVisibility(R.id.widget_show, View.GONE)
                v.setViewVisibility(R.id.widget_progress, View.GONE)
                v.setViewVisibility(R.id.widget_play, View.GONE)
                v.setImageViewResource(R.id.widget_art, R.drawable.ic_widget_headphones)
                v.setViewPadding(R.id.widget_art, glyphInset, glyphInset, glyphInset, glyphInset)
                v.setContentDescription(R.id.widget_audio, context.getString(R.string.widget_open_app))
                v.setOnClickPendingIntent(R.id.widget_audio, launch(context))
            } else {
                v.setTextViewText(R.id.widget_title, audio.title)
                if (audio.show == null) {
                    v.setViewVisibility(R.id.widget_show, View.GONE)
                } else {
                    v.setViewVisibility(R.id.widget_show, View.VISIBLE)
                    v.setTextViewText(R.id.widget_show, audio.show)
                }
                val duration = audio.durationMs
                if (duration == null || duration <= 0) {
                    v.setViewVisibility(R.id.widget_progress, View.GONE)
                } else {
                    v.setViewVisibility(R.id.widget_progress, View.VISIBLE)
                    v.setProgressBar(
                        R.id.widget_progress, 1000,
                        (audio.positionMs * 1000 / duration).toInt().coerceIn(0, 1000), false,
                    )
                }
                if (art != null) {
                    v.setImageViewBitmap(R.id.widget_art, art)
                    // A real cover fills the tile; the glyph keeps its inset.
                    v.setViewPadding(R.id.widget_art, 0, 0, 0, 0)
                } else {
                    v.setImageViewResource(R.id.widget_art, R.drawable.ic_widget_headphones)
                    v.setViewPadding(R.id.widget_art, glyphInset, glyphInset, glyphInset, glyphInset)
                }
                v.setContentDescription(R.id.widget_audio, context.getString(R.string.widget_open_work))
                v.setOnClickPendingIntent(
                    R.id.widget_audio,
                    activity(context, WidgetBridge.ACTION_OPEN_WORK, 10, audio.workId, profileId),
                )
                // Only a process with Dart in it can be playing.
                val playing = audio.playing && alive
                v.setViewVisibility(R.id.widget_play, View.VISIBLE)
                v.setImageViewResource(
                    R.id.widget_play, if (playing) R.drawable.ic_widget_pause else R.drawable.ic_widget_play,
                )
                v.setContentDescription(
                    R.id.widget_play,
                    context.getString(if (playing) R.string.widget_pause else R.string.widget_play),
                )
                v.setOnClickPendingIntent(
                    R.id.widget_play,
                    when {
                        playing -> broadcast(context, TAP_PAUSE, 2)
                        ready -> broadcast(context, TAP_PLAY, 1)
                        // Not ready to play headless (see the class note):
                        // open the app, the one launch Android always
                        // allows from a widget, and resume there.
                        else -> PendingIntent.getActivity(
                            context, 11, playIntent(context, snap), FLAGS,
                        )
                    },
                )
                v.setOnClickPendingIntent(R.id.widget_back, broadcast(context, TAP_BACK, 3))
                v.setOnClickPendingIntent(R.id.widget_forward, broadcast(context, TAP_FORWARD, 4))
            }
            // A skip needs a loaded player, which only a running app has.
            val skipVisibility = if (skips && alive) View.VISIBLE else View.GONE
            v.setViewVisibility(R.id.widget_back, skipVisibility)
            v.setViewVisibility(R.id.widget_forward, skipVisibility)

            v.setViewVisibility(R.id.widget_reading_side, if (readingSide) View.VISIBLE else View.GONE)
            v.setViewVisibility(R.id.widget_reading_below, if (readingBelow) View.VISIBLE else View.GONE)
            if (reading != null) {
                val read = activity(context, WidgetBridge.ACTION_READ, 12, reading.workId, profileId)
                val part = (reading.progress * 1000).toInt().coerceIn(0, 1000)
                v.setTextViewText(R.id.widget_reading_side_title, reading.title)
                v.setProgressBar(R.id.widget_reading_side_progress, 1000, part, false)
                v.setOnClickPendingIntent(R.id.widget_reading_side, read)
                v.setTextViewText(
                    R.id.widget_reading_below_title,
                    "${context.getString(R.string.widget_continue_reading)}: ${reading.title}",
                )
                v.setProgressBar(R.id.widget_reading_below_progress, 1000, part, false)
                v.setOnClickPendingIntent(R.id.widget_reading_below, read)
                val label = "${context.getString(R.string.widget_continue_reading)}: ${reading.title}"
                v.setContentDescription(R.id.widget_reading_side, label)
                v.setContentDescription(R.id.widget_reading_below, label)
            }
            return v
        }

        private const val FLAGS = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT

        private fun broadcast(context: Context, action: String, code: Int): PendingIntent =
            PendingIntent.getBroadcast(
                context, code,
                Intent(context, WidgetTapReceiver::class.java).setAction(action), FLAGS,
            )

        private fun activity(
            context: Context, action: String, code: Int, workId: Long, profileId: Long,
        ): PendingIntent = PendingIntent.getActivity(
            context, code,
            Intent(context, MainActivity::class.java).setAction(action)
                .putExtra(WidgetBridge.EXTRA_WORK_ID, workId)
                .putExtra(WidgetBridge.EXTRA_PROFILE_ID, profileId)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            FLAGS,
        )

        internal fun playIntent(context: Context, snap: Snapshot?): Intent =
            Intent(context, MainActivity::class.java).setAction(WidgetBridge.ACTION_PLAY)
                .putExtra(WidgetBridge.EXTRA_PROFILE_ID, snap?.profileId ?: 0L)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

        private fun launch(context: Context): PendingIntent = PendingIntent.getActivity(
            context, 13,
            Intent(context, MainActivity::class.java).setAction(Intent.ACTION_MAIN)
                .addCategory(Intent.CATEGORY_LAUNCHER)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            FLAGS,
        )

        /// The show's cover, shrunk to what a 40dp tile needs: a widget's
        /// bitmaps cross to the launcher process, which caps their size.
        private fun decodeArt(path: String): Bitmap? = try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= ART_PX && bounds.outHeight / (sample * 2) >= ART_PX) {
                sample *= 2
            }
            val decoded = BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
            decoded?.let {
                if (it.width <= ART_PX && it.height <= ART_PX) it
                else Bitmap.createScaledBitmap(it, ART_PX, ART_PX, true)
            }
        } catch (e: Exception) {
            null
        }
    }
}
