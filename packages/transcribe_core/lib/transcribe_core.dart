/// The transcription pipeline as a checkpointed `jobs_core` task
/// (proposal-2 §9): windowed ASR over a seekable PCM seam, VAD gating,
/// overlap merge, sentence-ish segmentization into the `loom_core` spine.
/// Pure Dart — decode, files and FFI are adapter concerns in the app.
library;

export 'src/pcm_source.dart';
export 'src/segmentize.dart';
export 'src/transcribe_task.dart';
export 'src/window_plan.dart';
