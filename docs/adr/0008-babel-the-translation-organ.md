# ADR-0008: Babel — the translation organ

- Status: Accepted. The engine, the registry entry, the per-work
  sentence-indexed store, the cancellable/resumable batch action, the
  scroll-mode dual display, and speak-in-Spanish are ALL shipped —
  Phases 3 and 4 (deferred when this ADR was first accepted) landed in a
  follow-up pass, recorded below. Still not exercised on real hardware:
  the ONNX Runtime sessions actually opening on a device, and — a
  separate, more pointed gap — nobody has HEARD the Spanish speech this
  pass makes possible (see the Phase 4 section's honesty accounting).
- Date: 2026-08-15 (Phases 1-2); amended 2026-08-15 (Phases 3-4)

## Context

The founding dream for this app, in the owner's own words: "I would pay
for a podcast player that automatically translates episodes into other
languages so I could practice Spanish while listening to my favorite
shows." Every other organ this needs already exists — whisper transcribes
with sentence timing, `Layers` persists per-language text keyed to a
segment, Supertonic speaks Spanish (its v2 weights cover it; only the
app-level language gate was narrowed to English). The one missing organ
was a REAL on-device machine-translation engine. This ADR records what
was built, the trap it had to route around, and what is honestly still
open.

### The model

`opus-mt-en-es`, int8-quantized ONNX, from
`huggingface.co/onnx-community/opus-mt-en-es` (Xenova/onnx-community's
conversion of `Helsinki-NLP/opus-mt-en-es` — a Marian transformer,
OPUS/Tatoeba-Challenge trained). Verified by downloading and hashing the
actual files (2026-08-14/15), not assumed from a listing:

| File | Bytes | Role |
|---|---|---|
| `onnx/encoder_model_quantized.onnx` | 52,875,078 | encoder, run once |
| `onnx/decoder_model_merged_quantized.onnx` | 193,290,224 | decoder, run per token |
| `source.spm` | 801,636 | SentencePiece unigram piece table |
| `vocab.json` | 1,720,044 | joint piece->id vocabulary (`separate_vocabs: false`) |

Total ~246 MB — the spec that opened this campaign guessed ~113MB from
memory; the real number, verified by downloading both ONNX files
directly, is roughly double. `target.spm` (825,924 bytes, also present
in the repo) is deliberately NOT registered: it only tokenizes text for
the OTHER direction (es->en decode input), and this engine's decode path
reverses the joint `vocab.json` instead of running a second SentencePiece
model.

**License, recorded precisely because the spec's assumption was
backwards:** the spec expected "Apache-2.0 (HF card) / weights CC-BY-4.0
upstream." What was actually found, reading both cards directly
(2026-08-15): the ONNX conversion repo that hosts the exact files this
engine downloads (`onnx-community/opus-mt-en-es`) carries `license:
cc-by-4.0` in its own card. The UPSTREAM original
(`Helsinki-NLP/opus-mt-en-es`) carries `license: apache-2.0` in ITS card.
The registry entry's `licenses` field names `CC-BY-4.0` — the license
attached to the actual bytes being downloaded and run — with both
strings recorded verbatim, with fetch date, in
`docs/reference/mt-models.md`, following `tts-voices.md`'s precedent for
exactly this kind of weights-vs-upstream license split.

### The tokenizer decision

Marian's tokenizer is SentencePiece unigram (`source.spm`, model_type=1,
verified by reading the model's own protobuf trainer_spec, not assumed).
Rather than depend on a full protobuf library, this campaign implements
a pure-Dart reader for exactly the fields the piece table needs
(`ModelProto.pieces[].{piece,score,type}`) and a from-scratch Viterbi
unigram encoder over that table — `packages/ml_runtime/lib/src/
marian_tokenizer.dart`.

Twenty-five golden vectors (punctuation, numbers, unicode, empty,
whitespace-only, a long sentence, one deliberately NFKC-unstable input)
were generated with the real `sentencepiece` Python library against the
actual downloaded `source.spm`, and committed as JSON fixtures
(`packages/ml_runtime/test/fixtures/marian_tokenizer_goldens.json`) — the
model files themselves are never committed (they are runtime-downloaded
assets, same law as the ONNX weights); only the golden pieces/ids are.
24 of 25 match the Dart encoder exactly. The 25th is a deliberate,
permanent scope limit:

**Not implemented: the `.spm` model's real normalizer.** `source.spm`'s
`normalizer_spec.name` is `nmt_nfkc` — NFKC-based Unicode normalization
plus NMT-specific rules, compiled into a 237,538-byte precompiled
charsmap inside the model file. Porting that table is out of scope for
this campaign. What IS implemented and verified byte-for-byte against
the real model's own `.normalize()` method for all 24 non-adversarial
golden sentences: whitespace-run collapse, trim, a dummy leading space,
and escaping every space to `▁` (U+2581) — the parts of normalization
that are cheap, deterministic, and cover the overwhelming majority of
real English/Spanish text (which is almost always already in NFKC-stable
precomposed form). The one documented gap: a decomposed combining
character (e.g. `e` + U+0301 rather than the precomposed `é`) tokenizes
differently in the Dart encoder than in the real model. The golden
fixture pins this as an EXPECTED divergence — the test asserts the
mismatch explicitly, with a comment naming why, so a future fix or a
regression both fail loudly instead of silently drifting from this
paragraph. Discovery worth recording for whoever picks this up: the app's
own `pubspec.yaml` already pulls in `unorm_dart` (transitively, for some
other feature) — a real NFKC implementation is one dependency add away
in `ml_runtime` if this gap is ever worth closing.

### ⚠️ THE trap — verified directly against the real graphs

The spec pointed at onnxruntime issue #17677: naive single-shot or
wrongly-threaded Marian decode produces garbage, not an error. Before
writing any Dart, the exact generation loop was proven end to end in
Python against the real downloaded ONNX graphs (kept in `/tmp`, never
committed) — and it took three real, load-bearing discoveries to get
there, not one:

1. **The merged decoder graph's `use_cache_branch` polarity is the
   intuitive one** (`false` = no cache yet, compute fresh; `true` = cache
   exists, reuse it) — but getting there required first hitting a hard
   ONNX Runtime crash (`Reshape` on a zero-sized dimension) by guessing
   wrong, then inspecting the graph's own `If`-node subgraphs directly
   (`onnx.load` + walking `then_branch`/`else_branch`) rather than
   continuing to guess.
2. **Step 1 needs TRUE zero-length dummies for ALL 24
   `past_key_values.*` inputs** — both the decoder self-attention slots
   AND the encoder cross-attention slots — not a "reasonable-looking"
   non-zero placeholder shape. A non-zero placeholder for the
   cross-attention slots avoids the crash but silently corrupts the
   result (observed: the graph's own reshape math scrambles into a
   nonsensical `(0, 8, 1, 64)` output) — worse than a crash, because
   nothing signals the failure.
3. **The cached branch's OWN `present.*.encoder.*` output is
   degenerate**, every single time `use_cache_branch=true` — observed
   shape `(0, 8, 1, 64)` (batch 0, effectively empty), regardless of what
   was fed in. The standard "thread every `present.*` forward as next
   step's `past_key_values.*`" pattern (correct for the decoder
   self-attention slots, which genuinely grow one token per step) is
   WRONG for the cross-attention slots specifically. The fix: freeze
   step 1's real, correctly-computed `present.*.encoder.*` and re-feed
   those exact tensors on every later step, never the current step's own
   output for that slot. Steps 1-2 of a translation look plausible even
   with the naive (wrong) approach — short-range bigram priors carry a
   couple of tokens — which is exactly how this trap hides until a
   longer sentence or a careful side-by-side check exposes it.

Verified output from the Python proof, greedy decode, before any Dart
was written:

```
"Hello, world!" -> "¡Hola, mundo!"
"The quick brown fox jumps over the lazy dog." ->
  "El zorro marrón salta sobre el perro perezoso."
"I would pay for a podcast player that automatically translates
episodes into other languages." ->
  "Pagaría por un reproductor de podcast que traduce automáticamente
  episodios a otros idiomas."
"Good morning. How are you today?" -> "Buenos días. ¿Cómo estás hoy?"
```

The Dart transcription
(`app/lib/features/reader/translation/marian_generation_loop.dart`)
encodes discovery 3 as a permanent regression test, not a comment
someone could delete: `marian_generation_loop_test.dart`'s "THE TRAP,
pinned" case feeds a fake decoder session that returns the same
degenerate marker the real graph does on every cached step, and asserts
the translator still feeds step 1's frozen values three steps later. If
this test ever goes red, the fix described above has regressed.

## Decision

- **Engine shape mirrors `SupertonicSpeechEngine` exactly**: lazy
  residency (a cached `Future`, not a cached value — closes the same
  two-callers-race-before-open gap), serialized calls through a queue
  (concurrent `session.run` against the same sessions is unproven, and
  Phase 3's translate-ahead lookahead can have more than one call in
  flight), dispose waits for the in-flight call before releasing
  sessions. Same conditional-export trio (`marian_engine.dart` exports
  the real implementation by default, a web stub under
  `dart.library.js_interop` that refuses calmly in its constructor).
  Typed calm failures — `MarianModelMissingFilesException`,
  `MarianModelInitException` — replace bare platform exceptions.
- **The generation loop is tested at its own boundary, separate from the
  engine wrapper.** `MarianSessionRunner` is a thin (data + shape +
  dtype) interface the loop calls instead of `OrtSession.run` directly —
  narrow enough that `marian_generation_loop_test.dart` drives every
  mechanic (zero-length step-1 dummies, self-attention KV growth, the
  frozen-cross-attention-KV fix, EOS stop, the `3x input + 16` length
  cap) with a deterministic fake, never touching
  `package:flutter_onnxruntime`. The engine wrapper is then tested
  exactly the way `SupertonicSpeechEngine`'s own test is: faked one level
  up, at the `MarianModelHandle` boundary.
- **`MarianModelLayout`** (`packages/ml_runtime`) names which downloaded
  filename plays which role — the same "data, not code" surface
  `SupertonicVoiceLayout` established: a second language pair is a new
  `ModelSpec` + a new `MarianModelLayout`, not an engine change.
  `ModelTask.translation` already existed in the registry's task enum
  before this campaign — nothing to add there.
- **`langs` on the registry entry names the TARGET language** (`{'es'}`),
  not a source language — the reading that makes
  `pickModel(ModelTask.translation, tier, langHint: 'es')` answer the
  question a caller actually has ("give me something that can produce
  Spanish").

## Phase 3: the store, the batch action, the scroll display

Landed in the follow-up pass that closes this ADR's original Phase 3/4
gap.

- **Schema v13, `TranslationSentences`**: one row per (work, segment,
  sentence WITHIN that segment) — `(workId, segmentIdx, sentenceIdx,
  lang)` as the primary key, `sourceText` captured at write time
  alongside `body`. Finer-grained than the existing `Layers` table (whose
  key stops at `segmentIdx`): whisper's X->EN translate task produces one
  string per WHOLE segment, but Marian translates one sentence at a
  time, and Phase 4's speak substitution needs that granularity to pair
  a Spanish sentence with the English cursor it plays under.
  `Works.showTranslationLayer` is the per-work display toggle, off by
  default, mirroring the existing `pinned` bool. Numbered v13 rather than
  the v9 originally planned: two other campaigns (the study crown, ADR-
  0009; and a separate player-love campaign) claimed v9-v12 on `master`
  in the meantime — this hop's own migration guard (`if (from < 13)`)
  needs no `from >=` lower bound, unlike the RFC 5005 v8 hop, because
  neither `works` nor `translationSentences` is ever freshly created by
  an earlier block with this column/table already present.
- **The staleness law, made a function**: `sourceText` is compared
  against the CURRENT English sentence at every lookup
  (`translatedTextFor` in `sentence_units.dart`) — a re-ingest that
  reshapes a work's segments makes a stale row read as MISSING, falling
  back to English, rather than pairing a translation with a sentence it
  was never translated from. Both the scroll-mode display and Phase 4's
  speak substitution call this ONE function, so the law can't drift
  between the two readers.
- **`sentenceUnitsOf`**: the canonical (segIdx, sentenceIdx) numbering
  BOTH the writer (the batch job) and BOTH readers (display, speech) key
  off — always over a work's canonical segments, never a
  language-projected list (see the guard below). `segIdx` is each
  segment's own `Segment.idx`, never its position in whatever list it
  came from — a work whose segments don't start at 0 still stores
  correctly (a case the fixture suite exercises directly, not just
  implicitly).
- **`DeviceServices.translatorFor`/`resolveTranslator`**: the exact gate
  shape `speechEngineFor`/`resolveSpeechEngine` already established for
  the Supertonic voice — `localMlAvailable`, tier, `MarianModelLayout`
  presence, then `modelStore.isDownloaded` — applied to the Marian
  translator. Cheap either way: `MarianTranslator` opens its ONNX Runtime
  sessions lazily on first `translate()`.
- **`TranslationJobController`**: the cancellable, resumable
  Translate-to-Spanish batch. Deliberately NOT built on `jobs_core`'s
  `JobRunner`/`JobsTable` the way transcription is — that machinery
  exists because whisper's decode isn't naturally chunked into a
  persisted artifact until a whole window completes, so a separate
  checkpoint row is load-bearing. A translated sentence is durable the
  instant it's written; the `TranslationSentence` store IS the
  checkpoint. Re-running the same action after a cancel, a crash, or
  simply reopening the work skips every sentence already stored (via
  `translatedTextFor`'s own staleness check — a stale row is retried like
  any missing one), so resumption is free. A `translate()` failure on
  one sentence stores nothing for that index and the run continues — the
  fallback law below is what makes that safe to leave alone rather than
  retry immediately.
- **The reader's own guard**: the Translate action, Show Spanish, and (Phase
  4) Speak in Spanish are offered ONLY while `_activeLang == null` — the
  existing whole-segment mt-layer swap (ADR-0002) projects `_blocks`
  through a different text entirely, whose own `core.splitSentences`
  boundaries would disagree with the store's numbering if Babel's
  sentence indices were computed over THAT projection instead of the
  canonical `_original`.
- **Scroll-mode dual display**: restructures the per-block word `Wrap`
  into one row per ENGLISH sentence — the SAME word-range slice, just
  narrower — immediately followed by its Spanish line (italic, dimmed,
  the same subordinate-text idiom the existing figure caption already
  uses) wherever `translatedTextFor` finds one. The untranslated path
  (Show Spanish off, or nothing translated in a given block) renders
  through the exact prior `_proseWrap` body, unchanged, so
  `reader_print_test.dart`'s pinned layout keeps passing byte-for-byte.
  Headings, which render as one opaque `Text` with no per-word row to
  interleave into, get their translation(s) below the title instead.

## Phase 4: Babel speaks

### The es-voice verdict

The brief's instruction was conditional: widen `supertonicSupportedLangs`
and register a Spanish voice's files — UNLESS upstream ships no separate
Spanish speaker, in which case say so honestly and gate on the voice
actually present, never inventing a model URL. Checked directly against
`Supertone/supertonic-2`'s own file listing and the official example's
usage pattern (not assumed):

- `voice_styles/` holds `F1`-`F5`, `M1`-`M5` — ten SPEAKER TIMBRES, no
  language suffix anywhere in the naming.
- The official Python usage passes `lang` and `voice_style` as two
  INDEPENDENT parameters to the same call — language is not baked into
  which voice-style file you load.

There is no separate "Spanish voice" to download. `supertonic-en-m1`'s
four shared graphs, `unicode_indexer.json`, and `M1.json` are already the
files a Spanish utterance would run through — the ONLY change is
`supertonicSupportedLangs`, widened from `{'en'}` to `{'en', 'es'}` in
`supertonic_voice_handle.dart`. No new `ModelSpec`, no new registry
entry, no invented URL — there was nothing upstream to point one at.

This is the exact escape hatch ADR-0007 named without taking it: "a new
`ModelFile` entry for another voice style (or the same M1 embedding, if
it turns out to generalize — untested, not assumed)." That ADR declined
to widen the gate because nobody had verified Spanish output from a
voice reviewed only for English. This pass widens it anyway, on the
strength of the architectural finding above (the engine already
validates and tags all five of the v2 model's actual languages
internally, per ADR-0007's own accounting) — but the "untested, not
assumed" fact itself hasn't changed. **Nobody has heard this voice speak
Spanish on real hardware.** The honesty obligation ADR-0007 discharged by
refusing to ship is discharged here by shipping AND saying so, in this
paragraph, in the CHANGELOG, and in the campaign report — not by leaving
the feature unbuilt a second time.

Deliberately NOT widened: the registry's `supertonic-en-m1` entry still
claims `langs: {'en'}`. That set governs `pickModel`'s selection law —
"which voice should a WORK in this language be read by" — a different
question from "can the already-resolved voice also speak one stored
Spanish sentence under an English work," which is all Phase 4 needed.
Widening the registry claim would be a second, larger honesty claim (this
voice as the PRIMARY reader for a Spanish-source work) that nothing in
this pass verifies.

### The speak loop

`_activeLang`/`_showSpanish`'s guard from Phase 3 carries over unchanged.
A new session-only toggle, Speak in Spanish — never persisted, unlike
`showTranslationLayer`; there is no "was this on last time" question for
a runtime speech choice — is offered only once Show Spanish is already
on, and resets to off whenever Show Spanish is turned off (so a hidden
menu item can never keep silently substituting Spanish into a run the
user has no way to see or undo).

Both speak paths substitute per SENTENCE, keyed exactly the way the store
and the scroll display already are:

- The system voice's loop (`_speakWithUtterance`) looks the translation
  up right before each `engine.speak` call and tags the utterance `'es'`
  only when one was actually found — this path already threads `lang`
  per call, so no engine change was needed.
- The neural voice's path builds its flat unit list
  (`_remainingSpeechUnits`) with the substituted text AND a per-unit lang
  tag, then hands both to `SpeechPlaybackPipeline.start`'s new
  `langOverrides` parameter — a small, backward-compatible addition
  (existing callers that never pass it are unaffected). This was
  necessary because the pipeline's synthesis-ahead batch previously took
  ONE `lang` for the whole run; a batch that mixes stored Spanish with
  English fallback sentences needs each one tagged in the language it's
  ACTUALLY written in, or a fallback sentence would be spoken in English
  text under a Spanish language tag.

Either way, `seg`/`wordIdx` in every unit still point at the ORIGINAL
sentence's position — the karaoke cursor never moves to reflect which
language is actually playing, and a sentence with no stored translation
(or a stale one) speaks English from the original: no gap, no crash, per
the fallback law Phase 3 already established for the batch job.

## What's deferred

- **Other language pairs** are registry data (a new `ModelSpec` +
  `MarianModelLayout`), not an engine change — the generation loop and
  tokenizer are already pair-agnostic. Widening Supertonic further
  (ko/pt/fr) is the same `supertonicSupportedLangs` move Phase 4 made for
  Spanish — still unverified by ear, not done here.
- **The long-tail of languages this pair doesn't cover** stays
  Brain-backed where a Brain translation path exists, or unavailable
  where it doesn't.
- **Word-level alignment** between source and target tokens is out of
  scope — the engine returns a translated sentence, not a token mapping.
- **RSVP-mode dual display** was never in scope — Phase 3's brief named
  scroll mode only; RSVP shows one word at a time and has no natural
  place to pair a translation without breaking its own shape.
- **Real-hardware verification** — of the ONNX Runtime sessions opening
  at all, and separately, of what Spanish actually sounds like through
  the M1 embedding — remains open. This is the one gap this amendment
  cannot close by writing more code; it needs a phone and a pair of ears.

## Consequences

- The organ exists, is wired end to end (store, batch action, scroll
  display, speech), and is proven against faked session/engine
  boundaries plus, for the MT engine specifically, against the real
  downloaded model in Python (genuinely fluent Spanish out). Still
  unproven on real hardware: ONNX Runtime actually opening sessions on a
  device, and whether the M1 voice's Spanish is intelligible to a human
  ear — two different, both open, both named rather than assumed away.
- A future reader adding a second language pair has a template: one
  `ModelSpec`, one `MarianModelLayout`, no engine code. A future reader
  widening Supertonic to another of its five covered languages has an
  even smaller template: one set literal, once someone has actually
  listened.
- The feature-matrix's Translation entry is corrected in this pass to
  reflect Phases 3-4 shipping — see the campaign report and CHANGELOG for
  the precise wording; the wrong "translation runs through a Brain LLM
  call" claim this ADR's first acceptance caught stays corrected.
