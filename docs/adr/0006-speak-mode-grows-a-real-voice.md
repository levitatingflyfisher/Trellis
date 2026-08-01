# ADR-0006: Speak mode grows a real voice — sentences are the unit of speech

- Status: Accepted (Phases 1–5 shipped — the engine picker is wired into
  `_speakLoop`; see "The engine picker, wired" and Consequences for what
  is proven through the seam versus unexecuted on real hardware)
- Date: 2026-08-14 (final wiring pass: 2026-08-14, same day)

## Context

Speak mode hands each PARAGRAPH to the platform voice (`flutter_tts`) and
awaits it. On the web that means Chrome's `speechSynthesis`, and the user's
verdict on it was "pauses and glitches a lot." Two independent facts explain
this without inventing a third:

1. A whole paragraph can be a genuinely long utterance, and long
   `speechSynthesis` utterances are known to stall in Chrome past roughly 15
   seconds (a documented, long-standing engine bug, not a Trellis defect).
2. The pinned `flutter_tts` (4.2.5, per `pubspec.lock`) already runs the
   standard workaround for this INTERNALLY: its web implementation
   (`flutter_tts_web.dart`) starts a `Timer.periodic(Duration(seconds: 14))`
   on `onStart` that calls `synth.pause(); synth.resume();` for the duration
   of any utterance spoken with a non-local voice, and cancels it on
   `onEnd`. This was verified by reading the vendored package source before
   writing a second one — see `device_services.dart`'s `FlutterTtsSpeaker`
   doc comment.

Fact 2 means the keep-alive this campaign might have added at the app layer
would have duplicated (and could race) a timer the dependency already runs.
The gap that's genuinely still open is narrower than "Chrome's engine
stalls": it's "a LOCAL voice, which the plugin's own guard skips, reading a
long utterance." Making utterances short closes that gap directly, and also
happens to be the correct fix for the deeper architectural problem: a
paragraph is not a natural unit of speech. A sentence is.

Separately, VISION's freedom-of-compute ladder promises a T2 tier
("Piper/Kokoro TTS") that speak mode has never delivered — it has shipped on
system TTS only (the ladder's zero-byte rung) since v1.0. This ADR is also
that promise's first real installment.

## Decision

### The sentence-unit speech spine

`loom_core` gains `splitSentences(String text) -> List<Sentence>`
(`packages/loom_core/lib/src/sentence_splitter.dart`): terminal-punctuation
boundaries with modest abbreviation/initial tolerance (a wrong SPLIT costs a
listener one extra breath — acceptable; the tolerance list is not
exhaustive, by design, and a regression test pins that honestly). Each
`Sentence.firstWordIdx` is NOT a re-derived word count — it is read straight
off `tokenizeDocument`'s own word count for the sentence's prefix, because it
feeds `globalWordIndex`/`cursorAt` (ADR-0002) and from there
`savePosition`'s `segmentIdx`+`wordIdx`. A wrong index there is a wrong
PERSISTED cursor, not a stylistic quibble — a naive whitespace count drifts
by exactly one word on any block containing a hyphenated compound (the
tokenizer's own hyphen-split), which is the discriminating regression test.

`reader_screen.dart`'s `_speakLoop` ticks per SENTENCE instead of per whole
block for the existing `TtsSpeaker` path: every current test fixture happens
to be one sentence per segment, so this was a behavior-preserving refactor
for them; the new coverage proves the actual change — a two-sentence block
now produces two utterances and two cursor stops, not one long call.

### Two engine shapes behind one contract

`lib/features/reader/speech/speech_engine.dart`:

- `UtteranceSpeechEngine` wraps the existing `TtsSpeaker` seam:
  `speak()`/`stop()`, `canPause == false` (no platform voice exposes a
  reliable mid-utterance pause across targets).
- `SynthesisSpeechEngine` is the neural rung's contract:
  `synthesize(sentence, lang) -> SynthResult` (raw PCM + sample rate),
  `canPause == true` (the player owns pause/resume, not the engine).
  `SynthResult.durationMs` is EXACT — `samples.length / sampleRate` — never
  estimated. **No sherpa/Piper/Kokoro engine exposes word-level timing.**
  Sentence-exact IS the timing contract this campaign ships, permanently,
  not a placeholder for something finer (Phase 4, below).

`canPause` is the one fact the UI needs before offering a control an engine
can't honor.

### The gapless playback pipeline

`SpeechPlaybackPipeline` (`speech_playback_pipeline.dart`) drives a
`SynthesisSpeechEngine` through a sentence list: synthesizes AHEAD of
playback (lookahead 2 sentences — while sentence N plays, N+1 and N+2 are
already rendering), writes each result to a temp WAV
(`speech_temp_files.dart`, `wavBytes()` — a minimal 16-bit mono encoder, no
new audio format), and appends the files IN SENTENCE ORDER to a
`SpeechAudioQueue` regardless of which finishes rendering first (a
sequential await loop makes this an invariant, not a race). `SpeechAudioQueue`
(`speech_audio_queue.dart`) is a narrow seam over `just_audio` mirroring the
podcast player's own `EpisodePlayer`/`JustAudioEpisodePlayer` split — the
SAME audio engine the app already ships, never a second one, per the
research verdict. Sentence-start callbacks fire off the queue's OWN index
stream, never an app-side timer: the queue holds exactly one clip per
sentence, so an index change IS a sentence boundary by construction, and
this can't drift from what's actually audible.

Generation fencing mirrors `reader_screen`'s existing `_speakGen` law one
level lower in the stack: every `start()` bumps a counter, and any
synthesis result that resolves after a `stop()` or a superseding `start()`
is discarded before it reaches the queue or disk — proven by a scripted
fake engine whose completions the test controls out of order.

`JustAudioSpeechQueue` (the real implementation) uses `AudioPlayer`'s own
`addAudioSource`/`clearAudioSources` rather than the now-deprecated
`ConcatenatingAudioSource` class. It is not unit-tested directly, matching
`JustAudioEpisodePlayer`'s own precedent: a platform channel has nothing to
fake, and every behavior above it is proven through the pipeline's tests
with a scripted fake queue.

### The sherpa-onnx rung (Android)

`sherpa_onnx` (Apache-2.0, `^1.13.5`) is the neural engine.
`SherpaSpeechEngine` (`sherpa_engine.dart`) implements
`SynthesisSpeechEngine` over its `OfflineTts`, with the native call layer
behind a narrow `SherpaVoiceHandle` seam
(`sherpa_voice_handle.dart`) — every engine test fakes the handle and never
loads a native symbol or calls `sherpa_onnx.initBindings()` (which lives
ONLY inside the real handle factory, never in the engine's constructor —
the discriminating property a fresh engine can be built and tested on a
host VM with no sherpa binary present at all). The handle is created lazily
on the first `synthesize()` call and stays resident until `dispose()` —
`transcribe_core`'s whisper-engine residency law, one level over (create
per use, dispose explicitly; no LRU pool, no timer-driven eviction — the
app has exactly one voice active at a time in v1). Missing voice files and
a native init failure are typed exceptions
(`SherpaVoiceMissingFilesException` / `SherpaNativeInitException`), never a
bare platform error.

Kept OFF the web build by the repo's established conditional-export trio
(`whisper_ffi`'s pattern: `export 'src/real.dart' if (dart.library.js_interop)
'src/unsupported.dart';`) — for a DIFFERENT reason than whisper's, worth
recording precisely so a future reader doesn't assume the wrong one:
`package:sherpa_onnx` (as of the pinned version) actually compiles fine on
web now — it self-routes to a WASM implementation under
`dart.library.js_interop` internally. Whisper's split exists because
`dart:ffi` genuinely cannot compile to JS; sherpa's split here is pure
SCOPE — this campaign ships no web neural tier yet (see Phase 4), and
resolving the real branch on web would pull sherpa's native/plugin payload
into a bundle that would never use it. The web stub mirrors
`unsupported_stub_test.dart`'s own compile-level pin: it `implements
SynthesisSpeechEngine` and refuses, naming the native tier, so a seam
change breaks the stub the same build it breaks the real one.

Android's `build.gradle.kts` gains an explicit `ndk { abiFilters +=
"arm64-v8a" }`. The APK has been arm64-only in EFFECT since whisper.cpp
landed (only `jniLibs/arm64-v8a/libwhisper.so` is committed — an install on
another ABI would simply find no whisper library at runtime), but never by
enforcement. sherpa's per-ABI natives ship inside the pub package's own
platform AARs (`sherpa_onnx_android_arm64`/`armeabi`/`x86`/`x86_64`), so
without this filter more than one ABI's worth could land in a merged APK.
**Unverified against an actual Gradle build in this environment** — added
on the strength of the Android Gradle Plugin's Kotlin DSL contract, not a
build that was run; the next Android build should confirm it.

### Voices join the model registry — data, not code

`ModelSpec` gains an optional `VoiceArchiveLayout` (`topLevelDir`,
`modelFileName`, `tokensFileName`, `dataDirName`) — the surface a NEW voice
uses to become a complete registry entry with zero engine-code changes.
`DiskModelStore` extracts an archive spec's downloaded `.tar.bz2`
(`package:archive`'s `BZip2Decoder` + `TarDecoder`) into a staging directory
and atomically renames it into `voiceDirOf(spec)` — the same
verify-then-promote law a plain file's sha256 check already follows, one
level up: a directory rename is atomic on the same filesystem, so there is
no partially-extracted state to distinguish from "not yet". `isDownloaded`
for an archive spec means "the extracted directory exists"; the tarball is
deleted once extraction succeeds (no reason to keep both the compressed and
extracted copies). A missing or renamed upstream top-level directory is a
typed `ModelExtractionException`, never a silent partial install.

The starter registry gains `piper-en-libritts-r-medium`: Piper
`en_US-libritts_r-medium`, int8-quantized (23.4 MB — picked on SIZE,
matching the fleet's whisper-q8 precedent; **nobody verified this by ear in
this pass**, and TTS quantization artifacts are audible in a way ASR's
q8 isn't, so fp16/full are drop-in re-pins if the maintainer judges int8
rough — see `docs/reference/tts-voices.md`). URL, sha256, and byte size were
verified 2026-08-14 by downloading, hashing, and extracting the real release
asset — the `VoiceArchiveLayout` in code matches what actually came out of
the tarball, not a guessed shape.

**The license verification, verbatim, with fetch date, lives in
`docs/reference/tts-voices.md`.** Summary: `en_US-libritts_r-medium`'s
MODEL_CARD names its dataset (LibriTTS-R, OpenSLR 141) under CC BY 4.0 —
freely redistributable with attribution. The other size-comparable
candidate, `en_US-lessac-medium`, was rejected: its MODEL_CARD's license
field is a link, and following it (not assuming) surfaces a gated,
per-user, manually-issued "RESEARCH LICENCE AGREEMENT" between Voice
Factory International and Lessac Technologies — not freely
redistributable inside an app's asset catalog. `ModelSpec.licenses` for the
starter voice states `['CC-BY-4.0', 'GPL-3.0']` — both facts, surfaced for
free through the existing models screen's licenses line (see Licensing,
below, for the second one).

### Speak-mode door honesty

`DeviceServices.speechEngineFor(voiceSpec)` is the `localMlAvailable`
honesty gate one layer deeper: null unless this tier can run local ML AND
the specific voice is actually downloaded — never a bare crash on a
missing/mis-registered spec. `ReaderScreen.offerNeuralVoice` (a plain bool
the caller resolves from `DeviceServices`, keeping the widget's own test
surface a bool rather than a device mock) shows ONE quiet `SnackBar` naming
Models the first time speech starts with no voice downloaded — never a
repeated nag (ADR-0003 law 5). The download itself starts only on the
user's explicit tap through the existing consent chokepoint (ADR-0003 law
6) — the models screen's download flow is unchanged; the voice is simply
one more registry entry inside it.

### The engine picker, wired

`_speakLoop` forks on which `SpeechEngine` `_resolveEngine()` returns.
Resolution happens once, in `_load()` (not literally at the moment speech
starts — priming it there lets the settings-escape menu item know whether a
neural voice exists BEFORE the user's first speak-toggle press, and the
result is cached for the screen's session, the same residency law as the
`TtsSpeaker` holder): `DeviceServices.resolveSpeechEngine(lang:)` applies
the registry's selection law (`ModelRegistry.pickModel(ModelTask.tts,
tier, langHint:)`) then the download-honesty gate
(`speechEngineFor`) — null either way means the system voice, same as
before this pass.

The resolution is keyed to `widget.work.lang`, not `_activeLang` — a
language toggle (ADR-0002's mt-layer projection) does NOT re-pick the
voice mid-session. With one English voice on the starter catalog this is
a harmless scoped simplification (worst case: a toggle silently keeps the
system voice, or keeps the English voice speaking a different language's
text) — it stops being harmless the moment a second-language voice joins
the registry, at which point re-resolving on toggle becomes a real fix,
not a nice-to-have.

- **Utterance engines** keep the original per-sentence awaited loop
  (`_speakWithUtterance`), unchanged in shape.
- **Synthesis engines** hand the REST of the document's sentences —
  computed by `_remainingSpeechUnits`, which flattens every speakable
  segment from the cursor to the end — to a long-lived
  `SpeechPlaybackPipeline` (reused across runs; its own generation counter
  makes reuse safe) and return immediately, exactly as fire-and-forget as
  the utterance path from the caller's perspective. Sentinel segments
  (code/table/figure) are excluded from that flat list outright — the
  utterance path's silent "blip" through them has no analogue in a flat
  gapless list, so the neural voice simply never stops there. A
  deliberate, tested divergence between the two engines
  (`reader_speak_synthesis_test.dart`'s sentinel group), not a bug:
  synthesizing "[code]" aloud would be worse than skipping it.

`SpeechAudioQueue` gained the "finished naturally" signal
(`completedStream`, mirroring `EpisodePlayer.completedStream`'s
`processingStateStream` → `ProcessingState.completed` mapping).
`SpeechPlaybackPipeline` gates it behind its OWN `_reachedEnd` flag (set
only once the synthesis loop has appended the LAST sentence) because the
stream alone cannot distinguish "nothing more is coming" from "playback
merely caught up to the lookahead buffer" — a completed event that arrives
before the run has genuinely finished is silently dropped, proven by a
dedicated pipeline test. `_speakGen` fencing is preserved across BOTH
paths: the pipeline's callbacks are bound once (reuse, not
reconstruction), so `_onSynthSentenceStart`/`_onSynthDone` check a
`_synthGen` field set at the start of each run against the live
`_speakGen`, on top of — not instead of — the pipeline's own internal
generation check. Stopping mid-run tears the pipeline down
(`pipeline.stop()`) and deletes every temp file it had already written; a
run that finishes naturally restores the non-speaking state through the
exact same `_finishSpeaking` call the utterance path uses.

**Pause is not wired to any control this pass.** `SpeechEngine.canPause`
is real and `SpeechPlaybackPipeline.pause()`/`.resume()` work, but the
existing speak-toggle button is binary (reading aloud / not) — there is no
natural affordance in the current UI for a third "paused" state without
inventing new surface, which this pass deliberately declines to do. A
future pass that wants pause needs a real UI decision, not a wiring one.

### The settings escape

`Profiles` gains `preferSystemVoice` (schema v7, `addColumn` migration) —
a profile-scoped bool, false by default, so the reader uses a neural voice
whenever one is on-device and falls back to the system voice either way
when none is. The ONE control this exposes — `CheckedPopupMenuItem` in the
existing reader overflow menu, "Use the system voice" — appears ONLY when
a neural voice actually resolved for this work (no dead settings,
ADR-0003 law 5's sibling for controls, not just nags): toggling it flips
the persisted value and takes effect on the NEXT speak run, never a
mid-sentence engine hot-swap.

Migration tests for schema versions BEFORE v7 (`study_db_test.dart`
v2→v3, `jobs_db_test.dart` v3→v4, `ledger_db_test.dart` v4→v5,
`household_db_test.dart` v5→v6) build their synthetic "old" database from
the CURRENT live schema and drop only what their own target version
added — a technique that silently broke the moment `addColumn` (not
idempotent, unlike `createTable`) landed on a table those tests never
touch directly. Each now also drops `prefer_system_voice` when stamping
its synthetic `user_version`, restoring the "what remains IS that version's
schema" invariant the tests already claimed to establish.

## Phase 4 — recorded, not built

- **No word-level karaoke.** No engine (sherpa/Piper/Kokoro included)
  exposes word timing. Sentence-exact is the permanent contract this
  campaign ships — restated here so it is never mistaken for an
  intermediate step toward word highlighting.
- **No web neural tier yet.** `kokoro-js` via JS interop is the recorded
  next rung for the browser (an 86MB+ opt-in download, WebGPU-gated); the
  web tier ships the improved sentence-chunked system rung from this ADR
  instead. Note for a future pass: `sherpa_onnx`'s OWN package now ships a
  WASM web path internally (see above) — worth evaluating directly against
  kokoro-js before building either, since it may already do most of the
  work.
- **No Kokoro model yet.** The T2 bundle is ~686MB fp32; it becomes a
  second registry entry later, the quality rung above Piper.

## Licensing

**Superseded by [ADR-0007](0007-the-voice-goes-mit.md).** This section
is left exactly as written — an accurate record of what was true when
sherpa-onnx shipped the neural rung — but it is no longer the current
answer: ADR-0007 replaces sherpa-onnx/Piper with Supertonic, which needs
no phonemizer and carries no GPL-3.0 obligation. Read ADR-0007 for the
present state; read the rest of this section for the finding that made
that replacement necessary.

`sherpa-onnx`'s TTS path bundles `espeak-ng`'s phoneme data
(`espeak-ng-data/`, inside the SAME release archive as the voice weights)
today — GPL-3.0. Upstream issue #3731 plans its removal; undated. **This
means an APK carrying this rung distributes GPL-3.0 code.** The repo stays
MIT; the shipped BINARY's obligations change the moment this rung is built
into a release, which is a real fact this ADR states rather than hides. The
RELEASE decision — ship this rung, wait for espeak-ng's removal, or take the
escape hatch below — is explicitly the maintainer's, not decided here.

**Recorded escape hatch if the maintainer declines:** `piper-plus`
(MIT-licensed, espeak-free phonemization) is the named alternative sherpa's
own ecosystem offers, should the GPL-3.0 obligation be unacceptable for a
given release channel.

## Consequences

- Speak mode's actual "pauses and glitches" fix ships today, on the
  zero-byte system rung, for every platform — the sentence-unit spine, not
  the neural rung, is what most users will feel first.
- **The neural rung is wired end to end and proven through the seam, not
  on real hardware.** `_speakLoop` genuinely forks on the resolved engine;
  `reader_speak_synthesis_test.dart` drives the full path — cursor
  advance, Position saves, stop mid-sentence tearing down the pipeline and
  its temp files, natural completion, generation fencing across a quick
  stop/restart, the sentinel divergence, the settings escape — through a
  `FakeSynthesisSpeechEngine` and `FakeSpeechAudioQueue`, never a real
  `sherpa_onnx` handle or a real `just_audio` player. What remains
  genuinely unexecuted: `sherpa_onnx.initBindings()`/`OfflineTts`
  actually opening a native handle and producing audible PCM on an arm64
  device, and `JustAudioSpeechQueue`'s real `AudioPlayer` actually playing
  it gaplessly. Both are one Android build and a phone away, not further
  code.
- The `abiFilters` addition is unverified against a real Gradle build in
  this environment (no Android build was run — "do not build artifacts"
  was a hard constraint on this pass). The next Android build should
  confirm the merged APK is arm64-only.
- Sizing an APK that bundles a 23MB voice, and the GPL-3.0 obligation
  above, are both real release-decision inputs this ADR surfaces but does
  not resolve.
