package com.openhearth.trellis

import android.app.Application

/// Redraws the home-screen widget whenever the app's process starts. A
/// process killed outright (swiped away while paused, which Android 14
/// does with "remove task", or a low-memory kill) gets no chance to
/// redraw the card, so it would keep the Play it was drawn with for a
/// running app. A new process has no Dart attached yet, so this redraw is
/// the cold card, whose Play opens the app (TrellisWidget's class note).
/// Seen on the emulator: the swipe killed the process and audio_service
/// was restarted at once for media resumption, in a fresh process.
class TrellisApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        try {
            // The stored card may say "playing" and "loaded" for a player
            // that died with the old process; until this process's Dart
            // says otherwise, nothing plays and nothing is loaded, so no
            // redraw before Dart's first push can offer a headless Play.
            WidgetBridge.markCold(this)
            TrellisWidget.refresh(this)
        } catch (e: Exception) {
            // A widget that can't redraw keeps its last card; never a crash.
        }
    }
}
