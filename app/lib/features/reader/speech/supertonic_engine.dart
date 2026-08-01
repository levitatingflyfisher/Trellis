/// The Supertonic rung (ADR-0007): Supertone Inc.'s MIT-licensed TTS
/// engine over `flutter_onnxruntime`, behind the [SynthesisSpeechEngine]
/// contract. No phonemizer, no espeak — the model consumes raw character
/// indices, so there is nothing for a GPL dependency to hide in.
///
/// Kept OFF the web build by the repo's established conditional-export
/// trio (whisper_ffi's pattern, also the sherpa rung's own precedent this
/// replaces): a web neural TTS rung is recorded as future work
/// (ADR-0007), not built this pass, so resolving the real branch on web
/// would pull the native/plugin payload into a bundle that would never
/// use it.
library;

export 'src/supertonic_speech_engine.dart'
    if (dart.library.js_interop) 'src/supertonic_speech_engine_unsupported.dart';
