# ADR-0014: Babel widens — the hub-and-spoke law

- Status: Accepted, Phases 0-5. Phase 5's `BrainTranslator` and
  `TranslationJobController.translateBatch` are real, tested code but
  NOT wired into the live app — no call site outside their own tests
  constructs a `BrainTranslator` today; see Phase 5's own section for
  exactly what was and wasn't built, and why. Phase 6 is this document
  plus the CHANGELOG and feature-matrix rows it points at.
- Date: 2026-08-15

## Context

ADR-0008 "Babel" shipped one language pair — `opus-mt-en-es` — hardcoded
throughout the reader: a fixed "Translate to Spanish" menu item, a
`_showSpanish`/`_speakSpanish` pair of booleans, a `TranslationSentences`
store keyed only by `lang` (always `'es'` in practice), Supertonic's own
language gate widened to exactly `{'en', 'es'}`. Real device testing of
that release surfaced the literal shape of the problem: the app offered
to translate an English work into English, because nothing in the
picker's design considered that the SOURCE language might ever not be
English, or might ever equal the target.

This campaign generalizes the organ from "the Spanish organ" to "the
translation organ" — Spanish becomes a parameter, not a fact baked into
sixteen call sites. The guiding law, cheap to state and easy to verify
against: **for N target languages off one hub (English), the app needs
2N models (N forward, N reverse), never N² — nobody translates Russian
to German directly.** Every registry entry, every test, and this ADR
itself are organized around that hub-and-spoke shape.

## Decision: `sourceLang` becomes a first-class parameter

`ModelSpec` gained a `sourceLang` field (nullable, translation-task
only). `ModelRegistry.pickTranslationPair(tier, {sourceLang, targetLang})`
matches BOTH ends of a pair — `pickModel`'s single `langHint` genuinely
cannot express "de-en and ru-en and zh-en all produce `langs: {'en'}`;
tell them apart by where they came FROM," so a new method exists rather
than overloading the old one's contract.
`ModelRegistry.translationPairsAt(tier)` lists every runnable pair, the
data `DeviceServices.availableTranslationTargets({required sourceLang})`
filters (by downloaded state, excluding `sourceLang` itself) to become
the reader's own picker options.

Each `Work` carries an `activeTranslationLang` (nullable `String`,
schema v19) — the "one active translation layer per work at a time" law
made literal: picking a new target REPLACES it, never adds to a set. A
work's own declared source language lives on `Works.lang`, settable
through a calm per-work picker (`_openWorkLanguagePicker`) alongside the
existing "Translate…" action. **Declared, not detected** — this campaign
ships no language-ID model; a user who mislabels a work's language gets
wrong translate options, not a crash, and can always correct it through
the same picker.

**Addendum, from the device-test report (folded into Phase 1, not a
separate phase):** the work's own declared source language is never
listed as a target, and a stray X->X request is refused a second time,
defensively, in `_startTranslation` itself — "never trust a single
chokepoint" (`reader_translate_test.dart`'s own test for exactly this).

## Phase 0: verification before registration

Every pair below was checked before it was written into
`ModelRegistry.starter()` — real downloads, real hashes, and for the
pairs that shipped, real ONNX inference in Python (not assumed from a
model card). The full accounting, including the zero-download HF
tree-API hashing method (cross-validated three times against real
downloads) and every quality sample, lives in `docs/reference/
mt-models.md`; the summary:

| Pair | Verdict | Why |
|---|---|---|
| en-de / de-en | Shipped, excellent both directions | tc-big export exists for both; fluent on every test sentence |
| en-ru / ru-en | Shipped, excellent both directions | tc-big export exists for both |
| en-zh | **Evaluated, NOT shipped** (Phase 3 finding) | translation is usable; no verified way to DISPLAY the output — see Phase 3 below |
| zh-en | Shipped, excellent | English output, no glyph risk |
| en-jap / jap-en | **Evaluated, NOT shipped** | pure `<pad>` collapse at step 0 (masked in the probe, not the app); output still incoherent after the fix — Japanese needs a Brain (Phase 5), not the Marian floor |
| en-pt / pt-en | **Evaluated, NOT shipped** | no clean-licensed `tc-big` OR base ONNX conversion clears the trust ladder — a directive-token mechanism gap, not a quality one |

The decoder-trap ADR-0008 discovered (frozen cross-attention KV across
autoregressive steps) was re-probed against the new pairs and holds; the
Marian tokenizer's one real gap this pass found — fullwidth ASCII
punctuation (`！`vs`!`) not folding before Viterbi encoding — was fixed
in `marian_tokenizer.dart` and is what makes the CJK golden vectors in
Phase 3 match real sentencepiece output exactly.

## Phase 1: Spanish becomes a parameter

`reader_screen.dart`'s translation state was renamed and re-derived
end to end: `_showTranslation`/`_translatedSentences`/
`_speakTranslation` replace the `_showSpanish`-shaped fields; `_load()`
resolves `availableTranslationTargets`, the active language (with a
LEGACY FALLBACK for pre-campaign data — see below), and the translator
for whichever pair is actually active. `_openTranslatePicker()` replaces
the fixed "Translate to Spanish" action with a picker over whatever
`availableTranslationTargets` returns.

**A real crash this generalization would otherwise have shipped:**
Supertonic's own language gate (`supertonicSupportedLangs`, still
`{'en', 'es'}` per Phase 0's own indexer census — see tts-voices.md) does
not cover German, Russian, or Chinese. Speaking a German translation
with a neural voice primed and preferred would have thrown
`SupertonicUnsupportedLangException`, uncaught, mid-utterance.
`_resolveEngine()` now checks `_activeTranslationLang` against that same
set BEFORE selecting an engine, forcing the system voice whenever the
active translation's language isn't neurally covered — engine
SELECTION, not per-utterance error handling, so the picker never reaches
Supertonic's own gate at all. Tested for German, Russian, and Chinese
alike (`reader_speak_spanish_test.dart`'s Phase 2/3 groups).

**Legacy compatibility:** a work translated under the old, es-only
scheme has `showTranslationLayer=true` and `activeTranslationLang=null`
(the column didn't exist yet) — `'es'` was the only language that could
have written it, so `_load()` reads that shape as an implicit `'es'`.

**Two regressions an adversarial review caught in this same pass, both
fixed and regression-tested, neither ever released:**

1. **Dead controls.** `setActiveTranslationLang` runs BEFORE a batch
   produces its first sentence (so the progress card can appear
   immediately); an active language with zero stored rows — a fresh
   pick mid-run, a batch cancelled at zero, a work reopened mid-run — was
   offering a "Show ⟨language⟩" toggle with nothing behind it. Gated on
   a new `_hasStoredTranslation` getter (active language AND at least
   one row) instead of the active language alone.
2. **Pre-campaign data losing its toggle.** The legacy `'es'` probe was
   conditioned on `showTranslation` being true, so a 1.3.0 work with
   stored Spanish but its DISPLAY toggled off lost the toggle entirely on
   reopen — indistinguishable from never having translated anything. The
   probe for EXISTENCE no longer depends on the bool that gates DISPLAY.

## Phase 2: the crown, verified per script family

The full episode flow — transcript sentences -> resumable batch
translation (`TranslationJobController`, its per-sentence contract
unchanged in this phase) -> speak-in-X with the karaoke cursor tracking
the ORIGINAL English — was already generalized by Phase 1's own
parameter; the karaoke screen itself has no translation surface of its
own (its only door is "Read from here," into the same reader). What
Phase 2 owed was proof, not new plumbing:

- Per-script-family speak tests mirroring Spanish's own "system voice
  path" test exactly (translated sentence speaks in-language, untranslated
  falls back to English, cursor advances through the ORIGINAL sentences
  either way): German (Latin), Russian (Cyrillic), Chinese (CJK) — the
  last needing no sentence-boundary handling of its own in THIS
  direction, since `splitSentences` only ever runs over the English
  source; the translated body is substituted as one opaque string per
  sentence.
- A long-form endurance suite, pure Dart over `sentenceUnitsOf`/
  `translatedTextFor` (the same two functions the speak loop calls
  per-sentence) at a 600-segment/~1200-sentence episode-scale document:
  exact numbering, the fallback law checked for every single unit
  against a simulated partial batch, and a stale-reingest case proving
  one reshaped sentence never invalidates a whole episode.

**Recorded, not built:** background/lock-screen playback (`audio_service`)
for the speak-in-X loop — a real dependency gap, unrelated to
translation itself, inherited from however speak-mode already behaves
under a locked screen today.

## Phase 3: CJK segmentation, and a font-rendering finding that changed the shipped feature set

`tokenizer.dart`'s word-splitting and `sentence_splitter.dart`'s
boundary regex were both ASCII/whitespace-only by construction — a
space-less CJK run either collapsed to `tokenizer.dart`'s own `…`
placeholder (KNOWN DONOR LIMITATION M8, on record since the RSVP port)
or spoke as one giant utterance (exactly the "long-utterance stall"
ADR-0006 built the sentence splitter to fix in the first place). New
`loom_core/lib/src/cjk.dart` implements the baseline UAX #29 already
specifies absent a dictionary: one Han ideograph per unit (no
"don't-break" rule joins adjacent ideographs by default), a maximal
Katakana run kept together (rule WB13), Hiragana one character per unit
— a real ceiling for Japanese grammatical words (食べる splits into
食/べ/る), TinySegmenter or a dictionary the honest fix, not shipped
this phase since `ja` carries no Marian pair either direction (Phase 0).
Both consumers route through this one module; a grep of every
whitespace-split site in `loom_core` found exactly these two, no second
tokenizer introduced.

**The finding that changed the shipped feature set.** A golden-test
render (`app/test/visual/cjk_font_golden_test.dart`, the same
self-guarded `VISUAL_TOUR=1` convention `tour_golden_test.dart` uses) of
the scroll-mode Chinese translation display showed tofu boxes. Two
follow-ups turned this from an open caveat into a settled, costed
decision:

1. Declaring `fontFamilyFallback` naming a system CJK font this
   development box genuinely has installed made no difference —
   `flutter test`'s golden pipeline loads only asset-bundled fonts and
   never consults fontconfig, proven by the experiment producing a
   byte-identical render, not by assumption.
2. Bundling a CJK font was costed, not guessed: Noto Sans SC's
   single-weight, single-region subset OTF measures 8,331,336 bytes
   against `app/budgets.json`'s ~3.3MB of remaining C3 APK headroom. It
   does not fit.

This app already has a conformance law for exactly this situation —
`fleet_conformance_test.dart`'s `FleetCheck.c7Fonts`, which exists so
glyph rendering never depends on what happens to be installed on a
device (Lora/Nunito are bundled for exactly this reason). Recording
"add `fontFamilyFallback`, verify on hardware" as the open next step
would have adopted the exact assumption that law exists to forbid, right
after proving it can't be checked from anything the app controls.
**Consequence: `opus-mt-en-zh` is not registered.** `opus-mt-zh-en`
(Chinese source, English output) is unaffected — Latin text, no glyph
risk, and it is Phase 4's foundation. Speak-in-Chinese itself was never
blocked by this finding; what's withheld is the DISPLAY toggle a
just-proven-broken render would sit behind.

**C7's own scope, worth naming for whoever reads this check next:** C7
bounds AUTHORED UI strings (literal source-code text) — a translation
feature's runtime output, produced from arbitrary model text, falls
outside what a static cmap-coverage scan can check at all. Not a gap
this campaign introduced; a boundary worth knowing C7 won't catch.

## Phase 4: the X->en direction — one lane already existed

Investigation before writing anything found the spec's own "whisper
translate-while-transcribing lane" already fully shipped, predating this
campaign: River's episode menu has offered "Transcribe + translate to
English" since before "Babel widens" started
(`transcribe_coordinator.dart`'s `WhisperTask.translate` +
`translateJobId`, `transcript_writer.dart`'s `writeTranscript(...,
translation: ...)` projecting the second whisper run's segments onto the
primary transcript's alignments as a SEPARATE `Layers` row, `kind: 'mt'`,
`lang: 'en'`), complete with its own passing tests
(`transcribe_flow_test.dart`). It never needed language-parameterizing
the way the Marian pipeline did — whisper's translate task is the same
model regardless of source language, so it was never es-specific to
begin with. **Nothing was built here; a reader who assumes both X->en
lanes were generalized by this campaign would go looking for work that
was never needed.**

What Phase 4 actually owed:

- An end-to-end test proving the Marian reverse direction works through
  the FULL reader flow (picker -> batch -> store -> active-lang ->
  display), not just the registry lookup
  `device_services_translation_test.dart` already covered. A
  German-sourced work now offers English as a translate target via
  `opus-mt-de-en`, ending in the same `activeTranslationLang`/"Show
  English" state the forward direction already proves.
- A test proving the artifact-separation law the two X->en lanes
  actually need: whisper's lane writes to `Layers` (kind `mt`); the
  Marian picker writes to `TranslationSentences`. Different tables,
  neither aware the other exists, and a user could plausibly reach both
  for the same work — confirmed neither write disturbs the other's rows.

## Phase 5: BrainTranslator — built, tested, NOT wired into the live app

The one real design question, resolved before writing either class:
`TranslationJobController.translate` is a strict `Future<String>
Function(String)`, called once per sentence, in `units`' own order —
the right grain for Marian (one ONNX call per sentence), the wrong one
for a Brain-backed translator, where sending 10-20 sentences in ONE
request is the entire efficiency point. Rather than teach
`BrainTranslator` fragile lookahead tricks to fake batching through a
per-sentence closure, the controller itself gained a second, optional
path: `translateBatch` (`Future<List<String?>> Function(List<String>
sentences)`) plus `chunkSize`. When set, `start()` groups
not-already-stored units into `chunkSize` chunks and calls it once per
chunk instead of `translate` once per sentence; `translate` stays
required and every existing Marian call site — and all seven of its
pre-existing tests — compiles and passes completely unchanged when
`translateBatch` is unset. Failure granularity was designed to match
what "fail-closed per sentence, never per episode" actually needs at
two levels: a `null` at one array position fails just that sentence
(English falls through); the whole batch call throwing fails every
sentence in that ONE chunk, never the whole run — the next chunk still
executes. Cancel is checked only at chunk boundaries, the smallest
atomic round trip on this path.

`BrainTranslator` itself sits on domovoi's `Brain` interface: one request per
chunk, a numbered sentence list in, a strict `{"translations": [...]}`
JSON object out, parsed via `extractJsonObject` — the SAME
extract-then-parse house pattern `DiscourseGrader`/`RecapGenerator`
already use (`brain_wiring.dart` now re-exports `extractJsonObject`
alongside them; it was reachable only via a `src/` import before).
Fail-closed exactly as the controller's chunked path expects: an
unparseable or wrongly-shaped whole reply throws
`BrainTranslationFailedException`; a missing/non-string/blank array
entry becomes `null`. The Brain's own `AskException` propagates
untouched. Proven against a scripted fake Brain, and — the specific
check most worth doing directly rather than assuming — against a stove
tier pinned with nothing real behind it: `UnavailableTierBrain` throws
`AskException` unconditionally today (there is no real `StoveClient`
wired), so a `BrainTranslator` sitting on it hits the whole-chunk
failure path for every single chunk. A full `TranslationJobController`
run against exactly that shape reaches `done` with nothing stored and
every unit counted as processed — never a hung run, never an uncaught
throw a caller would need its own try/catch for. This is the state a
real user most easily lands in (pin stove, translate something, nothing
is actually connected yet), and it degrades exactly like every other
translator failure in this app already does.

**What did NOT get built, named rather than left to be discovered by
grepping for it:**

- **The tier ladder.** Nothing in `DeviceServices.resolveTranslator`
  or the reader's picker ever constructs a `BrainTranslator` — it is a
  complete, tested, standalone class with zero call sites outside its
  own file and tests. Wiring "which Brain tier is pinned decides Marian
  vs. Brain, and which Brain" is real work: reading the user's pinned
  `BrainTier` (`brain_store.dart`'s `brainForUse()`), deciding when a
  Brain rung should even be OFFERED (Phase 0 already named Japanese as
  the case that needs one — the Marian floor has nothing for it), and
  composing that decision with `DeviceServices.availableTranslationTargets`.
- **Egress consent for translation specifically.** `brainForUse()`
  already returns `requiresEgressConsent` — the chokepoint exists (the
  Courses tab's distillation flow already fronts every cloud call
  through it) — but nothing routes a translation request through it.
  Doing this properly means deciding whether translating an ENTIRE
  episode through a paid cloud API is a per-chunk consent question or a
  per-work one; the wrong answer is a dialog after every 15 sentences.
- **A "Brain" rung in the reader's own engine picker.** The
  "Translate…" picker only ever shows languages a downloaded Marian
  pair covers; there is no UI concept yet of "translate this into
  Japanese via your Anthropic key" for a language the offline floor
  doesn't reach.

Stopping here rather than pushing through all three in the same pass
that also owed this ADR was a deliberate choice, not a budget one — the
tier ladder and consent design deserve the same "write it down before
building it" treatment this document gave Phase 5's core chunking
question, and folding three more open design decisions into an
already-long pass risked exactly the kind of undiscovered coupling bug
this campaign's own regression fixes (Phase 1) were caught having
shipped.

**Addendum 2, part 2 — decided, not deferred further:** the stove
tile's subtitle stays "on the roadmap." This phase did not wire a real
`StoveClient` connection — `BrainTranslator` is generic over any
`Brain`, and the stove tier's own `Brain` (`UnavailableTierBrain`)
remains the same permanent stand-in it always was. The addendum's own
condition ("when your Phase 5 wires the stove lane for translation")
was not met, so the subtitle's honesty holds without a code change;
"Local model" stays honestly not-yet, also unaffected.

## What's deferred

- **Background/lock-screen playback** for the speak-in-X loop
  (Phase 2) — a real dependency (`audio_service`), not built.
- **TinySegmenter for Japanese** (Phase 3) — the ideograph-run/WB13
  baseline ships; a real dictionary segmenter for Japanese grammatical
  words is named, not built, since `ja` carries no Marian pair.
- **A bundled CJK font** (Phase 3) — costed at 8.3MB for a single
  region/weight against ~3.3MB of remaining APK budget; would unblock
  `opus-mt-en-zh` if a future pass has the room.
- **Real-hardware verification** of the bare two-letter locale code
  (`'de'`, `'ru'`, `'zh'`) reliably resolving to an installed system TTS
  voice — the same unverified assumption ADR-0008 already carried for
  `'es'`, now widened to three more languages rather than a new one.
- **The Brain tier ladder, egress consent for translation, and the
  reader picker's own "Brain" rung** (Phase 5) — `BrainTranslator` and
  the controller's `translateBatch` path are built and tested; nothing
  yet decides when to use them, asks consent for a cloud call, or offers
  the option in the UI. This is the largest deferred item in this ADR
  — a future pass wiring a household stove connection, a BYOK cloud
  tier for translation, or Japanese's Brain-only path (Phase 0) all
  depend on this being done.
- **The progress card has only ever driven the per-sentence path.**
  `reader_screen.dart`'s `_startTranslation` constructs
  `TranslationJobController` without `translateBatch` — consistent with
  "BrainTranslator is unwired" above, but worth being explicit that the
  UI's behavior under batch-granularity `doneUnits` jumps (15 at a time
  rather than 1) has never been driven through a widget test, only
  through `TranslationJobController`'s own unit tests directly. Whoever
  wires the tier ladder should check the progress card still reads
  calmly at that jump size, not assume it does because the controller's
  own state machine is tested.

## Consequences

- The picker, the store, the batch action, and the speak loop are all
  genuinely language-parameterized now — a future pair is registry data
  (one `ModelSpec`, one `sourceLang`), not an engine change, matching
  the template ADR-0008 already left for a single-direction addition.
- The hub-and-spoke law (2N, not N²) is now load-bearing in the
  registry's own shape (`pickTranslationPair`'s (source, target) key),
  not just a design intention — a Russian-to-German request has no path
  through this registry at all, by construction.
- Two real regressions (dead controls, a legacy-data toggle loss) were
  caught by review before release, not after — recorded above with their
  fixes and tests, not smoothed over.
- One feature was demoted on real, measured evidence (a golden-test
  render, a costed font bundle) rather than shipped on an assumption
  that a system font would probably save it. The evidence — and the
  reasoning for why "probably" wasn't good enough given this app's own
  C7 doctrine — is recorded in full in `docs/reference/mt-models.md` and
  `docs/reference/tts-voices.md`, not just this summary.
- A second Translator rung exists behind the same `Translator` boundary
  the Marian pipeline uses, proven against a scripted Brain and against
  the specific degraded state (stove pinned, nothing real behind it) a
  real user most easily reaches — but it is inert: no code path in the
  shipped app can reach it yet. A future reader wiring the tier ladder
  has a tested translator and a tested chunked-batch controller path
  already waiting, not a blank page; what remains is the DECISION layer
  (which tier, whose consent, which UI), not the translation mechanics.
