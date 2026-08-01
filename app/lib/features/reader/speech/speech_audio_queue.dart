/// The gapless queue seam behind [SpeechPlaybackPipeline] — mirrors the
/// player feature's existing pattern (`episode_player.dart`'s
/// [EpisodePlayer]/`JustAudioEpisodePlayer` split): a narrow interface over
/// `just_audio`, so tests never reach a platform channel, and the SAME
/// audio engine backs both podcasts and speech (no second audio engine,
/// per the campaign's research verdict).
///
/// [currentIndexStream] is the pipeline's ONLY source of "a new sentence
/// started playing" — never an app-side timer, which could race the real
/// player's buffering. Because the queue holds exactly one clip per
/// sentence, an index change IS a sentence boundary, by construction.
library;

abstract class SpeechAudioQueue {
  /// Appends one more clip to the tail of the queue. Safe to call while
  /// the queue is already playing — that's the whole point (synthesize
  /// ahead, append as each sentence finishes rendering).
  Future<void> append(String filePath);

  Future<void> play();
  Future<void> pause();
  Future<void> resume();

  /// Empties the queue and stops playback. Does not delete files — that's
  /// the pipeline's job, since it owns the temp-file lifecycle.
  Future<void> clear();

  bool get playing;

  /// Fires the (0-based, queue-relative) index of whichever clip just
  /// became the active one.
  Stream<int> get currentIndexStream;

  /// Fires once when the queue has played every appended clip through to
  /// the end and stopped on its own — mirrors `EpisodePlayer.completedStream`
  /// (`just_audio_player.dart`'s `processingStateStream` →
  /// `ProcessingState.completed` mapping), the same signal shape one seam
  /// over. Never fires from `pause()` or `clear()`.
  ///
  /// This is necessary but not SUFFICIENT proof a run ended naturally: if
  /// playback ever catches up to the end of what's been appended so far
  /// (synthesis running behind the lookahead buffer), the underlying
  /// player has no way to know more clips are coming and reports
  /// "completed" too — the exact same trust assumption any gapless
  /// playlist player makes. [SpeechPlaybackPipeline] only treats this as
  /// the run's real end once its OWN synthesis loop has appended every
  /// sentence, which is the fact this stream alone cannot see.
  Stream<void> get completedStream;

  Future<void> dispose();
}
