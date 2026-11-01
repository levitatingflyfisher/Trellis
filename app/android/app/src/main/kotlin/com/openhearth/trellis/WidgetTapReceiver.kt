package com.openhearth.trellis

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/// The widget's Pause and skip taps (1.5.5). Not exported, so only
/// the widget's own PendingIntents reach it, never another app.
///
/// A tap acts headless only on what the card was drawn for: Dart running
/// and, for the skips, the work's audio already in the player. Anything
/// else means the card went stale under it, and it is redrawn as things
/// now are. Play is not here: see WidgetPlayActivity.
class WidgetTapReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val snap = TrellisWidget.Snapshot.parse(WidgetBridge.snapshot(context))
        val alive = WidgetBridge.dartAlive()
        val ready = alive && snap?.audio?.loaded == true
        val kind = when (intent.action) {
            TrellisWidget.TAP_PAUSE -> if (alive) "pause" else null
            TrellisWidget.TAP_BACK -> if (ready) "back" else null
            TrellisWidget.TAP_FORWARD -> if (ready) "forward" else null
            else -> return
        }
        if (kind != null) {
            WidgetBridge.deliver(kind, profileId = snap?.profileId)
            return
        }
        TrellisWidget.refresh(context)
    }
}
