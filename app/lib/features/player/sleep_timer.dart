/// Sleep timer support: the pure fade curve applied over the final seconds
/// before a sleep timer stops playback. The timer's live state (mode,
/// remaining, shake-to-extend) lives on [PlayerController] — it drives off
/// the SAME position/duration streams playback already provides rather than
/// a wall-clock timer of its own, so it is exercised the same way the rest
/// of playback is: by scripting the player's streams (test/support/
/// fake_player.dart), never a real Timer.
library;

enum SleepTimerMode {
  /// Stops after a fixed duration counted from when the timer was armed.
  duration,

  /// Stops when the current episode reaches its end.
  endOfEpisode,
}

/// Full volume (1.0) outside the fade window; ramps linearly down to
/// silence (0.0) exactly at the stop instant. [remaining] may already be
/// negative (past the instant) — clamped to 0.0, never a negative volume.
double sleepTimerFadeVolume(Duration remaining,
    {Duration fadeWindow = const Duration(seconds: 20)}) {
  if (remaining >= fadeWindow) return 1.0;
  if (remaining <= Duration.zero) return 0.0;
  return remaining.inMilliseconds / fadeWindow.inMilliseconds;
}
