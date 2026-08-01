/// The speech-engine seam (ADR-0006): two capability shapes behind one
/// contract, so speak mode can grow a real (neural) voice without the
/// reader having to know which kind of voice it has, except where the two
/// genuinely differ.
///
///  * Utterance engines ([UtteranceSpeechEngine]) wrap the existing
///    [TtsSpeaker] seam (`device_services.dart`): one awaited `speak()`
///    call per sentence, no pause primitive — the platform decides when
///    the utterance is audible.
///  * Synthesis engines ([SynthesisSpeechEngine]) render PCM the app plays
///    itself, gaplessly, through [SpeechPlaybackPipeline] (the neural
///    rung — Supertonic's `SupertonicSpeechEngine`, ADR-0007, is the
///    current implementation) — and CAN be paused/resumed, because the
///    app owns the player, not the engine.
///
/// [SpeechEngine.canPause] is the one fact the UI needs before deciding
/// what controls to offer — it must never promise a pause button an engine
/// cannot honor.
library;

import 'dart:typed_data';

import '../../../services/device_services.dart' show TtsSpeaker;

sealed class SpeechEngine {
  bool get canPause;
}

/// The platform voice: one sentence per awaited call, no pause capability
/// (flutter_tts — including its browser speechSynthesis backing — exposes
/// no reliable mid-utterance pause across platforms).
class UtteranceSpeechEngine implements SpeechEngine {
  final TtsSpeaker speaker;
  const UtteranceSpeechEngine(this.speaker);

  @override
  bool get canPause => false;

  Future<void> speak(String sentence, {String? lang}) =>
      speaker.speak(sentence, lang: lang);

  Future<void> stop() => speaker.stop();
}

/// One synthesized sentence: raw linear PCM plus the sample rate it was
/// rendered at. [durationMs] is EXACT — `samples.length / sampleRate` —
/// never estimated: no Supertonic/Kokoro engine exposes word timing, so
/// sentence-exact IS the timing contract this campaign ships (ADR-0006),
/// not a placeholder for something finer later.
class SynthResult {
  final Float32List samples;
  final int sampleRate;
  const SynthResult({required this.samples, required this.sampleRate});

  int get durationMs =>
      sampleRate == 0 ? 0 : (samples.length / sampleRate * 1000).round();
}

/// A neural engine that renders audio the app plays itself. [canPause] is
/// always true — pause/resume is the player's job ([SpeechPlaybackPipeline]
/// via `just_audio`), not the engine's.
abstract interface class SynthesisSpeechEngine implements SpeechEngine {
  @override
  bool get canPause => true;

  Future<SynthResult> synthesize(String sentence, {String? lang});

  /// Releases native resources. Called on voice switch and on teardown —
  /// never mid-synthesis (the caller's responsibility to sequence).
  Future<void> dispose();
}
