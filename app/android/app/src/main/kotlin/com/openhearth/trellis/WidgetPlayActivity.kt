package com.openhearth.trellis

import android.app.Activity
import android.os.Bundle

/// The widget's Play, as an invisible activity rather than a broadcast. A
/// receiver opening the app is a background launch Android may refuse, and
/// it refuses quietly, so a card drawn ready whose app had since been
/// killed left a Play that did nothing. Started from the card, an activity
/// is allowed; from it, opening the app is too.
///
/// It decides as the receiver did: Play only when Dart is running and the
/// player holds the work's audio (TrellisWidget's class note says why).
/// Anything else opens the app, which resumes the work in the foreground.
class WidgetPlayActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val snap = TrellisWidget.Snapshot.parse(WidgetBridge.snapshot(this))
        if (WidgetBridge.dartAlive() && snap?.audio?.loaded == true) {
            WidgetBridge.deliver("play", profileId = snap?.profileId)
        } else {
            startActivity(TrellisWidget.playIntent(this, snap))
            TrellisWidget.refresh(this)
        }
        finish()
    }
}
