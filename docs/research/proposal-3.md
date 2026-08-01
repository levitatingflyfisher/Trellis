# Grist & Trellis — two surfaces, one format (.ohcourse 2.0). Grist is the web studio (intake, feeds, reading, ML, distillation); Trellis, already shipped, stays the sole study surface. Working title: PrimingTrellis.

**Stack:** Grist: TypeScript + Vite PWA (transformers.js v4, wllama, Piper-WASM/kokoro-js, OPFS + IndexedDB, @noble/ciphers for OHBK) + Parlour-style WebView shell APK. Trellis: the existing Flutter/Riverpod app (183 tests, ships as-is) + a bounded delta (domovoi Brain, schema 2.0 reader, share-target). ohcourse-spec: JSON Schema 2020-12 + Node `ohcourse validate` CLI + shared conformance corpus vendored into both CIs.

## Architecture
# Grist & Trellis — ADR-0006 reborn, with the failure surgically removed

## 0. Why ADR-0006 failed, precisely — and what is different now

ADR-0006's own text names the disease: *"Both read the same `.ohcourse` format **and run the same retrieval loop**."* The lockstep duty that killed it was never JSON parsing — it was two implementations of SM-2, two review queues, two card renderers, two answers to "where does this feature go?". ADR-0008 paid for that with the whole reading engine ("dropped, not ported").

This design removes the duplication **by role, not by discipline**:

| | Grist (web studio) | Trellis (Flutter) |
|---|---|---|
| .ohcourse | **writes** (and re-writes: revisions) | **reads** (only reader — ADR-0008 stands) |
| Scheduler / recall UI / mastery / DAG | **none — zero lines** | sole owner (SM-2 + monotonic floor, 4 item types, unlock law) |
| Reading engine / feeds / ML | sole owner | none (RSVP intake of course passages only, as today) |
| Study state | never writes; may later read `.ohbk` read-only | sole owner |

The dangerous question now has a typed answer: *does the change alter what a course file contains?* → Grist + spec repo. *Does it alter how a course is studied?* → Trellis. There is no third case, because no semantics are implemented twice. ohPrimer's in-browser SM-2 is **deliberately not ported** — that drop is the purchase price of the seam, and it is cheap because Trellis's engine is strictly better (typed items, DAG, monotonic floor, 183 tests).

### The three seam mechanisms (what makes it cheap this time)

1. **One-way flow, as law.** `.ohcourse` flows Grist → Trellis only. Trellis never emits course files; Grist never holds SRS state. No bidirectional format = no negotiation = no drift pressure. (One future, read-only exception is flagged in §6: Grist may *import* a Trellis `.ohbk` to paint mastery over source text. It is read-only, a frozen wire format with a JS-portable spec, and can be cut without touching the seam.)
2. **A neutral referee repo: `ohcourse-spec`.** Contains: (a) JSON Schema for 2.0 (evolving Trellis's existing `schema/ohcourse.schema.json`, draft-07 → 2020-12); (b) the prose spec; (c) a Node **`ohcourse validate` CLI** that re-implements Trellis's full semantic rejection matrix (unknown/self/cyclic prereqs, per-type required fields, version gate) — not just shape; (d) the **conformance corpus**: `corpus/valid/*.json` with canonical-parse golden snapshots, `corpus/invalid/*.json` with expected error codes, `corpus/v1/*.json` (today's files, forever accepted), and `corpus/update/*` pairs `(rev N, rev N+1, expected-SRS-carryover map)`. Neither app is the reference implementation; **the corpus is**. Both repos vendor it at a pinned sha; Trellis CI must accept/reject exactly per corpus; Grist CI must (i) pass every emitted golden through `ohcourse validate` and (ii) run an end-to-end seam canary: fixture source → FakeRuntime distill → emitted file → validate. A schema bump is a deliberate paired-PR event; the validate CLI fails on unknown versions in both CIs, so a lazy bump cannot ship.
3. **Asymmetric capability + additive schema.** Trellis only needs a reader, and its existing parser law ("tolerant of optional, strict about required", unknown top-level ignored — ADR-0003) means Grist can enrich files (anchors, alignment, translations) without breaking it. The strict `schemaVersion` gate stays: 2.0 requires a deliberate Trellis parser update, exactly once.

### .ohcourse 2.0 (additive deltas over 1.0)
- `schemaVersion: "2.0"`; 1.0 files remain accepted by Trellis forever (corpus-enforced).
- `revision: int` (monotonic per course `id`) — the **update channel**. Trellis update law (corpus-tested): re-import same `id` with higher revision → content replaced atomically, SRS state preserved by `itemId`; an item with `supersedes: ["oldId"]` inherits the superseded item's card; state for removed items is retained orphaned (restorable). Never half-imports.
- Per-node/per-item `source: {workId, span: [sentStart, sentEnd], title?, url?}` — **spine anchors**, the position-continuity carrier (§2).
- Per-node optional `layers: {audio: {url, durationMs}, alignment: [[sentIdx,startMs,endMs],…], translations: {"<bcp47>": [perSentence…]}}` — how a distilled podcast course carries its transcript/timing/translation to any device, including potatoes.
- `provenance.origin: {tool:"grist", version, modelIds[]}` — honest ML provenance.
- Optional bundle form `.ohcoursepack` (zip: course.json + media) — Grist emits; Trellis reads JSON-only at first (degraded, phased).

## 1. Content spine (Grist's core data model)

Every source — podcast episode, article, EPUB chapter, feed item, pasted text, transcript — normalizes to a **Work**:

```
Work { workId: sha256(canonicalText), meta, blocks[] }
Block { kind: text|code|table|figure|heading, sentences[] }   // sentinels preserved
Sentence { ord, text, tokens[] }                               // segmented once, stable ordinals
Layers (per Work, all optional, independently present):
  audio:        MediaRef (OPFS blob | URL) + AlignmentTable [sentOrd → (startMs,endMs)] + wordTimings?
  translation:  per-language per-sentence strings (cached incrementally)
  ledger:       per-profile word familiarity (new|learning|known)   // LingQ mechanic, local
Position { workId, sentOrd, tokenIdx?, layer }                 // THE bead — ~60 bytes
```

`Position` is its own tiny IndexedDB store (fixing ohPrimer's rewrite-the-whole-book-record-on-autosave jank, index.html:3319). Every reader mode (RSVP, parafoveal, scroll, speak, podcast bar) reads and writes the same bead. `mediaTimeMs` is always *derived* from `sentOrd` via the alignment table and vice-versa — time is never a second source of truth.

## 2. Position continuity — solved where it matters, conceded where it would recreate ADR-0006

**Solved outright — the canonical scenario.** "Stop listening in the car, resume reading at the same sentence, possibly in another language" happens entirely **inside Grist on one spine**: listening writes the bead via alignment; opening the text (or a translation layer) reads the same bead. One codebase, zero seam crossing, sentence-level guaranteed (word-level when timings are good, §4). This is not luck; it is the design placing *all* consumption surfaces on one side of the seam.

**Solved across the seam, statically.** Anchors are *data carried by the file*, so no runtime channel is needed:
- Trellis → Grist: every node/item shows "read the source" → deep link `grist/#/w/<workId>/s/<sentOrd>` (from the embedded `source` anchor). One tap from a flashcard to the exact sentence of the podcast, audio cued.
- Grist → Trellis: when a Work has a distilled course, the reading view shows a **lattice margin** — the nodes anchored to the passage you're on, with "study this" deep-linking into Trellis (Android app link with courseId/nodeId).

**Solved across devices, manually.** The bead is ~60 bytes → a **hand-off token** (QR / share URL): car phone → home desktop, no server, no account.

**Conceded, deliberately.** (1) *Live* cross-surface position: Trellis's intake-reading offset inside a node does not stream back to Grist, and Grist's bead does not appear inside Trellis. Building that channel is precisely the standing tax that killed ADR-0006; the anchors above make the hop one tap instead. (2) Automatic cross-device sync: no server, so no silent sync; the QR token is the honest local-first answer. Judges should score this as a trade made with open eyes: ADR-0006 wanted "study anywhere" to be seamless and paid with the whole product; we buy 95% of the experience with 0% of the coupling.

## 3. Grist module map (TypeScript, Vite; pure modules + thin UI)

- `spine/` — Work/Sentence/Layers/Position, segmentation, anchor math. Pure, heavily unit-tested.
- `intake/` — EPUB (JSZip+TOC/NCX, figures, front-matter skip), PDF (pdf.js columns/footnotes + Tesseract OCR fallback), TXT/MD heuristics, URL readability extraction, Gutenberg (Gutendex), paste, reading-list, bulk/folder — **ported from ohPrimer via the rebuild's proven method** (verbatim extraction + issue-ID regression tests; rebuild/ already has 108 node tests over utils/state/privacy/tokenizer/partial parsers/comms).
- `comms/` — the battle-designed 40-comms.js as-is: SSRF guard, direct-first 5s timeout, consent-gated public-proxy fallback naming third parties, 25MB/300MB caps enforced mid-stream, ETag/304/Retry-After, background refresh never prompts. Plus: optional self-hosted-proxy setting; batch refresh through one proxy session.
- `feeds/` — RSS/Atom/podcast parse, auto-discovery, OPML in/out, iTunes directory, conditional GET + breaker, auto-download queue (metered/quota aware), **river: strictly reverse-chronological, no ranking code path exists**.
- `reader/` — RSVP (ORP pivot), parafoveal, scroll, speak; TOC drawer, chapter cards, sentinels, page panel + minimap, context strip, translation strip, podcast audio bar (skips, 6 speeds, chapters JSON+PSC, offline toggle), tap-word audio seek, wake lock, stats.
- `mill/` — the ML **job system**: persistent job records, checkpoints, honest ETA; tasks transcribe/align/translate/tts (see §4). Workers only; sticky-fallback flags replaced by retry-with-cooldown.
- `models/` — registry (ids + exact MB), **download engine implementing the domovoi laws in TS**: fetch + `Range` resume from OPFS `.part` length; 416 or 200-on-resume ⇒ discard and restart; cold streams; progress `(received, total?)`; cancel keeps the partial; **completion IS the caller's `promote`** (sha-256 verify + atomic OPFS rename). Weights live in OPFS (owned, `persist()`-ed), never the evictable browser cache; transformers.js pointed at the local store (v3+ custom cache). A persistent resume card in the UI. Runtime detection: WebGPU → T2 paths, else WASM.
- `brain/` — `interface Brain { complete(prompt): Promise<string> }` (domovoi's seam verbatim), impls: `NoBrain` (graceful absence), `ByokAnthropicBrain` (direct browser, donor precedent), `OpenAiCompatBrain` (Ollama/LM Studio/OpenRouter; localhost skips egress consent), `WllamaBrain` (T2 local), `StoveBrain` (§5 T3).
- `distill/` — source → typed `.ohcourse` 2.0. Productizes the `trellis-author` skill: DAG builder, Matuschak-property item prompts (focused/precise/consistent/tractable/effortful; generation-effect items), chapter-append revisions, and the **Commonplace course**: extracts/vocab captures maintained as an auto-revisioned personal course. **Every Brain output must pass the embedded validate library before a file is written — fail closed; the LLM is never trusted into the seam.**
- `capture/` — extract tray (tap/drag span picking, swipe-up), vocab flag, **word ledger** (per-profile new/learning/known painted over all text; tap-to-translate creates a context-carrying extract — LingQ/Readlang mechanics, fully local). **No scheduler. No review queue.**
- `library/` — search/sorts/filters/pin, source lines, storage panel (per-feed audio breakdown, quota bar, purge), boot eviction: **ephemera decay by default (episodes/articles by keepN/days), works and courses persist**.
- `profiles/` — multi-profile (word-PIDs), parent dashboard + salted-SHA-256 PIN, per-profile prefs/feeds/consents/ledger. Episode/clone records stamped with profileIdx and included in delete cascade (fixes donor orphan jank).
- `backup/` — OHBK v2 in JS (`@noble/ciphers` ChaCha20-Poly1305; HKDF via WebCrypto), appDomain `grist`: positions, library metadata, extracts, ledger, feeds, consents, distill provenance. Media/models excluded (re-acquirable). Legacy ohPrimer JSON import supported once.
- `ui/` — ohStyle `tokens.css` direct; screens/modals; the modal-a11y focus-trap pattern ported; OpenDyslexic/high-contrast prefs.

**Storage:** IndexedDB (works-meta, spine text, positions, jobs, extracts, ledger, feeds) + OPFS (episode audio, PCM scratch, model weights, TTS cache) + localStorage (prefs/consents). `navigator.storage.persist()` at boot; install prompt on iOS (the 7-day-eviction mitigation per the packet).

## 4. The mill — reliability engineering (the donor's two worst wounds, closed by design)

**Transcription is a checkpointed, resumable job — never a promise in RAM:**
1. Enclosure streams to an OPFS blob via `comms` (never buffered; donor buffered 300MB in RAM).
2. Decode to 16kHz mono PCM i16 written to OPFS (~115MB/hr — disk, not heap) via WebCodecs `AudioDecoder` streaming; Safari fallback `decodeAudioData` with an honest per-file duration cap.
3. **VAD pass** (Silero-VAD ONNX, ~2MB) → speech windows; suppresses Whisper's silence hallucination (~1% fabricated phrases, packet: arXiv 2402.08021).
4. Worker transcribes window-by-window (30s/5s stride — the canonical recipe) with multilingual Whisper, `language` hint or auto-detect, `task: transcribe|translate`; **no timeout on inference** (watchdog guards model *load* only — the donor's 120s default timeout killed every real podcast and stampeded work back onto the main thread).
5. **Checkpoint per window** appended to the job record; a killed tab resumes at `lastWindow+1`, never restarts. The partial transcript is readable *during* the job (incremental spine append). ETA from the measured realtime factor, displayed honestly.
6. Completion: sentence segmentation + alignment table; detected language stamped on the Work (donor hardcoded `eng_Latn`).

**Alignment contract:** sentence-level timing is the *guaranteed* floor (Whisper segment timestamps are robust); word-level timings are best-effort via the `_timestamped` ONNX exports, which the packet documents as fragile (#1357 broken turbo timestamps, #1590 fp16-encoder precision — we run encoders int8/fp32, never fp16). Tap-word-to-seek degrades gracefully to tap-sentence.

**Model lifecycle:** platform-aware residency (desktop holds 2 models; iOS keeps the donor's one-resident law), retry-with-cooldown instead of sticky session-long fallback flags, per-file MB progress with cumulative totals, real cancel (AbortController — v4 has it; the donor's v2 didn't).

## 5. Freedom-of-compute ladder (see ml_plan for the exact model table)

- **T0** — no ML, full product minus generation (see potato_story). Crucially, **the .ohcourse file is the potato tier's ML delivery vehicle**: `layers` carry transcript + alignment + translations produced on someone else's T2/T3, so a cheap phone follows a synced transcript of a foreign-language podcast with zero local inference.
- **T1 (WASM)** — whisper-tiny/base multilingual, opus-mt pair translation, Piper TTS. Checkpointing makes slow honest: a 40-min episode at ~0.5–1× realtime is an overnight job that survives anything.
- **T2 (WebGPU)** — whisper-small default / large-v3-turbo opt-in, NLLB long-tail opt-in, Kokoro EN TTS, wllama Qwen for local distill-assist.
- **T3 (household/BYOK)** — `StoveBrain` + **Stove Studio mode**: the packet proves a *browser* stove client is infeasible today (no CORS on the Dart server; https-PWA can't fetch http:// LAN). Fix at the root: the domovoi stove desktop gains static hosting and **serves the Grist bundle itself** over LAN — same-origin kills both blockers at once, protocol v1 frames unchanged. Until that ships: BYOK Anthropic (works today, donor precedent) and OpenAI-compatible localhost (Ollama needs `OLLAMA_ORIGINS`). Stove-side transcription (faster-whisper on the desktop, results over the ask channel) needs a frame-size protocol extension — explicitly phased, not promised.

## 6. Study engine — Trellis reproduced (it ships), then exceeded

**Reproduced by not rebuilding:** the scheduler (SM-2, EF clamp ≥1.3, lapse reset, monotonic floor `max(newInterval, oldInterval+1)`), epoch-day UTC time base, 4 typed items, DAG unlock with unlock-is-first-exposure-only, grading suggestions, cloze key text-ordering, `.apkg` export, OHBK backup, 183 tests — all remain exactly the shipped code. The crown-jewel property tests (monotonic-growth-under-repeated-Hard, unlocked-never-relocks) stand untouched.

**The Trellis delta (bounded, ~6 features):**
1. **Schema 2.0 reader + update law** (+ corpus conformance suite in `flutter_test`). Renders `layers.translations` as an optional per-paragraph strip; ignores `audio` initially (degraded, honest).
2. **File picker + Android share-target** for `.ohcourse`/`.ohcoursepack` — kills paste-only import and makes the Grist→Trellis hop one share-sheet tap.
3. **Construction & discourse via domovoi Brain** (pure Dart, already powers Reckon): post-reveal Socratic follow-up, explain-back with model-graded feedback, elaborative-interrogation prompts ("why does this follow?"). **Advisory forever: the model highlights a suggested grade; the learner's self-rating drives SM-2** (Reckon's model-never-decides law). Graceful absence: keyword-coverage suggestion (already shipped) is the floor. Consequence stated plainly: Trellis gains the INTERNET permission — fenced by a C4-style exact-permission test, a WeatherGlass-style "What leaves your device" screen, consent-gated egress, local-only (stove/localhost) never touching WAN.
4. **Multi-profile** (family focus; ohPrimer had it, Trellis didn't): profile-prefixed stores, backup envelope v2 enumerating profiles.
5. **Study-ahead** (the 144-empty-days fix): preview the next node's intake + ungraded self-checks without granting mastery — effort gets work on due-empty days, the pedagogy keeps its gate.
6. **Storage honesty + revlog**: course bodies move out of SharedPreferences into files (the VISION "Near" decision, taken); cards stay in prefs; backup serializer read-surface updated. An append-only revlog starts recording now — it costs nothing and keeps FSRS honestly open (packet: FSRS-6 beats SM-2 in 99.6% of collections, but the 20–30% figure is simulation, not RCT; we do **not** swap a 183-test scheduler on a simulation — the seam to swap behind is already there).

`.ohbk` read-only import into Grist (mastery painted over source text, "your study left off here" hints) is a flagged later phase: read-only, frozen format, cuttable.

## 7. Attention sovereignty — by structure, verifiable by grep

- River is reverse-chronological **only**; no ranking function exists to test, and a conformance test asserts no engagement-ordering code path.
- Ephemera decay by default (episodes/articles evict by policy); works and courses persist until the user deletes them.
- **Bounded asks** (Zvi's Get Compact): review sessions have a set size and a natural end screen; reading sessions end at chapter cards; nothing auto-plays the next episode.
- No streaks-as-hostage, no repair purchases, no leaderboards, no mascot guilt. Stats are passive records. **Zero notifications** — the only number that ever summons is the due count, and memory math sets it, not engagement math.
- No telemetry, no accounts; egress only through the consent chokepoint that names the third party.

## 8. Surfaces & beauty

- **Grist**: PWA at `levitatingflyfisher.github.io/Grist/` (Parlour deploy model: `npm test && npm run build`, committed output is the site) + Parlour-style WebView shell APK (debug-keystore, `releases/latest/download/Grist.apk`) whose extra duty is registering as an `.ohcourse` share-source; WebGPU-in-WebView is uncertain, so the shell is the T0/T1 convenience surface and Chrome the T2 one (stated, not hidden). Landing gains one `APPS` entry.
- **Trellis**: existing APK + PWA, unchanged distribution.
- **Signature UI — the Warp**: ohStyle linen/hearth, Lora headings, print-like measure. Every Work wears a thin vertical loom ribbon: one thread per layer (text, audio, each translation), chapter marks as crossings, and a single copper **bead** — your position — that slides *across* threads when you switch format and never jumps *along* them. The bead is the product thesis drawn as one glyph. Grist's mill iconography (hopper → stones → flour sack for intake → distill → course) gives the studio a memorable, warm identity; Trellis keeps its lattice.

## 9. Test strategy

- **Spec repo**: corpus + validate CLI, self-tested; corpus grows with every seam bug (regression-by-corpus).
- **Grist**: pure-module vitest/node:test (port the 108 rebuild tests + its verbatim-extraction/regression-ID method); **the entire ML layer sits behind `MlRuntime`/`Brain` interfaces with deterministic fakes** — mill checkpoint/resume/ETA logic is unit-tested with zero model bytes (the donor's fatal gap — 60-ai had no tests — answered by construction); download engine tested against a local fault-injecting HTTP server (Range/416/200/stall — domovoi's matrix ported); real-model smoke (whisper-tiny on a 10s fixture, transformers.js v4 in Node) on a weekly opt-in CI lane; Playwright behavior tests incl. **kill-tab-mid-transcription-then-resume**; visual-loop screenshots at 320dp/2×; re-pinned fleet values as node scripts: size budgets (C3), glyph coverage (C7 — Lora/Nunito lack ≤/≥), no-network-until-consent as a test.
- **Trellis**: 183 kept + corpus conformance + update-law property tests (revision/supersedes/orphan carryover) + Brain-mock discourse tests + C4 exact-permission pin + goldens.
- **Seam canary** in Grist CI: fixture → FakeRuntime distill → emit → `ohcourse validate` → diff against a committed golden that is *also a corpus member* — the same bytes Trellis CI must accept.

## 10. Build phases

- **P0 (wk 1–2)**: `ohcourse-spec` repo — schema 2.0, validate CLI, corpus seeded from Trellis's current tests + bundled course; Trellis 2.0 reader + update law. *The seam exists before either surface grows.*
- **P1 (wk 3–7)**: Grist core — spine + position store, storage, reader modes ported, intake ported, comms/feeds/river, library, profiles, theme + Warp. **Usable milestone: a beautiful reader/feed app, T0-complete.**
- **P2 (wk 8–12)**: mill + models — download engine, checkpointed multilingual transcription + VAD + alignment, translation (opus-mt/NLLB), TTS (Piper/Kokoro). **Milestone: the language-learner-via-podcast case works for the first time ever.**
- **P3 (wk 13–15)**: distill + Brain tiers + Commonplace + revisions + word ledger + OHBK backup + hand-off QR.
- **P4 (wk 16–18)**: Trellis delta (share-target, discourse, profiles, study-ahead, storage move, revlog).
- **P5 (wk 19–20)**: shells, Stove Studio hosting, storage panels, docs spine (VISION/AGENTS/Diátaxis/ADRs — ADR-0009 supersedes 0008 citing this document's seam laws), landing card.

## Feature coverage
### Covered
- ohPrimer: all four reader modes — classic RSVP (ORP pivot, punctuation pacing), parafoveal ticker (sigma/window sliders), scroll mode (windowed, dimming, tap-seek), speak mode (now Kokoro EN + Piper multilingual)
- ohPrimer: playback engine (WPM 100–1500, wake lock, session recording), all seek surfaces (tap zones, swipes, keys, scrub, transport), sentinel segments, chapter cards + TOC drawer, page panel + minimap, context strip
- ohPrimer: translation strip — upgraded: opus-mt pair (~110MB) default tier + NLLB-200 (22→200 langs) opt-in; per-work per-language cache moved out of the book record into a layer store
- ohPrimer: audio transcription — upgraded: multilingual whisper tiny/base/small/large-v3-turbo with language picker + auto-detect + Whisper translate task (the donor's English-only whisper-tiny.en meant the canonical use case never worked); VAD hallucination suppression; checkpointed/resumable
- ohPrimer: word-timing audio sync — sentence-level guaranteed via alignment table, word-level best-effort via _timestamped exports; tap-to-seek both directions
- ohPrimer: podcast audio bar (skips, 6 speeds, chapters JSON+PSC, offline toggle), episode offline caching (now profile-stamped, in delete cascade — fixes orphan jank), feed subscriptions + auto-discovery, feed refresh hygiene (conditional GET, Retry-After, breaker, PTR), auto-download queue (metered/quota aware), river view (reverse-chron only)
- ohPrimer: library screen (search/sorts/filters/pin), bulk/folder import, EPUB parsing (TOC/NCX, figures, front-matter), PDF + Tesseract OCR fallback, plain-text heuristics, tokenizer, URL article reader (readability extraction, feed detection), Gutenberg browser, iTunes podcast directory
- ohPrimer: .ohcourse import — Trellis is the reader (typed items, DAG); Grist previews courses read-only including mermaid diagrams
- ohPrimer: AI content generation, AI review assists (as Trellis discourse: Socratic/explain-back/make-cloze), AI comprehension check (as ungraded in-reading checkpoint prompts in Grist + graded items in Trellis), BYOK providers (Anthropic direct + OpenAI-compatible incl. localhost), consent-gated egress chokepoint, SSRF/URL safety + size caps (40-comms.js ported with its tests)
- ohPrimer: extract-to-card flow (span picking, vocab flag) → Commonplace course, auto-revisioned, studied in Trellis; plus NEW word ledger (LingQ known/learning/new) and tap-to-translate context capture
- ohPrimer: SM-2 review + two-sided cards + review stats — covered by the strictly stronger Trellis engine (typed recall, DAG, monotonic floor, suggested grades); reading stats bar + parent dashboard + PIN in Grist
- ohPrimer: Anki CSV export (kept in Grist for Commonplace) and Trellis .apkg export (genanki-faithful) both retained
- ohPrimer: multi-profile (now in BOTH surfaces), backup (JSON → OHBK v2 encrypted, legacy JSON import once), OPML in/out, reading-list import, share-by-URL + ?url= deep link, settings (a11y, eviction, voices, AI provider), storage panel + eviction, theme system, position persistence (upgraded: dedicated position store, 60-byte bead), PWA offline shell, modal accessibility pattern
- ohPrimer: ML worker architecture + model memory management + model download UX — all upgraded: job system with checkpoints, platform-aware residency, retry-with-cooldown, owned OPFS download engine (Range resume, sha-256 promote, real AbortController cancel), honest MB/ETA, persistent resume card, no runtime CDN dependency
- Trellis: everything ships as-is — SM-2 with monotonic floor, epoch-day UTC, mastery/progress, DAG gating, unlock-is-first-exposure-only, session flow with in-session relearn, all 4 item types + UIs, auto-grading + suggested grades, cloze key ordering, RSVP intake + stripping, strict/tolerant parser + cycle rejection, course repository, card repository, course map, OHBK backup + startup vault snapshot, .apkg export, no-remote-fetch markdown, bundled Kalman course, all 183 tests incl. the property-test crown jewels
- Trellis jank fixes: file-picker + share-target import (paste-only gone), study-ahead (empty-app problem), course bodies out of SharedPreferences into files, revlog added
- NEW beyond both donors: .ohcourse 2.0 revisions/supersedes update channel, spine anchors + deep links both directions, QR position hand-off, courses carrying transcript/alignment/translation layers to zero-ML devices, checkpointed jobs, VAD, word ledger, discourse study, stove tier
### Degraded
- Review-where-you-read: ohPrimer graded its cards in the same tab as the reader; now the graded loop lives in Trellis — one share-sheet tap + app switch on Android, a file download/upload hop on desktop/iOS web. Grist keeps only ungraded in-flow checkpoint prompts. This is the deliberate price of one scheduler; the hop is engineered down, not hidden.
- Live cross-surface position: no automatic 'Grist bead visible inside Trellis' or vice versa — static anchors + one-tap deep links + QR hand-off instead (see architecture §2 for why the live channel is exactly the ADR-0006 tax).
- Kokoro voices: donor claimed ~54; the browser ONNX package is 28 English-only voices (packet-verified). Multilingual TTS is Piper (~60MB/voice, lower naturalness than Kokoro).
- diagramMermaid: rendered properly in Grist course preview; Trellis still shows formatted source with a copy affordance (native mermaid rendering not yet earned) — donor Trellis never rendered it at all, so this is strictly better but not done.
- .ohcoursepack embedded media in Trellis: Trellis reads the JSON (text + translations) and ignores audio layers initially; audio-synced study stays in Grist until a later Trellis phase.
- iOS/Safari: transcription is foreground-only with wake lock (iOS suspends workers in background — platform fact); decode fallback caps very long episodes; 7-day eviction mitigated by install-to-home-screen, not eliminated.
- Trellis Anki .apkg export remains native-only (dart:io + sqlite3), hidden on web — unchanged donor limitation.
- Trellis zero-network purity: discourse features add the INTERNET permission — fenced by an exact C4-style permission test, consent gate, and a 'What leaves your device' screen; users who never enable a Brain generate zero packets, but the permission line itself is a real change and is stated as one.
### Dropped
- ohPrimer's in-browser SM-2 scheduler/review queue as an implementation: deliberately not ported — one scheduler law (Trellis's). This is the structural drop that makes the seam cheap; the capability is covered, the duplicate code is refused.
- SpeechT5 voice-clone read-aloud (4 CMU-ARCTIC preset voices + per-(book,preset) WAV cache): dropped — a generation behind (packet), English-only, 5–15-min blocking synthesis; replaced by Kokoro (quality, EN) + Piper (multilingual, streaming). The 'clone' framing was never real cloning.
- Dormant encrypted seed-channel sync code: dropped (it was already dead — entry points throw; ADR-0007's file-based OHBK is the answer).
- Runtime esm.sh CDN dependency: dropped by design — transformers.js v4 vendored into the bundle; a CDN outage can no longer brick ML.
- Automatic serverless cross-device sync of positions/library: not built — no server exists to build it on; the QR hand-off token and OHBK files are the local-first answer.
- Stove-tier transcription (phone asks the desktop to run faster-whisper): not in scope — needs a stove protocol frame-size extension; recorded as a horizon, not promised.

## Potato story
The user: a cheap Android phone, stock Chrome, intermittent network, no WebGPU, no patience for 600MB downloads.

T0 (no ML, works today, offline after first load): She opens Grist — a light PWA shell (size-budgeted like Parlour; zero model bytes ever move without consent). She subscribes to her podcast and three blogs (OPML import from her old reader worked). The river is reverse-chronological; nothing is ranked, nothing nags. When she has signal, episodes auto-download within her quota; offline, she reads and listens from cache. She reads an EPUB in scroll mode, speed-reads an article in RSVP (RSVP is potato-native — it's just DOM), extracts a sentence to her Commonplace tray. Crucially: her brother runs the family desktop. He distilled her favorite podcast's episode into a .ohcourse — and the file carries the transcript, sentence-level audio alignment, and a Spanish→English translation layer *inside it*. On her potato, she plays the episode and follows the synced transcript, taps a sentence to replay it, flips to the translation layer — zero local inference; the file was the ML delivery vehicle. She shares the course to Trellis (one share-sheet tap; Trellis APK is a light Flutter app with no network use unless she opts into discourse) and studies the typed recall ladder on the bus. Her position survives: stop listening in the car, open the text at home — same sentence, because both live on one spine in Grist; moving to the family tablet is a QR scan.

T1 (same phone, patient): She consents to whisper-tiny multilingual (41MB, resumable — a dropped connection resumes from the .part, never restarts). Transcribing a 40-minute episode at ~0.5–1× realtime WASM is an honest overnight job: checkpointed every 30-second window, readable while it runs, survives Chrome killing the tab. One opus-mt pair (~110MB) gives her translation for HER language pair; a Piper voice (~60MB) reads articles aloud. No LLM is pretended at this tier.

T2 (a newer phone or any desktop browser): whisper-small (248MB) transcribes at useful speed on WebGPU; Kokoro reads beautifully in English; wllama + Qwen2.5-0.5B drafts cloze items she approves.

T3 (the household): the family desktop runs the stove; in Stove Studio mode it serves Grist itself on the LAN, so her phone's browser gets desktop-class distillation and summaries with nothing leaving the house — or she pastes a BYOK key. The model never runs unprompted at any tier, and at every tier below it, the buttons don't guilt her — they explain the ladder and offer 'import a pack from someone who has it.'

## ML plan
All model/runtime facts below are from the research packet. Runtime: transformers.js v4 (Feb 2026, rewritten C++ WebGPU runtime, browser + Node — enables real-model CI smoke), vendored/pinned — no runtime CDN. Weights in an owned OPFS store via the TS port of the domovoi download laws (Range resume, sha-256 promote); transformers.js pointed at the local cache.

T1 — WASM (any modern browser, single-thread honest):
- ASR: onnx-community/whisper-tiny multilingual int8 ~41MB (default), whisper-base int8 ~77MB (recommended when quota allows). int8/q8 below small — the packet documents q4 decoders LARGER than int8 at these sizes. Pipeline: chunk_length_s 30 / stride 5, language hint or auto, task transcribe|translate (X→EN only, inherited from Whisper). Silero-VAD ONNX (~2MB) pre-pass for hallucination suppression (arXiv 2402.08021).
- MT: Xenova opus-mt per-pair, ~110MB per direction (en-es measured) — the learner installs their pair, not a 600M multitool.
- TTS: Piper WASM, ~60MB/voice, CPU-only, 3–5× realtime, genuinely multilingual (MIT).
- LLM: none advertised (0.5B on WASM is real but miserable; allowed, not promised).

T2 — WebGPU (default-on in all major browsers incl. Safari 26/iOS 26 per packet):
- ASR: whisper-small int8 ~248MB default; whisper-large-v3-turbo q4f16 ~563MB (enc 370 + dec 193) opt-in. Encoders run int8/fp32, never fp16 (precision bug #1590). Word-level timings via _timestamped exports where sound (#1357 fragility) — sentence alignment is the contract, words are garnish.
- MT: NLLB-200-distilled-600M (>800MB, 2–5s/complex sentence) opt-in for long-tail languages; opus-mt remains the default tier. Chrome's built-in Translator API (desktop Chromium only) used as free progressive enhancement, never a foundation.
- TTS: kokoro-js Kokoro-82M q8 92.4MB, 28 EN voices — the quality tier; Piper stays the multilingual tier.
- LLM: wllama V3 (llama.cpp WASM+WebGPU, GGUF 512MB splits, streams from OPFS — chosen over WebLLM because it doesn't pull the whole model through JS memory and rides the GGUF ecosystem) with Qwen2.5-0.5B-Instruct q8 ~500MB (Apache-2.0, UNGATED — the only friction-free family for a no-account FLOSS product; Llama/Gemma are license-gated) scaling to Qwen3-1.7B on strong desktops.

T3 — household/BYOK (the Brain seam, domovoi verbatim):
- StoveBrain: ChaCha20-Poly1305 frames per stove protocol v1 (port 4663, challenge + AAD 'domovoi-stove/v1'|endpoint|challenge); browser-feasible ONLY via Stove Studio mode (stove serves the Grist bundle same-origin — the packet's two blockers, no-CORS and mixed-content, both dissolve). Desktop model = whatever the household runs (Ollama-served Qwen/Llama-class).
- OpenAiCompatBrain: Ollama/LM Studio at localhost (OLLAMA_ORIGINS noted), skips egress consent per donor precedent.
- ByokAnthropicBrain: direct browser API (shipped in ohPrimer; Reckon precedent).
Distillation runs at T2+ or T3; every Brain output is schema-validated fail-closed before touching the seam.

Trellis-side ML: none on-device — discourse rides the same Brain seam (pure Dart, powers Reckon today) to stove/localhost/BYOK; keyword-coverage suggestion is the zero-Brain floor.

## Risks
- Word-level timestamp fragility is real (packet: #1357 broken turbo timestamps, #1862 non-English drift, #1590 fp16 encoder): if _timestamped exports stay unreliable for the learner's language, tap-word-seek degrades to tap-sentence permanently — the design survives (sentence alignment is the contract) but a marquee delight is diminished.
- The Grist→Trellis course hop is one tap only on Android (share-target); on iOS/desktop web it is a file dance. The study loop's friction off-Android is the design's weakest UX seam and could push users to wish for the in-tab review the architecture deliberately refuses.
- Stove Studio requires modifying the domovoi stove server (static hosting + serving context); until it ships, T3 from a phone browser is BYOK-cloud only (packet: no-CORS + mixed-content make a browser stove client infeasible today). If the stove work slips, the 'household compute' story is desktop-localhost only.
- transformers.js v4 is ~6 months old with a rewritten WebGPU runtime; regressions are likely (fp16 precedent). Mitigation: pinned version, weekly real-model smoke lane, WASM path kept green as the permanent fallback — but a bad v4 bug could still force living on WASM speeds for a while.
- Two repos + a spec repo is residual coordination cost: the corpus/validate-CLI/paired-PR protocol makes drift loud, not impossible — a maintainer who force-lands a schema change in one repo recreates ADR-0006 in miniature. The mitigation is CI refusing unknown versions, but discipline is still a dependency.
- Safari/iOS platform ceilings: background suspension (no overnight transcription on iPhone), decodeAudioData fallback memory on very long episodes, 7-day eviction if the user won't install. The potato story is Android-first; iOS potatoes get a genuinely lesser tier and the docs must say so.
- Trellis gains the INTERNET permission for discourse — a values-surface regression risk if the fence (C4 exact-permission test, consent gate, egress screen) is ever weakened; some users will reasonably grieve the grep-clean zero-network APK.
- Browser storage quota churn: model weights + episodes + PCM scratch compete inside one origin quota; Safari can purge despite persist(). Resumable downloads make re-acquisition cheap, but a user near quota will see confusing evictions — the storage panel must be excellent, not adequate.
- Scope: Grist P1+P2 is a serious application (reader port + mill + models). One artisan + agents shipped comparable scope before (sanctuaryAuth fleet, Peckish), but the mill's reliability engineering is the kind of work where estimates slip 2×; the phase plan's usable milestones (P1 reader, P2 transcription) are the pressure valve.
- NLLB-200 at >800MB and 2–5s/sentence may be practically unusable on mid hardware — if opus-mt pair coverage misses a user's language pair, translation quality at T1/T2 has a real gap that only T3 closes.

## Build cost
Phased, one artisan + AI agents (this workshop's proven mode), in artisan-weeks of evening-cadence work: P0 seam (spec repo + corpus + validate CLI + Trellis 2.0 reader) 1.5–2 wks. P1 Grist core (spine, storage, reader + intake ports from the rebuild, feeds/comms, profiles, theme) 4–5 wks — usable T0 reader/feed app ships here. P2 mill + models (download engine, checkpointed multilingual transcription, VAD, alignment, translation, TTS) 4–5 wks — the highest-variance phase (reliability engineering; budget 2× slip here specifically) — the language-learner-via-podcast case works at its end. P3 distill + Brain tiers + Commonplace + revisions + ledger + backup 3 wks. P4 Trellis delta (share-target, discourse, profiles, study-ahead, storage move, revlog) 2–3 wks. P5 shells + Stove Studio hosting + docs spine + landing 2 wks. Total: 17–20 nominal artisan-weeks; 'first delicious release' (end of P3: Grist with working multilingual podcast transcription feeding courses into today's shipped Trellis) at ~12–15 artisan-weeks. At the workshop's observed agent-parallel cadence that is roughly 8–12 calendar weeks, with a real, useful app in hand from P1 onward. Not counted: the stove server extension (~1 wk, lives in domovoi's repo) and ongoing corpus gardening (~hours per schema change, by design).
