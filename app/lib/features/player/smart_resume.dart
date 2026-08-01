/// Resuming a paused podcast episode rewinds by a small amount scaled to how
/// long it was paused — the small mercy that means you never resume mid-word.
/// Pure function; the caller supplies how long the pause lasted and applies
/// the result to the player's current position. Podcast playback only — the
/// reader has its own resume semantics under the cursor law (ADR-0002).
library;

/// <1 minute paused: barely lost the thread, back up 2s.
/// <1 hour paused: a typical interruption, back up 5s.
/// 1 hour or more: a real return, back up 10s for a fuller re-anchor.
Duration smartResumeRewind(Duration pauseLength) {
  if (pauseLength < const Duration(minutes: 1)) return const Duration(seconds: 2);
  if (pauseLength < const Duration(hours: 1)) return const Duration(seconds: 5);
  return const Duration(seconds: 10);
}
