# Espalier — the OpenHearth reading-and-remembering loom (working name PrimingTrellis; an espalier is literally a tree trained on a trellis, and the shipped APK upgrades package com.openhearth.trellis in place)

**Stack:** TypeScript (strict) + Vite + Preact/signals PWA; ML in Web Workers via @huggingface/transformers v4 (WASM/WebGPU) + wllama/WebLLM + kokoro-js + piper-tts-web; IndexedDB + OPFS storage; @noble/ciphers + WebCrypto for OHBK; Vitest + fake-indexeddb + Playwright; WebView-shell APK (Parlour precedent); Tauri desktop later.

## Architecture
# Espalier — full design

**One modular TypeScript codebase, web-native.** The single-file era was the jank, not the requirement: ohPrimer's own `rebuild/` already proved the porting method (7 modules, 108 node tests, verbatim extraction + issue-ID regression tests). Espalier finishes that thought at full scale, welds in Trellis's study semantics verbatim, and rebuilds the ML layer from first principles on transformers.js v4.

## 0. Thesis

Everything the user takes in — podcast episode, article, EPUB chapter, feed item, pasted text, generated passage — becomes a **Work threaded on one spine**: an ordered list of sentence-grade spans. Text, audio, transcript, and translation are **layers addressed by the same span IDs**. Position is a spine address, not a layer address — so you stop listening in the car and resume reading at the same sentence, possibly in another language. Study items anchor to span ranges, so no card is ever an orphan prompt (Matuschak's law). The LLM is a seam, never a resident: it distills, converses, and grades **only when asked**, and its distillation output must pass the same strict `.ohcourse` parser as any human-authored course — the openDaisugi instinct (verify what the LLM authored) applied to curriculum.

## 1. Stack (with maturity evidence)

- **Language/build:** TypeScript strict, Vite, ES modules, zero runtime CDN — every dependency vendored and bundled (the esm.sh-outage-bricks-ML failure mode dies here).
- **View:** Preact (+ @preact/signals) — ~4KB, a decade stable; the reader surfaces (RSVP, minimap, scroll reconciliation) stay hand-rolled canvas/DOM exactly as the donor proved out.
- **ML:** `@huggingface/transformers` **v4** (Feb 2026, rewritten C++ WebGPU runtime, ~200 architectures — per the research packet, target v4 not v3); `kokoro-js` (Kokoro-82M ONNX); `piper-tts-web` (Mintplex-Labs fork, MIT, CPU WASM); `wllama` V3 (llama.cpp WASM+WebGPU, OPFS streaming, MIT); `@mlc-ai/web-llm` (18.5k stars) as an optional lazy chunk for big-desktop discourse; `@ricky0123/vad-web` (Silero VAD, ~2MB) for hallucination suppression.
- **Study:** own verbatim SM-2 port (default) + `ts-fsrs` (FSRS-6, MIT, ~740 stars, ships default parameters) behind one Scheduler interface.
- **Crypto:** `@noble/ciphers` (zero-dep ChaCha20-Poly1305 IETF) + native WebCrypto HKDF-SHA256/PBKDF2-HMAC-SHA512 — exactly the gap analysis in the fleet packet (OHBK + stove need only the AEAD filled in).
- **Parsing:** JSZip (EPUB — donor precedent), pdfjs-dist, tesseract.js (lazy, OCR fallback), fflate (zips), `@sqlite.org/sqlite-wasm` (~1.2MB lazy) for in-browser genanki-faithful `.apkg`.
- **Tests:** Vitest + fake-indexeddb + Playwright; visual-loop skill for screenshot review.

## 2. Module map

```
espalier/
  src/
    core/        # Result, typed events, epoch-day time, ids
    tokens/      # ohStyle tokens.css + tokens.ts import (C1: single source)
    spine/       # Work, Span, Layer, Alignment, Position — THE model
    store/       # typed IDB wrapper, schema+migrations, OPFS blob store, quota/eviction
    comms/       # fetch policy: SSRF guard, consent gate, proxies, conditional GET, caps
    intake/      # epub, pdf+ocr, text/md heuristics, url-article, gutenberg, reading-list, tokenizer
    feeds/       # subscriptions, discovery, refresh hygiene, auto-download, river, OPML
    reader/      # rsvp, parafoveal, scroll, speak, toc, minimap, page panel, context strip, sentinels
    audio/       # player bar, chapters (JSON+PSC), offline cache, timing sync
    ml/          # model registry, download engine, InferenceHost worker protocol, asr/translate/tts adapters
    jobs/        # checkpointed resumable job engine (transcribe/synthesize/distill/download/ocr)
    study/       # scheduler seam (SM-2 verbatim + ts-fsrs), grading, 4 item types, DAG, session, revlog
    courses/     # .ohcourse 1.0/1.1 strict parser, repository, distillation validator
    brain/       # LLM seam: Null/Byok/OllamaLocal/Wllama/WebLLM/Stove providers + router
    discourse/   # comprehension checks, Socratic follow-ups, explain-back, distillation pipeline
    profiles/    # multi-profile, parent dashboard + PIN, per-profile scoping
    backup/      # OHBK v2 read/write, legacy trellis/ohPrimer import, anki csv+apkg, vault snapshot
    ui/          # screens: Hearth, Shelf, River, Reader, Espalier(course map), Tend(review), Kiln(jobs)
    pwa/         # sw (shell cache + COOP/COEP injection), manifest, install, share-target
  workers/       # inference.worker.ts, jobs.worker.ts (real files, not blob URLs)
  tests/         # vitest unit, behavior (playwright), goldens, budgets
```

Dependency rule (enforced by a lint test): `spine`, `study`, `courses`, `backup`, `intake` parsers, and `comms` policy are **pure** — no DOM, no IDB, no fetch; effects live in `store`, `jobs`, `ui`. This is what made Parlour and the Trellis domain layer testable, kept.

## 3. Content spine data model (requirement 2, the heart)

```ts
Work   { id, kind: 'book'|'article'|'episode'|'note'|'generated', title,
         provenance {url?, feedId?, courseId?, model?}, langGuess,
         ephemeral: boolean, decayAt?, pinned, createdAt }
Span   { seq, blockIdx, kind: 'text'|'heading'|'code'|'table'|'figure', hash }   // sentence-grade
Block  { idx, kind, tocEntry? }                                                  // paragraph-grade, sentinels preserved
TextLayer  { workId, lang, role: 'original'|'transcript'|'translation'|'summary',
             chunks: SpanTextChunk[] }        // ~200 spans/record — bounds rewrite cost
AudioLayer { workId, blobRef(OPFS), duration, provenance: 'enclosure'|'tts:<voice>'|'file',
             timing: chunked span→[t0,t1], wordTiming?: experimental, confidence }
Position   { profileId, workId, spanSeq, tokenOffset, mediaTime?, mode, updatedAt }  // OWN tiny store
CardAnchor { workId, spanRange, focusTokens }  // every card deep-links to context
```

- **Format switch:** mediaTime→span via timing map→reader opens there; span→t0 the other way; translation layers share span IDs so switching language keeps the exact sentence. TTS layers are synthesized per-span, so their timing is intrinsic.
- **Alignment sources:** Whisper segment timestamps give sentence-grade alignment natively (the reliable multilingual path); translation alignment is 1:1 by span (NLLB/opus-mt called per-span, as the donor's translation strip already did per-block); EPUB/article spans come from the ported tokenizer's segment map.
- **Ephemera decay by default:** feed items and cached episodes carry `decayAt` (per-feed keepN/days, donor eviction semantics). Any work that is read-progressed, extracted-from, carded, or pinned is **promoted** (`ephemeral=false`) and persists. Works persist; ephemera compost. This is attention sovereignty in the schema, not in a setting.
- **Positions/translations split out** of the work record — the donor's "position autosave rewrites megabytes" jank is fixed structurally.

## 4. Storage

- **IndexedDB `espalier` v1** stores: works, spanChunks, textLayerChunks, audioLayers(meta), positions, extracts/cards, revlog(append-only), courses, feeds, episodes(meta, **guid+profileIdx stamped on write** — fixes the donor's orphan jank), jobs, profiles, settings, consents.
- **OPFS** for all big bytes: episode audio, TTS caches, figure blobs, **model files**, backup vault snapshots. IDB-blob fallback where OPFS is absent (old WebViews).
- **Multi-profile scoping** on every store; profile delete cascades everything including episodes and TTS caches (donor bug fixed).
- **Quota citizenship:** `navigator.storage.persist()` requested on install; storage panel shows per-bucket usage (models/audio/works/courses) with per-feed purge; 80% quota warnings; auto-download respects metered + quota (donor semantics kept). Quota realities from the packet (Chrome 60%/origin, Firefox 10GiB best-effort, Safari ~60% but 7-day eviction unless installed) are surfaced honestly in the storage panel copy: "install to home screen to protect your library" on iOS.
- **Migrations:** versioned, tested with fake-indexeddb fixtures.

## 5. ML runtime

**Worker architecture:** real module workers (no blob-URL eval). One `inference.worker` owns all model sessions behind a typed request/response protocol (`InferenceHost` interface) with transferables, streamed progress events, and per-task cancellation via AbortSignal (v4 supports it — the donor's "cancel merely abandons the promise" dies). A `MockHost` implements the same interface for tests. Sticky fallback flags are replaced by per-task retry with cooldown + explicit user retry (donor jank fixed). Eviction is **platform-aware**: memory budget probed (deviceMemory, iOS heuristic); desktop keeps 2–3 sessions resident, iOS keeps 1 (donor's evictExcept behavior as the floor, not the ceiling).

**Threading/backends:** WebGPU where present (all major browsers ship it default-on in 2026, incl. Safari 26 per the packet). Where absent, multithreaded WASM — GH Pages sends no COOP/COEP, so our service worker injects `COOP: same-origin` + `COEP: credentialless` (coi-serviceworker technique; all assets same-origin so nothing breaks). Whisper encoder pinned int8/fp32 on WebGPU per issue #1590 (fp16 encoder precision bug).

**Model registry:** a vendored manifest of pinned model files (HF resolve URLs), sizes, sha-256, licenses — all chosen models are **Apache-2.0/MIT and ungated** (no token walls in a no-account product; Qwen not Gemma/Llama, per the packet). Downloads land in OPFS via the download engine (§6) and transformers.js v4 is pointed at that cache — a browser-cache eviction can never silently re-trigger 600MB again.

Per-tier model table → see ml_plan. Long-audio recipe: 30s windows / 5s stride (the canonical chunking), Silero VAD pre-pass to skip silence (kills the ~1% hallucination concentration in silences), language picker + auto-detect stored on the work record, Whisper's built-in `task:'translate'` (X→English) exposed as a one-tap "rough English" layer.

## 6. Reliability engineering

**Download engine — the domovoi laws ported to TS** (pattern, not code, exactly as its doc comment instructs): resume = HTTP `Range` from OPFS `.part` length; 416 or 200-on-resume → discard and restart (never append onto stale bytes); integrity + atomic `.part→final` rename live in the caller's `promote` callback (sha-256 vs registry manifest); progress `(received, total?)` offset by resumeFrom; cancel keeps the partial; cold stream; `onOutcome` fires exactly once. UI: real MB totals, honest ETA, a **persistent resume card** in the Kiln for any partial, metered-connection warning, consent naming exact sizes (donor's consent gate kept verbatim).

**Job engine — every long operation is a checkpointed, persisted Job:**
```ts
Job { id, kind: 'transcribe'|'download'|'synthesize'|'distill'|'ocr'|'feedSweep',
      params, checkpoint, progress {done,total,unit,etaMs}, state, error? }
```
Jobs run in a dedicated worker (worker threads are NOT throttled in background tabs, per the packet; Screen Wake Lock — universal since iOS 18.4 — held while foreground), survive reload/crash via IDB, and resume on boot. **Transcription specifically:** enclosure streams to OPFS (never a 300MB RAM buffer); decode proceeds in chunks (WebCodecs AudioDecoder where present; MP3 frame-boundary slicing + decodeAudioData fallback for Safari; whole-file decode only below a size threshold); each 30s window commits its segments to `checkpoint.segments` with `decodedThroughSec`; the partial transcript is **visible and readable while the job runs**; a killed 40-minute transcript resumes at its last window, never restarts. Completion promotes segments atomically into a TranscriptLayer. TTS synthesis is the same shape: per-span WAV chunks cached in OPFS keyed (work, voice, spanSeq), playback starts when the first sentence is ready (streaming — the donor's 5–15-minute wait dies), partial cache is usable. Kiln screen = all jobs, honest progress, pause/resume/cancel.

## 7. Study engine — Trellis semantics verbatim, then exceeded

**Ported exactly (with its property tests):** SM-2 in whole UTC epoch days; q(again/hard/good/easy)=2/3/4/5; EF′=EF+(0.1−(5−q)(0.08+(5−q)·0.02)) clamped ≥1.3; lapse resets interval/reps, lapses++, same-session relearn requeue with cleared inputs; success base = firstIntervalDays | 6 | round(interval·EF′), hard ×0.6 / easy ×1.3, then the **monotonic floor max(that, oldInterval+1)**; mastery = interval ≥7d; node mastery = fraction; unlock iff every prereq at 1.0; **unlock-is-first-exposure-only** (a started node never re-locks); grading: normalizeAnswer, cloze exact-all-blanks, discrimination index, keywordCoverage with 0.5/0.85 thresholds, suggestion-only-highlights-a-button; clozeKeysInTextOrder; the four item UIs (cloze/qa/discrimination/procedure) with hints/sources/rung chips. The monotonic-growth-under-repeated-Hard and unlocked-never-relocks property tests port **verbatim** as the crown jewels.

**Exceeded:**
1. **Revlog** — append-only review history per card (Trellis's admitted gap). Enables FSRS optimization later and honest Anki interchange (serious SRS users treat review-history lock-in as disqualifying, per the packet).
2. **FSRS-6 opt-in** via ts-fsrs behind the same `Scheduler` interface, default parameters, one knob (desired retention, default 0.90). Mastery maps to stability ≥7d; unlock-first-exposure-only makes re-lock impossible under either scheduler. SM-2 remains the default so `.ohcourse` semantics and the deterministic test suite stay exact.
3. **The empty-app fix** (144-of-200-days jank): review sessions come in bounded servings (8/15/25, Readlang precedent); when the garden is tended, the end screen offers (a) the next locked node's intake **as reading**, and (b) an explicit "sprout ahead" that starts ONE node early, flagged, never counted as mastery, never unlocking downstream. Course authors can set `gate: strict|standard` in 1.1; the default preserves Trellis exactly.
4. **Construction & discourse** (§9) — retrieval + elaboration on top of the typed items, per Dunlosky's high-utility list.
5. Extract-to-card (donor flow: swipe-up, drag-select focus span, V-flag vocab) now creates **typed** items with span anchors — every card can jump back into its source context, and "hear this sentence in the episode" works when the source has an audio layer.

## 8. .ohcourse 1.0 / 1.1

The 1.0 strict/tolerant parser ports with its full rejection matrix (schemaVersion '1.0' only, per-type required fields, unknown/self/cyclic prereqs rejected with path-qualified errors, never half-imports). **1.1 adds only optionals** (1.0 files remain valid): `discourse` per item (followUps[], explainBack{prompt,rubric}, misconceptions[]), `anchors` (span refs into a source work), `gate: strict|standard`, and `diagramMermaid` finally **rendered** (lazy mermaid chunk) instead of parsed-and-ignored. Import via paste, file picker, share-target, and deep link. The bundled Kalman starter course ships as an asset. Courses distilled by the LLM must pass this same parser — repair loop ≤2 attempts, then honest failure.

## 9. LLM seam (requirement 4)

Domovoi's Brain seam, ported: `interface Brain { complete(req): Promise<string>; stream?(req): AsyncIterable<string>; caps: {ctx, local, name} }` + `AskException` (displayable message, cause logged). Providers: **NullBrain** (T0 — every discourse affordance hides, nothing breaks), **ByokBrain** (Anthropic direct-browser or any OpenAI-compatible endpoint — donor's callLLM + test-connection kept), **OllamaBrain** (local endpoint, egress-consent-exempt per donor's isLocalEndpoint law), **WllamaBrain** (Qwen2.5-0.5B q8 in-tab for utility tasks), **WebLlmBrain** (Qwen3-1.7B/4B on strong WebGPU desktops), **StoveBrain** (household desktop — honest status in ml_plan/risks). A router assigns task classes: distillation prefers big-context providers (stove/BYOK), cloze-making and keyword-grade assists run on the 0.5B.

**Three discourse moments:**
- **Distill-time (works at T0):** distillation writes followUps/explainBack/misconceptions INTO the course, so a potato-phone student gets construction-and-discourse study with zero runtime inference. This is the single most important design move for the potato floor.
- **Review-time (T2+/BYOK/household):** post-reveal Socratic follow-up ("why does this hold?"), explain-back grading annotated PASS/REVIEW — **never overrides self-rating** (Trellis law preserved).
- **Reading-time:** donor's comprehension check upgraded with generation-effect prompts ("give your own example").

**Distillation pipeline** (a Job): source Work → chunked map (concept candidates + span anchors) → reduce (DAG + typed items + discourse) → strict-parser validation → editable review screen (per-node accept) → import. Anki-grade provenance: every node keeps its span anchors.

## 10. Feeds & comms

The rebuild's `40-comms.js` is already the reference design and ports near-verbatim to TS: SSRF guard before every fetch (schemes, loopback/link-local/private/metadata hosts), direct-first with 5s timeout, **consent-gated public proxies naming exactly which third parties see the URL**, background refresh never prompts, 25MB text / 300MB audio / 8MB XML caps enforced mid-stream, conditional GET (ETag/Last-Modified), 304/404/410/429+Retry-After, 5-failure breaker. Feed discovery, iTunes directory, OPML both ways, auto-download queue (metered + quota aware), river view (reverse-chron only, unread/audio/text filters, capped read-tracking) — all donor semantics kept. `<audio src>` streams cross-origin without a proxy (playback never needs consent; only byte-reads do). Optional self-hosted proxy URL setting for households that run one. Desktop Tauri phase removes the proxy need entirely.

## 11. Attention sovereignty by structure

No analytics module exists; there is nothing to toggle. Reverse-chron only; the sole badge is the due count (memory math, not engagement math). Bounded sessions with a natural end ("The garden is tended."). No streaks, no repair purchases, no mascot guilt, no leaderboards — a calendar of days-tended is shown plainly, loses nothing when broken. Ephemera decay is default-on. An **egress ledger** screen (WeatherGlass precedent) enumerates every possible network egress and its consent state; a Playwright test asserts **zero requests post-load without consent** — the C4 spirit, re-pinned as a web test.

## 12. Backup & migration

**OHBK v2 in TS** against the wire format in `ghost_backup.dart`: `OHBK|0x02|0x01|nonce12|mac16|ct`, AAD = header‖utf8(context), ChaCha20-Poly1305 IETF via @noble/ciphers, BIP39→PBKDF2-HMAC-SHA512(2048,"mnemonic")→HKDF-SHA256 with `openhearth.espalier.<purpose>.v1`. **Cross-implementation golden fixtures generated by the Dart core prove byte compatibility both ways.** Study data (courses, cards, revlog, profiles, settings, feeds-as-OPML) fits the 10MB envelope; the full library exports as `.ohbka` — a zip of ≤10MB OHBK envelopes + manifest (honest about the format cap). Weekly silent vault snapshot to OPFS when a key exists (Trellis law). **Legacy import:** Trellis-domain `.ohbk` (appDomain 'trellis', aadContext 'trellis-backup/v1' — courses+cards map 1:1) and ohPrimer plaintext JSON backups (books/extracts/feeds, with the donor's prototype-pollution sanitizer). The standard data hop is `.ohbk` (fleet law: no backwards-compat theater); a ~40-line optional shell bridge that one-shot-reads the surviving `shared_prefs` XML from the same package dir is a Phase-F nicety, not a dependency. Anki: CSV (donor format) + genanki-faithful `.apkg` **on all surfaces** via sqlite-wasm — exceeding Trellis, which hid it on web.

## 13. Surfaces

1. **PWA** — repo `Espalier`, deployed Parlour-style (static files on master ARE the site) at `levitatingflyfisher.github.io/Espalier/`; landing APPS entry swaps the Trellis card. SW: app-shell cache + COOP/COEP injection + offline toasts; share-target for .ohcourse/.ohbk/audio files; `?url=` deep link kept.
2. **Android** — `EspalierShell` forked from ParlourShell: one main.dart, webview_flutter at the live PWA URL, PopScope back-nav, applicationId **com.openhearth.trellis, versionCode 4** (> Trellis's +3) — sideload upgrades the existing install base in place; released as `Espalier.apk` via releases/latest/download. First-run offers "Restore from a Trellis backup".
3. **Desktop (post-1.0)** — Tauri wrapping the same dist; sidecars: whisper.cpp + llama.cpp native binaries for T3-class local inference without browser limits; native StoveBrain (no CORS problem outside the browser); real filesystem import/export.

## 14. Signature UI

ohStyle tokens as the single source (tokens.css/tokens.ts imported, C1 spirit; Lora/Nunito self-hosted; the ≤/≥ glyph trap gets a cmap test — C7 ported). Print-like heritage: linen ground, Lora serif measure, drop caps on works, terracotta accents, warm shadows, dark "night-linen" scheme. **The signature:** a thin copper **reading thread** — the same spine-position element rendered in the reader margin, the audio bar, and the translation strip, visibly the *same thread* as you switch formats; and the **espalier course map** — nodes as grafts trained along horizontal wires (tiers of the DAG), bare wood = locked, swelling bud = due, blossom = started, fruit = mastered. Screens: Hearth (home/profiles), Shelf (library), River (feeds), Reader, Espalier (course), Tend (review), Kiln (jobs). Full donor a11y parity: focus-trapped modals, OpenDyslexic + high contrast, reduced-motion, 320dp × 3× text-scale sweep as a test.

## 15. Test strategy

- **Unit (Vitest):** the rebuild's 108 tests port first (same modules, TS); Trellis's invariant matrix ports verbatim (exact SM-2 values, ease floor, monotonic-Hard property, unlocked-never-relocks 30-Hard property, lapse-only-shrink, purity, grading boundaries 0.5/0.85, cloze ordering, parser rejection matrix incl. cycle paths, corrupt-store tolerance). Target ≥450 unit tests by v0.1.
- **Cross-implementation goldens:** OHBK fixtures emitted by the Dart sanctuary core, decrypted by TS and vice versa; `.apkg` structure fixtures vs Trellis's exporter; `.ohcourse` acceptance corpus shared with Trellis.
- **Store:** fake-indexeddb + OPFS mock; migration fixtures.
- **ML seam:** InferenceHost protocol tested against MockHost (checkpoint commits, cancellation, progress) — the donor's lesson that the riskiest layer had zero tests, answered structurally; one tagged-slow CI lane runs real whisper-tiny WASM on a 30s fixture.
- **Behavior (Playwright):** port the donor's 11, add: resume-across-format, reload-mid-transcription-resumes-from-checkpoint, zero-egress-without-consent (request interception), review serving flow, offline install.
- **Budgets & conformance ports:** gzipped shell JS ≤300KB pre-ML (ML lazily chunked), measured in CI (C3); token single-source lint (C1); glyph cmap coverage (C7); 320dp/3× a11y sweep (C5); visual-loop screenshots at 360/768/1280.

## 16. Build phases

- **P0 (wk 1–2) Bench:** repo, Vite/TS/Vitest/Playwright, tokens, store+migrations, spine model, port rebuild's 7 modules + 108 tests.
- **P1 (wk 3–4) Reader:** RSVP/parafoveal/scroll, TOC/minimap/page panel/context strip/sentinels, positions store, Shelf, EPUB/PDF+OCR/TXT/URL/Gutenberg intake, share/deep-link. Installable PWA.
- **P2 (wk 5–6) Garden:** study engine verbatim + property tests, .ohcourse parser, espalier map, 4 item UIs, revlog, FSRS opt-in, Anki CSV+apkg, OHBK + legacy imports, profiles + parent PIN.
- **P3 (wk 7–9) Kiln:** download engine, model registry, InferenceHost, **multilingual checkpointed transcription** + VAD + timing sync, audio bar + episode caching, feeds/river/auto-download. **← v0.1, first delicious release: the friend-studies-their-podcast-in-its-language story works end to end.**
- **P4 (wk 10–11) Voices:** translation strip (opus-mt default, NLLB opt-in, next-N prefetch), streaming TTS (Kokoro/Piper/Web Speech), synthesis cache.
- **P5 (wk 12–13) Discourse:** Brain providers, distillation pipeline + review screen, discourse moments, .ohcourse 1.1.
- **P6 (wk 14) Ship:** budgets, a11y sweep, storage panel, shell APK versionCode 4, landing card, doc spine (VISION/AGENTS/Diátaxis/ADRs/yellow-paper for the spine+checkpoint invariants), optional prefs bridge.
- **Post-1.0:** Tauri + sidecars, stove v1.1 (server CORS/PNA), FSRS per-user optimizer.

## Feature coverage
### Covered
- ohPrimer: Classic RSVP (ORP pivot, punctuation pacing, long-word shrink)
- ohPrimer: Parafoveal ticker mode (Gaussian fade, sigma/window sliders)
- ohPrimer: Scroll mode (windowed 800 words, dimming, figure images, tap-seek)
- ohPrimer: Speak mode — now streaming per-sentence (Kokoro q8 / Piper / Web Speech API fallback) instead of whole-doc-first synthesis
- ohPrimer: Playback engine (WPM 100–1500, wake lock, session recording)
- ohPrimer: All seek surfaces (tap zones, swipes, keys, scrub, transport)
- ohPrimer: Sentinel segments (tables/code/figures pause + modal + always-skip)
- ohPrimer: Chapter cards + TOC drawer (EPUB nav/NCX + synthesized)
- ohPrimer: Page panel + canvas minimap
- ohPrimer: Context strip
- ohPrimer: Translation strip — per-span, cached in its own store, next-N prefetch; opus-mt default + NLLB-200 opt-in (full 200 langs vs donor's 22-lang UI)
- ohPrimer: Whisper transcription — now MULTILINGUAL (tiny/base/small/large-v3-turbo) with language picker, auto-detect, built-in translate task, VAD, checkpointed+resumable
- ohPrimer: Podcast audio bar (skips, 6 speeds, chapters JSON+PSC, offline toggle)
- ohPrimer: Episode offline caching (now profile-stamped, guid populated, in delete cascade — three donor bugs fixed)
- ohPrimer: Feed subscriptions + auto-discovery (RSS2/Atom/Media-RSS)
- ohPrimer: Feed refresh hygiene (conditional GET, Retry-After, breaker, PTR)
- ohPrimer: Auto-download queue (metered + quota aware)
- ohPrimer: River view (reverse-chron, filters, read tracking)
- ohPrimer: Library screen (search, 5 sorts, filters, pin/rename/delete)
- ohPrimer: Bulk/folder import
- ohPrimer: EPUB parsing (JSZip, TOC, figures, front-matter skip)
- ohPrimer: PDF parsing + Tesseract OCR fallback (lazy chunk)
- ohPrimer: Plain-text heuristics + tokenizer (ported with rebuild tests)
- ohPrimer: URL article reader (readability extraction, feed-XML detect)
- ohPrimer: Gutenberg browser (Gutendex + boilerplate strip)
- ohPrimer: Podcast directory search (iTunes)
- ohPrimer: .ohcourse import (now into the REAL typed study engine, not flattened two-sided cards)
- ohPrimer: AI content generation (topic/level/length via Brain)
- ohPrimer: Extract-to-card flow (drag-select focus span, V vocab flag) — now typed items with span anchors + context deep-link
- ohPrimer: SM-2 review queue with interval previews (behind Scheduler seam)
- ohPrimer: Two-sided cards (answer-not-in-DOM, cloze blur)
- ohPrimer: Review stats (streak, retention, due badge) — now backed by a real revlog
- ohPrimer: Anki CSV export
- ohPrimer: AI review assists (explain/define/paraphrase, make-cloze)
- ohPrimer: AI comprehension check (+ generation-effect prompts)
- ohPrimer: BYOK providers (Anthropic direct + OpenAI-compatible; local-endpoint consent exemption; test-connection)
- ohPrimer: Consent-gated egress chokepoint + metered warnings + egress ledger screen
- ohPrimer: SSRF/URL safety + size caps (comms module ported near-verbatim)
- ohPrimer: Multi-profile (word PIDs, scoped everything, cascade delete now includes episodes)
- ohPrimer: Parent dashboard + salted-SHA-256 PIN
- ohPrimer: Reading stats bar
- ohPrimer: Backup export/import JSON (legacy ohPrimer JSON import kept; native backup is encrypted OHBK)
- ohPrimer: OPML import/export
- ohPrimer: Reading-list import
- ohPrimer: Share-by-URL + ?url= deep link + PWA share-target (gain)
- ohPrimer: Settings (high contrast, OpenDyslexic, eviction policy, timestamps, voice picker w/ preview, AI provider)
- ohPrimer: Storage panel + eviction (per-bucket breakdown, purge, boot eviction)
- ohPrimer: Theme system (auto/light/dark, OS listener, theme-color sync)
- ohPrimer: Position persistence — now a tiny sibling store (donor's whole-record-rewrite jank fixed)
- ohPrimer: PWA offline shell + persistent-storage request + online/offline toasts
- ohPrimer: ML worker architecture — real module workers, typed protocol, AbortSignal cancel, testable seam
- ohPrimer: Model memory management — platform-aware eviction (desktop holds 2–3 sessions; iOS 1)
- ohPrimer: Model download UX — consent w/ exact sizes, real MB progress, persistent resume card, domovoi-law Range resume + sha-256 verify into OPFS
- ohPrimer: Modal accessibility (focus trap, Escape, restore focus)
- Trellis: SM-2 with monotonic-interval floor — verbatim port + verbatim property tests
- Trellis: Whole-epoch-day UTC time base
- Trellis: Node progress + 7-day mastery threshold
- Trellis: Prerequisite DAG unlock gating + cycle/self/unknown-prereq rejection
- Trellis: Unlock-is-first-exposure-only rule
- Trellis: Study session flow with in-session relearn requeue (cleared inputs)
- Trellis: Four typed recall items (cloze/qa/discrimination/procedure) with hints, sources, rung chips
- Trellis: Auto-grading + suggested-grade (0.5/0.85 thresholds; suggestion only highlights a button)
- Trellis: Cloze key text-ordering
- Trellis: RSVP reader + strippedForRsvp math/code stripping
- Trellis: .ohcourse 1.0 strict/tolerant parser with full rejection matrix, never half-imports
- Trellis: Course repository (bundled index + imported override, corrupt-course-skipped, raw-text cache keying)
- Trellis: Paste-JSON import (+ file picker and share-target — the donor's own fix_direction)
- Trellis: Card repository semantics (malformed-entry skip, corrupt-blob tolerance)
- Trellis: Course map (mastery bar, lock/due chips, presentable-due FAB) — as the espalier visualization
- Trellis: Encrypted .ohbk backup/restore (native espalier domain; reads legacy trellis-domain envelopes; destructive data-before-index restore order; preview/describe)
- Trellis: Silent startup vault snapshot (>7 days → OPFS snapshot)
- Trellis: Anki .apkg export — now on WEB TOO via sqlite-wasm (genanki-faithful, stable sha1 guids, subdecks, MathJax mapping) — exceeds donor
- Trellis: No-remote-fetch markdown/LaTeX rendering (untrusted course content can never GET)
- Trellis: Bundled Kalman-filter starter course
- Trellis: diagramMermaid — parsed AND finally rendered (lazy chunk) — exceeds donor
- Trellis: 132-case invariant test matrix ported (monotonic-Hard and never-relocks properties verbatim)
- NEW (superset): canonical content spine w/ cross-format position; multilingual ASR; checkpointed resumable jobs; revlog; FSRS-6 opt-in; distillation → validated .ohcourse; discourse baked into courses at distill time; ephemera decay; egress ledger; T0 Web Speech read-aloud
### Degraded
- Word-level timestamp sync: sentence-grade audio↔text sync is the guaranteed multilingual baseline (Whisper segment timestamps — this is what the spine needs); word-grade RSVP-follows-audio stays solid for English via whisper-tiny.en timestamped output, but is EXPERIMENTAL for other languages because _timestamped ONNX exports are documented-fragile (broken turbo timestamps #1357, fp16 encoder precision #1590, no streaming word timestamps #1198). Donor shipped word-grade for English only anyway, so nothing regresses — but the multilingual promise is honest: sentences now, words as the exports mature.
- Kokoro voice menu: donor's settings listed ~54 voices; the browser ONNX package actually exposes 28 English (US/GB) voices per the packet. Multilingual read-aloud is covered by Piper (~60MB/voice, dozens of languages) and the free platform Web Speech API, but at lower naturalness than Kokoro's English.
- Household (stove) tier from the BROWSER: not feasible against today's stove server (zero CORS handling; https→http LAN mixed-content). Ship order: OllamaBrain via OpenAI-compatible local endpoint works day one (user sets OLLAMA_ORIGINS); StoveBrain arrives with a stove server v1.1 (CORS + Private-Network-Access headers) and is Chromium-only from the PWA; full-fidelity stove is native in the Tauri desktop phase. The seam is built now; the transport honesty is staged.
- Public CORS proxies: still the only serverless answer for feeds/enclosures without CORS headers (the packet's survey confirms every serverless player hits this). Kept consent-gated with exact third-party naming, plus a self-hosted-proxy setting; structurally removed only on the Tauri surface. Same degradation the donor had — inherited, not worsened, but not solved in a browser.
- iOS background transcription: unchanged platform limit (Safari suspends the whole page when backgrounded). Checkpointing converts 'lost 40 minutes' into 'resumes where it left off', and wake-lock covers foreground — but a locked iPhone still pauses the job. Honest UI copy says so.
### Dropped
- SpeechT5 + CMU-ARCTIC x-vector 'voice clone' presets (~200MB): the model is a generation behind (packet verdict: legacy), English-only, and its 4 preset timbres are gone. The FEATURE it carried — whole-document read-aloud in selectable voices with persistent caching — is kept and improved (streaming start, resumable synthesis cache) via Kokoro q8 (92MB) and Piper; only those four specific voices are lost.
- Dormant encrypted seed-channel cloud sync code (already entry-point-disabled in the donor per its ADR-0007): not resurrected, not ported. File-based encrypted OHBK backup remains the deliberate product answer; the code corpse stays buried.
- The single-file deliverable itself: by assigned shape, dist is a real multi-chunk Vite build. Nothing user-visible is lost (still a static-host PWA, still Parlour-style deploy), but 'one copyable index.html' as an artifact form is intentionally gone.

## Potato story
The potato is a €90 Android phone, 2GB RAM, stock Chrome, prepaid data that comes and goes. **T0 (no ML, day one):** installs the PWA from the landing page (shell budget ≤300KB gz + fonts; a coffee's worth of data), gets the full reader — EPUB/PDF/TXT/paste/URL intake, RSVP/parafoveal/scroll, library, positions, themes, dyslexia font. Read-aloud works via the platform's own Web Speech API (zero download — a genuine gain over ohPrimer). Feeds sync when there's signal: conditional GETs are tiny, the river is reverse-chron, episodes STREAM via <audio> without any proxy, and wifi sessions auto-download the next N episodes for the bus. The full study engine runs: import a .ohcourse someone in the household distilled (share-target, file, or paste), and because discourse is baked into the course file at distill time, the potato student gets Socratic follow-ups, explain-back rubrics, and misconception distractors with ZERO runtime inference. SM-2, DAG gating, Anki export, encrypted OHBK backup — all local, all offline. **T1 (WASM, if they're patient):** whisper-tiny multilingual int8 is a 41MB one-time download (consent names the size, Range-resumes across dropped connections); transcribing a 40-minute episode at WASM speed is a plug-it-in, screen-on job — but it's checkpointed every 30 seconds, the partial transcript is readable immediately, and an interruption resumes instead of restarting. One opus-mt pair (~110MB) gives their study language; a 60MB Piper voice reads it aloud. **T2:** this phone has no WebGPU — honestly out of reach; the tier ladder says so in the UI instead of pretending. **T3:** if anyone in the family runs Ollama or the stove on a desktop, the phone's Brain features (distill this episode, grade my explanation) light up over LAN with nothing leaving the house — and until then, every Brain button is simply absent, not broken.

## ML plan
All models Apache-2.0/MIT and UNGATED (no token walls in a no-account product — the packet's licensing survey is why Qwen, not Gemma/Llama). Runtime: @huggingface/transformers v4 (Feb 2026 rewritten C++ WebGPU runtime; packet: target v4 not v3), files pinned by URL+sha-256 in a vendored registry, downloaded by the domovoi-law engine into OPFS, transformers pointed at that cache. WASM threads unlocked on GH Pages via SW-injected COOP/COEP (credentialless). whisper.cpp-WASM is explicitly NOT the primary path (packet verdict: 2–3× realtime CPU, ≤small, no browser GPU — transformers.js wins); it returns as a NATIVE Tauri sidecar at T3-desktop. — **T0:** no models. Web Speech API TTS (platform, free); Chrome's built-in Translator API used as progressive enhancement where present (desktop Chromium only — never a foundation, per packet). — **T1 (WASM, any modern browser):** ASR whisper-tiny multilingual int8 ~41MB (default) or whisper-base int8 ~77MB (onnx-community trees; int8 below small because q4 decoders are LARGER than int8 there — packet); Silero VAD ~2MB pre-pass (hallucination suppression per 'Careless Whisper'); chunk 30s/stride 5s, language + task:'translate' exposed; translation opus-mt per-pair int8 ~110MB/direction (packet sizing); TTS Piper WASM ~60MB/voice multilingual 3–5× realtime CPU. No local LLM at T1 — Brain absent or remote. — **T2 (WebGPU — default-on in all major browsers incl. Safari 26/iOS 26 per packet):** ASR whisper-small int8 ~248MB default upgrade, whisper-large-v3-turbo q4f16 ~563MB opt-in (encoder kept int8/fp32 per issue #1590); word-level timing via _timestamped exports flagged experimental (#1357/#1198); translation NLLB-200-distilled-600M ~800MB opt-in for long-tail languages (packet: 2–5s/sentence — prefetch next-N spans in the worker); TTS Kokoro-82M q8 92.4MB (28 EN voices, best-in-class for size); LLM utility tier Qwen2.5-0.5B-Instruct q8 ~500MB via wllama V3 (OPFS streaming, 512MB splits, WebGPU) for make-cloze/keyword-grade/short follow-ups; LLM discourse tier Qwen3-1.7B (~1.1GB) or 4B (~2.3GB) q4f16 via WebLLM prebuilt MLC weights on strong desktops (WebLLM: fastest in-browser, but lags new architectures — pinned versions, wllama as the durable fallback). — **T3 (household/native):** OllamaBrain (OpenAI-compatible LAN endpoint, egress-consent-exempt, works day one), BYOK Anthropic direct-browser (donor precedent), StoveBrain per the frozen stove protocol (HKDF info openhearth.domovoi.stove.v1, ChaCha20-Poly1305 via @noble/ciphers — crypto trivially portable per packet; browser transport gated on stove server v1.1 adding CORS+PNA headers, Chromium-only from https; full-fidelity native in Tauri, plus whisper.cpp/llama.cpp sidecars for big-model ASR/LLM without browser memory ceilings). Scheduler ML: ts-fsrs (FSRS-6, MIT, default parameters ship; per-user optimizer is a separate package, post-1.0).

## Risks
- Scope: this unifies two shipped apps and adds an ML rebuild — the honest mitigation is the phase gate at P3 (v0.1 ships reader+study+transcription; translation/TTS/distillation follow), but a 14-week single-artisan estimate has real variance.
- Word-level multilingual timing rides fragile _timestamped ONNX exports (#1357, #1590, #1198) — the design survives on sentence-grade sync, but the 'RSVP cursor rides the podcast' delight is English-first until upstream stabilizes.
- iOS storage: Safari's 7-day script-storage eviction can vaporize a library in a browser tab; install-to-home-screen is the mitigation (separate usage counter per packet) and the UI must actively push it — a user who ignores it can still lose data to whole-origin eviction.
- COOP/COEP-via-service-worker (coi-serviceworker technique) is a hack: first-visit reload, and any future browser tightening could drop WASM threads on GH Pages — WebGPU paths are unaffected, but T1 potato transcription speed depends on it.
- Distillation quality is unbounded work: the strict-parser gate guarantees VALIDITY of LLM-authored courses, not pedagogical quality; the review screen keeps a human in the loop, but tuning prompts per source type will consume post-1.0 attention indefinitely.
- The install-base upgrade is a data cliff: the WebView shell (versionCode 4) replaces Flutter Trellis in place, and SharedPreferences survive on disk but are unreadable from the PWA — users who never exported .ohbk lose SRS state unless the optional shell prefs-bridge ships; must be decided (and tested) before the APK goes out, against the fleet's no-backwards-compat-theater law.
- Browser memory ceilings on cheap phones: even with streaming decode and chunked inference, a 2GB device running whisper-base + a big episode can OOM the tab; the tier prober must right-size defaults aggressively (tiny, not base) and the job engine must treat tab death as a normal resume case.
- Public CORS proxies remain a third-party dependency for no-CORS feeds — consent-gated and named, but rate limits and outages will still cause intermittent feed failures until the Tauri surface or a household proxy exists.
- wllama/WebLLM churn: in-browser LLM runtimes move fast and lag new model architectures (packet: Qwen3.5 unsupported in WebLLM); pinning versions + keeping the Brain seam provider-agnostic contains this, but local-LLM discourse quality will trail the state of the art by months.
- Suite-level risk: transformers.js v4 is three months old — a rewritten runtime will have undiscovered regressions (the fp16 encoder bug is the known example); the MockHost seam plus a real-model CI smoke lane is the detection net, but some breakage will only surface on user hardware.

## Build cost
Phased, one artisan + AI agents, honest: P0 bench+spine (2 wks, rebuild's 108 tests ported), P1 reader+intake (2 wks), P2 study engine+courses+backup (2 wks — mostly verbatim ports with existing test matrices), P3 ML runtime+downloads+checkpointed multilingual transcription+feeds (3 wks — the genuinely new, riskiest engineering) → **first delicious release (v0.1) at ~9 weeks**: the canonical podcast-language-learner story works, ≥450 unit + ≥25 behavior tests. Then P4 translation+TTS (2 wks), P5 Brain+distillation+discourse (2 wks), P6 ship polish+shell APK+docs spine (1 wk) → **feature-superset 1.0 at ~14 weeks**. Post-1.0 (not in this cost): Tauri desktop + native sidecars (~2 wks), stove server v1.1 (~3 days in the domovoi repo), FSRS per-user optimizer. Variance is front-loaded in P3 (chunked decode across Safari/Chrome and transformers v4 maturity); everything before it is porting proven code with proven tests, which is why the phases are ordered that way.
