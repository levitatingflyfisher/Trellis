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
///    itself, gaplessly, through [SpeechPlaybackPipeline] (Trellis's own
///    voices, ADR-0022: `PocketSpeechEngine` and `KokoroSpeechEngine`,
///    one per language behind `DownloadedVoices`) — and CAN be
///    paused/resumed, because the app owns the player, not the engine.
///
/// [SpeechEngine.canPause] is the one fact the UI needs before deciding
/// what controls to offer — it must never promise a pause button an engine
/// cannot honor.
library;

import 'dart:typed_data';

import '../../../services/device_services.dart' show SystemVoice, TtsSpeaker;

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

  Future<void> speak(String sentence, {String? lang, SystemVoice? voice}) =>
      speaker.speak(sentence, lang: lang, voice: voice);

  Future<void> stop() => speaker.stop();
}

/// One synthesized sentence: raw linear PCM plus the sample rate it was
/// rendered at. [durationMs] is EXACT — `samples.length / sampleRate` —
/// never estimated: neither Pocket TTS nor Kokoro exposes word timing, so
/// sentence-exact IS the timing contract this campaign ships (ADR-0006),
/// not a placeholder for something finer later.
class SynthResult {
  final Float32List samples;
  final int sampleRate;
  const SynthResult({required this.samples, required this.sampleRate});

  int get durationMs =>
      sampleRate == 0 ? 0 : (samples.length / sampleRate * 1000).round();
}

/// How a voice is asked to speak a sentence it saves (the one tap's
/// "How clearly the voice speaks"). [rate] scales how long a sentence
/// takes: 1.0 is as it speaks, 0.8 takes a quarter longer. Each engine
/// honours it its own way: Kokoro and the phone's voice speak slower;
/// Pocket TTS has no speed input, so it leaves a pause after the sentence
/// instead (`pocketPauseSamples`). [careful] asks the engine to spend
/// more work on each sound where it has a way to (Pocket TTS: four flow
/// steps instead of one); Kokoro and the phone's voice have none and
/// ignore it.
class SpeechPace {
  final double rate;
  final bool careful;
  const SpeechPace({this.rate = 1.0, this.careful = false});

  static const natural = SpeechPace();

  @override
  bool operator ==(Object other) =>
      other is SpeechPace && other.rate == rate && other.careful == careful;

  @override
  int get hashCode => Object.hash(rate, careful);

  @override
  String toString() => 'SpeechPace($rate${careful ? ', careful' : ''})';
}

/// A neural engine that renders audio the app plays itself. [canPause] is
/// always true — pause/resume is the player's job ([SpeechPlaybackPipeline]
/// via `just_audio`), not the engine's.
abstract interface class SynthesisSpeechEngine implements SpeechEngine {
  @override
  bool get canPause => true;

  /// The bare language tags it can say. A sentence in any other
  /// language is refused, never said in the wrong voice.
  Set<String> get speaks;

  /// [pace] is how a saved episode asks it to be said; an engine with no
  /// way to vary something leaves that as it is.
  Future<SynthResult> synthesize(String sentence,
      {String? lang, SpeechPace pace = SpeechPace.natural});

  /// Releases native resources. Called on voice switch and on teardown —
  /// never mid-synthesis (the caller's responsibility to sequence).
  Future<void> dispose();
}
