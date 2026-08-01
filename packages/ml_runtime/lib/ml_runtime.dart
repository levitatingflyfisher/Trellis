/// The ML runtime's pure core (proposal-2 §5): the seams the FFI engines
/// implement (Transcriber / Synthesizer / Vad), scripted deterministic
/// fakes for tests, the overlap-merge law for windowed transcription, the
/// pinned model registry with tiered selection, and the residency +
/// load-retry policies. No Flutter, no FFI, no I/O — those live in the app.
library;

export 'src/fakes.dart';
export 'src/registry.dart';
export 'src/residency.dart';
export 'src/seams.dart';
export 'src/transcript.dart';
