package com.openhearth.trellis

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/// The widget's Play, Pause and skip taps (1.5.5). Not exported, so only
/// the widget's own PendingIntents reach it, never another app.
///
/// A tap acts headless only on what the card was drawn for: Dart running
/// and, for Play and the skips, the work's audio already in the player
/// (TrellisWidget's class note says why). Anything else means the card
/// went stale under it, and it is redrawn as things now are.
class WidgetTapReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val snap = TrellisWidget.Snapshot.parse(WidgetBridge.snapshot(context))
        val alive = WidgetBridge.dartAlive()
        val ready = alive && snap?.audio?.loaded == true
        val kind = when (intent.action) {
            TrellisWidget.TAP_PLAY -> if (ready) "play" else null
            TrellisWidget.TAP_PAUSE -> if (alive) "pause" else null
            TrellisWidget.TAP_BACK -> if (ready) "back" else null
            TrellisWidget.TAP_FORWARD -> if (ready) "forward" else null
            else -> return
        }
        if (kind != null) {
            WidgetBridge.deliver(kind, profileId = snap?.profileId)
            return
        }
        if (intent.action == TrellisWidget.TAP_PLAY) {
            // A card drawn ready whose app has since been killed outright
            // (the engine's own end redraws the card, but a low-memory kill
            // gives no notice). Opening the app from a receiver is a
            // background launch Android may refuse, and it refuses quietly,
            // without an exception; the redraw below makes the next tap the
            // plain open-the-app one either way.
            try {
                context.startActivity(TrellisWidget.playIntent(context, snap))
            } catch (e: Exception) {
                // Refused loudly on some versions; the redraw still follows.
            }
        }
        TrellisWidget.refresh(context)
    }
}
