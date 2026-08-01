/// The Marian rung (ADR-0008 "Babel"): opus-mt-en-es over
/// `flutter_onnxruntime`, behind [MarianTranslator]. No phonemizer, no
/// beam search — greedy decode over a real encoder-once, decoder-with-
/// past generation loop.
///
/// Kept OFF the web build by the repo's established conditional-export
/// trio (whisper_ffi's pattern, also the Supertonic rung's own
/// precedent): a web ONNX tier is future work, not built this pass, so
/// resolving the real branch on web would pull the native/plugin payload
/// into a bundle that would never use it.
library;

export 'marian_generation_loop.dart';
export 'marian_types.dart';
export 'src/marian_translator.dart'
    if (dart.library.js_interop) 'src/marian_translator_unsupported.dart';
