# whisper_ffi

whisper.cpp behind `ml_runtime`'s `Transcriber` seam.

- `WhisperBindings` — the raw dart:ffi symbol table of the pinned native
  shim (`wfs_*` exports of `libwhisper.so`; built and documented in
  [`../../natives/`](../../natives/README.md)). Fields are plain Dart
  function types, so unit tests substitute a recording fake symbol table
  and never touch native code.
- `WhisperTranscriber` — implements `Transcriber`: streams one
  `TranscriptChunk` per whisper segment (`tStartMs`/`tEndMs`), with
  best-effort word timings grouped from token-level timestamps. Params
  crossing the FFI boundary: language (null = auto-detect), the translate
  task, token timestamps on/off, thread count (default cores − 1), and
  `no_context` (default on — windows decode independently, which is what
  checkpoint-resumable jobs need). Each `transcribe` call owns one whisper
  context: freed on completion, error, and cancellation alike.

Windows off the `PcmChunkSource` are treated as consecutive audio; overlap
resolution belongs downstream (`mergeOverlap` in `ml_runtime`).

## Tests

```sh
dart test                                # unit: fake symbol table, no natives
dart test --tags native --run-skipped    # integration: real .so + pinned model
```

The native lane loads `natives/out/linux/libwhisper.so` and the pinned
`ggml-tiny-q8_0.bin` (paths overridable via `WHISPER_FFI_LIB` /
`WHISPER_FFI_TEST_MODEL`), transcribes generated speech-free audio, and
asserts the lifecycle: init, run, stream closes, re-run, no leak/crash. It
downloads nothing — see the natives README for the verified model recipe.
