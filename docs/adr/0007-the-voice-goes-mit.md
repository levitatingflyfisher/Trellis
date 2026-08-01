# ADR-0007: The voice goes MIT — Supertonic replaces sherpa-onnx/Piper

- Status: Accepted (the engine, the registry entry, and sherpa's removal
  are shipped; proven through the interface with a faked ONNX Runtime
  boundary, not yet exercised on real hardware — see Consequences)
- Date: 2026-08-14
- Supersedes: ADR-0006's Licensing section (that section stays as
  written — a record of what was true when it was written — this ADR is
  the current answer; ADR-0006 now carries a pointer to here rather than
  being rewritten)

## Context

ADR-0006 shipped speak mode's neural rung on sherpa-onnx over a Piper
voice (`en_US-libritts_r-medium`), and was explicit that this made the
APK's licensing obligations a maintainer decision: sherpa-onnx's TTS
path bundles espeak-ng's phoneme data (`espeak-ng-data/`, inside the
same release archive as the voice weights) to turn text into phonemes
before synthesis. espeak-ng is GPL-3.0. This was verified empirically —
downloading and extracting the actual release archive, not read off a
changelog — in every shipped sherpa-onnx TTS release asset checked for
this campaign: there is no build flag that removes it, and the upstream
issue tracking its removal (k2-fsa/sherpa-onnx#3731) carries no target
date. Shipping this rung means shipping a GPL-3.0 binary inside a fleet
whose convention is MIT. That is a real fact, not a hypothetical one,
and it is the reason the 1.1.0 APK was deliberately not rebuilt with
sherpa aboard.

Three alternatives were considered before Supertonic and rejected:

- **piper-plus** — MIT-licensed, espeak-free phonemization. The
  espeak-free property is real, but it ships no public English voice at
  this pass; adopting it would mean either training/sourcing a voice
  from scratch or shipping no voice at all. Rejected: solves the
  license problem and creates a voice problem.
- **PocketTTS** — MIT engine, CC-BY weights, English-only. The
  licensing is clean, but it requires a hand-rolled FFI binding (no
  existing Flutter/Dart integration) and English-only means the
  five-language ceiling sherpa's VITS path never offered either.
  Rejected on integration cost relative to Supertonic's ready-made
  Flutter path, not on licensing.
- **A custom de-espeaked sherpa build** — patch espeak-ng out of a
  self-built sherpa-onnx. Technically possible (sherpa's TTS path is
  open source), but it loses every existing Piper voice (they are
  espeak-phonemized) and commits the project to maintaining a private
  fork of a native build across every target ABI. Rejected: trades a
  license problem for a build-maintenance problem that never goes away.

**Why Supertonic won:** it needs no phonemizer BY ARCHITECTURE — the
model consumes raw character indices (`unicode_indexer.json`), so
there is nothing for a GPL dependency to hide in, not merely nothing
found this time. The engine license (MIT, Supertone Inc.) and the
integration path (`flutter_onnxruntime`, MIT, an official in-repo
Flutter example to port) are both already clean. Speed is proven on
Android arm64 by an existing F-Droid app built on the same stack (RTF
≈0.3 on an e-reader-class SoC — comfortably real-time for
sentence-at-a-time synthesis on a mid-range phone), and Supertone Inc.
is an active company shipping dated releases (Supertonic 3 landed
2026-04-29, mid-campaign — noted below). No other candidate cleared all
four bars (no phonemizer, ready Flutter path, proven arm64 speed, an
actively maintained upstream) at once.

## Decision

### The artifact set (Phase 0)

Three options were ranked going in: (1) official quantized weights from
Supertone's own Hugging Face repos, if published; (2) the community
int8 repack at `csukuangfj2/sherpa-onnx-supertonic-tts-int8-2026-03-06`,
if it loads under plain ONNX Runtime with the official Flutter example's
own wiring; (3) the official fp32 weights, size stated plainly.

**Option 1 does not exist.** Supertone's own Hugging Face org
(`Supertone/supertonic`, `-2`, `-3`) ships fp32 ONNX only — verified by
listing every file in all three repos; no quantized variant appears
anywhere in that org.

**Option 2 was verified, not assumed, and rejected — on TWO independent
grounds, either one sufficient alone:**

1. **The repack carries no license at all.** Its Hugging Face repo
   metadata reports `license: None`. A license-hygiene campaign cannot
   adopt unlicensed weights, full stop — this alone disqualifies it
   regardless of anything else about the files.
2. **Its support files are not the ones this engine's ported inference
   code reads.** Comparing file listings directly: the repack's
   `unicode_indexer.bin` is a 262,144-byte BINARY file, where the
   official Flutter example's `UnicodeProcessor.load()` expects a JSON
   array (`unicode_indexer.json`, 262,196 bytes in the official repo) it
   `jsonDecode`s directly. Its `voice.bin` (517,168 bytes) is likewise a
   packed binary, where `loadVoiceStyle()` expects a per-voice JSON file
   with `style_ttl`/`style_dp` keys (`M1.json`, 420,510 bytes officially).
   Both `.bin` formats are shaped for sherpa-onnx's own C++ loader, not
   for the Dart/ONNX-Runtime wiring this campaign ported. Using them
   would mean reverse-engineering two undocumented binary formats
   against no specification — exactly the kind of "probably fine"
   assumption Phase 0 was explicit about not making.

**Worth recording regardless of the rejection:** the repack's
`duration_predictor.int8.onnx` and `text_encoder.int8.onnx` are
BYTE-IDENTICAL (same sha256) to the official fp32 originals — despite
the `.int8` filename, they were never actually quantized. Only
`vector_estimator.int8.onnx` (40.7MB vs. 132.5MB fp32) and
`vocoder.int8.onnx` (26.0MB vs. 101.4MB fp32) are genuinely smaller. A
hybrid — the two genuinely-quantized graphs from the repack, paired with
the official JSON support files from Supertone's own repo — was
considered. It is possible in principle (the two ONNX graphs are
themselves plain ONNX Runtime models with the same tensor contract) but
was set aside for this pass: it would mean shipping weights with no
license at all, the same disqualifier as the whole-repack option, and
mixing files from two upstream sources when a clean, fully-licensed,
fully-compatible fp32 option already exists. Recorded as a real
size-reduction path (263MB → an estimated ~190MB) if a future pass finds
or negotiates a licensed quantized release.

**Option 3 — the official fp32 weights — is what ships.** One
correction to this ADR's own research verdict, found by verifying
rather than trusting the stated URL: the "v2, 66M params, en/ko/es/
pt/fr" weights actually live at `Supertone/supertonic-2`, not
`Supertone/supertonic` (that second repo is v1, English-only, and
happens to be the same ~263MB size class — an easy repo to confuse with
its sibling by URL alone). Every file below was downloaded directly and
hashed locally, not copied from a listing:

| File | Bytes | sha256 |
|---|---|---|
| `onnx/duration_predictor.onnx` | 1,521,526 | `6d556b3691165c364be91dc0bd894656b5949f5acd2750d8ec2f954010845011` |
| `onnx/text_encoder.onnx` | 27,431,318 | `dd5f535ed629f7df86071043e15f541ce1b2ab7f1bdbce4c7892b307bca79fa3` |
| `onnx/vector_estimator.onnx` | 132,471,364 | `105e9d66fd8756876b210a6b4aa03fc393b1eaca3a8dadcc8d9a3bc785c86a35` |
| `onnx/vocoder.onnx` | 101,405,066 | `19bd51f47a186069c752403518a40f7ea4c647455056d2511f7249691ecddf7c` |
| `onnx/unicode_indexer.json` | 262,196 | `b7662a73a0703f43b97c0f2e089f8e8325e26f5d841aca393b5a54c509c92df1` |
| `onnx/tts.json` | 8,699 | `ee531d9af9b80438a2ed703e22155ee6c83b12595ab22fd3bb6de94c7502fe96` |
| `voice_styles/M1.json` | 420,510 | `a04c823cbda6dd1c7de131ec68fea83bbb70d7f29d61623304eb871e3b83b5a1` |

Total: 263,520,679 bytes (~263.5MB / ~251.3MiB) across seven files —
matches this ADR's own size estimate from before verification, which is
itself worth recording: the estimate held, the URL didn't.

**Voice: M1.** The official Flutter example's own default
(`loadVoiceStyle(['assets/voice_styles/M1.json'])` in its `main.dart`) —
chosen on the same reasoning ADR-0006 used for sid 0 on the Piper voice:
a real, stable, upstream-endorsed default, not an invented preference.

### The registry surface: a named layout, not positional indices (Phase 2)

Two shapes were weighed for expressing "one voice = seven independently
verified files, no archive": a documented positional convention over
`ModelSpec.files` (mirroring the official Flutter example's own
`['duration_predictor', 'text_encoder', 'vector_estimator', 'vocoder']`
ordered list), or a named layout type mirroring `VoiceArchiveLayout`'s
own shape. The named type won, for a discriminating reason a positional
convention loses: `DeviceServices.speechEngineFor` needs a typed refusal
for "this spec isn't shaped like a voice this engine can read" — exactly
the property the existing `archiveLayout == null → refuse` check gave
the sherpa rung, and exactly what a bare `files.length != 7` magic-number
check would NOT give as legibly. `SupertonicVoiceLayout`
(`packages/ml_runtime/lib/src/registry.dart`) restores that shape:
seven named fields (`durationPredictorFileName` through
`voiceStyleFileName`), `ModelSpec.supertonicLayout` an optional field
alongside the existing `archiveLayout` — a spec picks at most one shape,
same as `archiveLayout` was never mutually enforced against anything
else either. A second, quieter reason: reordering a positional list is
the kind of edit that looks harmless in a diff and silently swaps which
file is the voice embedding and which is the config — a named field
can't be reordered into the wrong meaning.

`ModelStore` and `DiskModelStore` needed NO changes. The existing
per-file download → sha256-verify → atomic-rename loop
(`DiskModelStore.download`) already handles any number of independent
files landing under `<baseDir>/<id>/<filename>` — whisper's own single
file is just the degenerate N=1 case of the exact same law. Resolving
which file backs which named role is one small lookup
(`DeviceServices._pathForNamedFile`, matching a layout filename against
each registered `ModelFile`'s URL) added to `speechEngineFor`, not a new
promotion mechanism.

**`VoiceArchiveLayout`, `DiskModelStore`'s archive-extraction path
(`_extract`/`voiceDirOf`), and `model_store_archive_test.dart` are left
in place, deliberately, with no consumer after this campaign.** They are
generic, still-correct machinery — a future voice that genuinely ships
as one archive (the way every Piper release did) can still use them
unchanged. Removing ~200 lines of passing tests and a working code path
in the same change that swaps a registry entry would make this
campaign's own diff harder to trust as "the swap is safe," for a cleanup
that buys nothing the swap itself needs. Recorded here as a **real,
recommended follow-up**, not a decision made now: an
architect reviewing this campaign should judge whether dead-with-no-
consumer is corpse enough to remove on its own, independently
reviewable terms.

### minTier moves from t1 to t2

Piper's voice was 23.4MB, registered at `t1` ("cheap phone + one 40MB
download"). Supertonic's is ~263MB — a T1 device downloading whisper-
tiny (41MB) AND this voice would already be past the T1 budget's own
stated ceiling on the tiny model alone. VISION's own freedom-of-compute
ladder already named the correct tier before this campaign touched
it: "T2 | good phone / any desktop | Whisper-base/small, Piper/Kokoro
TTS, local LLM." `supertonic-en-m1` registers at `DeviceTier.t2`,
which is also now the tier VISION's own table describes truthfully —
Piper's `t1` registration was, in retrospect, inconsistent with that
same table the whole time.

### Language honesty: `{'en'}`, not the five the model covers

Supertonic v2's weights cover five languages (en/ko/es/pt/fr) — the
architecture and the `unicode_indexer`/preprocessing pipeline handle all
five. This campaign ships ONE voice embedding, M1, reviewed only for
English. `supertonic-en-m1`'s registry entry claims `langs: {'en'}`,
not the model's full coverage — claiming five languages against a
voice nobody has heard speak four of them would be the same kind of
overclaim the language-honesty law exists to prevent. `resolveSpeechEngine`'s
existing `pickModel(langHint:)` gate means a work in Portuguese, say,
still falls back to the system voice rather than getting English-
accented Portuguese from M1. Widening this set later is a **drop-in
registry change** — a new `ModelFile` entry for another voice style
(or the same M1 embedding, if it turns out to generalize — untested,
not assumed) and a widened `langs` set — because the ENGINE code
(`SupertonicSpeechEngine`, `_preprocessText`) already validates and
tags all five of the model's actual languages internally
(`_v2ModelLangs` in `src/supertonic_speech_engine.dart`); only the
public-facing `supertonicSupportedLangs` gate (currently `{'en'}`) is
what's conservative. Nothing about widening it touches engine code.

### The engine (Phase 1): what's ported, what's deliberately not

The inference loop — session wiring for the four ONNX graphs, character
indexing via the unicode indexer, NFKD text preprocessing (Hangul
decomposition, Latin accent decomposition, punctuation/emoji cleanup),
the flow-matching denoising loop, the vocoder call — is adapted from
Supertone Inc.'s own official Flutter example
(`github.com/supertone-inc/supertonic`, `flutter/lib/helper.dart`, MIT),
with its copyright notice retained in the ported file's own doc comment.
Four deliberate deviations, each recorded in the code and repeated here
because a future reader familiar with the upstream example would
otherwise read them as bugs:

- **`_infer` was ported, not `call()`.** Upstream's `call()` re-chunks
  text at 300 characters and splices 0.3s of silence between chunks —
  logic for turning a whole document into TTS-sized pieces. This app
  already hands the engine exactly one SENTENCE per call
  (`splitSentences`, ADR-0006) — porting `call()` wholesale would
  re-chunk an already-chunked unit and could insert dead air inside what
  `SpeechPlaybackPipeline` believes is one gapless clip. `_infer` (the
  single-chunk inference core `call()` itself calls in a loop) is the
  right unit to port.
- **Batch size fixed at 1.** One sentence per `generate()` call means
  every tensor upstream builds with a batch dimension collapses to a
  single row here — simpler code, same math.
- **`lang` validated against the FIVE v2 languages, not upstream's
  31.** The official example is written for Supertonic 3 (31 languages,
  a different, newer model release — noted below); porting its
  `availableLangs` list verbatim against v2 weights would silently
  accept a language the shipped weights were never trained on. The
  ported `_preprocessText` validates against `_v2ModelLangs` (the five
  v2 actually covers) and throws the typed `SupertonicUnsupportedLangException`
  where upstream throws a raw `ArgumentError` — ADR-0003's "errors are
  sentences" law, applied to a boundary upstream never had to think
  about this way.
- **Sessions load from a file path directly** (`OnnxRuntime().createSession(path)`)
  rather than upstream's asset-extraction dance
  (`copyModelToFile` + `createSessionFromAsset`) — upstream needs that
  dance because its files are bundled Flutter assets; this campaign's
  files are already plain files under the model store once downloaded,
  so the simpler call is also the correct one.

Two more deviations exist for correctness rather than fidelity, both
because ONNX Runtime inference crosses a platform channel — genuinely
asynchronous, unlike sherpa's synchronous FFI call:

- **The lazily-opened handle is cached as a `Future`, not a resolved
  value.** `_handleFuture ??= _open()` assigns synchronously, so two
  `synthesize()` calls racing before the handle resolves still only open
  it once. Caching the resolved value (`_handle ??= await _open()`, the
  literal shape sherpa's synchronous engine used) would race: two
  concurrent callers could both observe `null` before either writes.
- **`generate()` calls are serialized per engine**, through a chained
  `Future` queue. `SpeechPlaybackPipeline`'s synthesis lookahead (2, by
  default) means up to three `synthesize()` calls can be in flight at
  once; concurrent `session.run()` calls against the SAME four ONNX
  sessions are unproven safe, so this campaign does not gamble on it —
  every `generate()` call waits for the previous one to fully settle
  (success or failure) before starting.

Every intermediate `OrtValue` this file creates is disposed once
consumed, and `dispose()` closes all four sessions plus the two
resident style tensors — upstream's own example never disposes
anything, which is fine for a one-shot desktop demo and would be a
native-memory leak here across hundreds of sentences × eight denoising
steps per sentence on a phone.

**A minor, mechanical fix the port surfaced:** the ported text-
normalization table uses U+2011 (non-breaking hyphen), U+2192, and
U+2190 (arrows) as `replaceAll()` pattern data — characters stripped
from input before synthesis, never characters the UI draws. The fleet's
own C7-fonts conformance check (`oh_fleet_conformance`) flagged them
correctly on its own terms (it cannot know a string is pattern data
just by reading it) and was satisfied with its own documented
`// not-rendered` exemption — the same exemption the check's own doc
comment names as existing for exactly this shape of false positive.

### One update mid-research, recorded not chased

Supertone released **Supertonic 3** on 2026-04-29 — 31-language support,
"v2-compatible public ONNX assets" per its own release note (same four-
graph architecture, same tensor contract; the ported inference code in
this campaign would run v3 weights unchanged). This ADR's own research
verdict (v2, five languages) predates that release and was followed as
written rather than re-researched mid-campaign, per this campaign's own
scope discipline. Recorded as a real, low-risk future option: a v3
upgrade is a registry re-pin (new weight files, new hashes, a wider
`langs` set if the maintainer reviews more voices), not an engine
change — the architecture compatibility is the whole reason it's cheap.

## Weights licensing — OpenRAIL-M, quoted verbatim in tts-voices.md

The weights (all seven files above) are BigScience Open RAIL-M,
dated August 18, 2022 — full text fetched from
`Supertone/supertonic-2/LICENSE` and reproduced verbatim, with fetch
date, in `docs/reference/tts-voices.md`. Two clauses matter most for
what this app is actually doing:

- **§4.a** — use-based restrictions (Attachment A: no unlawful use, no
  exploiting minors, no disinformation, no undisclosed synthetic content
  passed off as human-made, no impersonation without consent, among
  others) MUST be passed through as an enforceable condition to anyone
  the model or its output is distributed to. Trellis distributes neither
  the model NOR is in the business of redistributing its output to third
  parties on the user's behalf — the restrictions bind the person who
  downloads and uses the voice, the same way they would if that person
  had downloaded the weights directly from Hugging Face.
- **§4.b** — anyone receiving the model must get a copy of the license.
  **Trellis never distributes the weights itself** — the download the
  models screen offers pulls directly from Hugging Face, where the
  `LICENSE` file sits alongside every weight file in the same repo. The
  user's copy of the license comes from Supertone (the licensor)
  directly, not through this app as an intermediary. This is a
  structurally favorable fact, not a coincidence this ADR is claiming
  credit for: the same "download from the source, verify locally,
  never re-host" law the whisper/LLM registry entries already follow
  (ADR pending on the general shape, but every `ModelFile.url` in the
  starter catalog already points at the upstream repo, never a mirror)
  happens to also be the cleanest possible posture under an OpenRAIL-M
  §4.b obligation.

**The accounting, stated plainly:** the shipped APK — every line of
Dart, the `flutter_onnxruntime` plugin, the Supertonic engine code
itself — is MIT end to end. The downloaded voice weights are OpenRAIL-M,
with real use restrictions, arriving only on the user's own explicit
tap (the models screen's existing consent chokepoint, unchanged) —
exactly the same shape whisper's model downloads already have, just a
different license name. `ModelSpec.licenses` for `supertonic-en-m1`
carries exactly one entry now — `['OpenRAIL-M']` — down from Piper's
two (`['CC-BY-4.0', 'GPL-3.0']`). That drop from two license names to
one, visible on the models screen's own existing size-and-license line,
IS the campaign's visible proof: there is no longer a second, engine-
side obligation riding along with the voice.

## Future web tier — recorded, not built

Character-level input (no phonemizer) means a web neural TTS rung via
`onnxruntime-web` would need no espeak WASM build — the specific
integration blocker that made ADR-0006 defer a web neural tier in the
first place doesn't apply to Supertonic the way it would have to a
web port of the old sherpa rung. This is worth recording precisely
because it changes the shape of a future decision (kokoro-js vs.
onnxruntime-web + Supertonic, both now genuinely comparable web
options) without committing to either here. Not built this pass.

## Consequences

- The APK is MIT-clean end to end, the moment sherpa's removal
  (already shipped, this same campaign) is built into a release —
  the maintainer's release decision ADR-0006 left open now has a clean
  answer available, not just a documented tradeoff.
- **Proven through the interface, not on real hardware** — the same
  honesty ADR-0006 recorded for sherpa, now for Supertonic.
  `supertonic_speech_engine_test.dart` and
  `device_services_speech_test.dart` drive the full engine contract —
  lazy session opening, residency, generation serialization, typed
  failures (missing files, native init failure, unsupported language) —
  through a faked `SupertonicVoiceHandle`, never a real ONNX Runtime
  session or a real `flutter_onnxruntime` platform channel. What
  remains genuinely unexecuted: the four real ONNX sessions actually
  loading, the ported denoising loop actually producing audible,
  correctly-timed PCM, and `flutter_onnxruntime`'s Android native layer
  actually running on an arm64 device. All three are one Android build
  and a phone away, not further Dart code — the same honest gap
  ADR-0006 left for sherpa, inherited rather than closed.
- `VoiceArchiveLayout` and the archive-extraction path in
  `DiskModelStore` now have zero consumers in the starter catalog. Live,
  tested, and correct — but a real candidate for a future, independently
  reviewed removal pass (see "The registry surface," above).
- Sizing: the APK gains `flutter_onnxruntime`'s native payload (per-ABI,
  filtered to arm64 by the existing Gradle policy) instead of sherpa's;
  the downloaded voice grows from Piper's 23.4MB to ~263.5MB — a real,
  user-facing size change the models screen already states plainly
  before any tap, unchanged mechanism, bigger honest number.
- A v3 upgrade (31 languages, "v2-compatible" ONNX assets per
  Supertone's own release note) is a recorded, low-risk future re-pin —
  not evaluated further this pass, per this campaign's own scope
  discipline.
