# Arbor — the household knowledge garden (app: Arbor; hearth daemon: Rootstock; working name PrimingTrellis)

**Stack:** TypeScript strict pnpm monorepo — vanilla-TS PWA (Vite build, no framework, uhtml-scale templating, ohStyle tokens) + Node ≥20 hearth daemon "Rootstock" (better-sqlite3, transformers.js v4, shipped as single-file executables) + Flutter WebView shell APK with an embedded Dart stove client (domovoi code reuse); crypto via @noble/ciphers + @noble/hashes; ts-fsrs; vitest + fast-check + Playwright.

## Architecture
# Arbor — household-compute-first architecture

## 0. The one idea, and the answer to the shape's question

**The client is structurally complete; the hearth is experientially load-bearing.** Every feature of both donors runs client-side at T0–T2 — no capability is gated on a server existing. But the *promise* of the app ("study anything, any language, any format, effortlessly") is delivered by the **Rootstock**: a daemon on the family desktop that does the heavy ML overnight and turns every phone in the house into a thin, always-ready reading surface. Formula, stated as a design law and enforced by tests:

> **Nothing requires the hearth. Everything heavy prefers it. The hearth never grows a public face.**

That third clause is the exposure-freeze answer made structural: Rootstock binds to the LAN, speaks only the AEAD-framed stove-style protocol keyed by the household BIP39 phrase, and has no cloud, no accounts, no relay. It is exactly "a server nobody else has to trust" — the owner's own phrase, built.

The metaphor system extends Trellis's name: the hearth daemon is the **Rootstock**; pairing a device is **grafting**; shareable pre-computed bundles are **cuttings** (`.ohparcel`); the course map is the **Espalier**; the home screen is the **Morning Basket** (the homeschool ritual — what the stove prepared overnight, plus what's due). Ephemera **mulch** (decay); works **persist**.

## 1. Module map (the monorepo IS the argument)

One study engine, one content spine, one comms layer — tested once, running in three homes (browser worker, Node hearth, and via the APK bridge).

```
arbor/                      pnpm workspace, TypeScript strict, MIT
  packages/
    spine/       Content model: Work, sentence spine, layers, alignment, positions.
    study/       Trellis engine port: sm2.ts (monotonic floor), fsrs.ts (ts-fsrs
                 adapter), grading.ts, progress.ts, parser.ts (.ohcourse 1.0+1.1),
                 revlog fold. The 132 Trellis invariant tests ported verbatim.
    store/       Storage seams: idb adapter (client: IndexedDB + OPFS blobs),
                 sqlite adapter (hearth: better-sqlite3 + CAS blob dir);
                 the op-log, HLC, and merge/fold live here.
    comms/       Port of rebuild/40-comms.js (already tested in the donor):
                 assertSafeFetchUrl SSRF guard, direct-first fetch, consent-gated
                 public-proxy fallback, conditional GET, 25MB/300MB caps,
                 RSS/Atom/OPML/iTunes/Gutendex parsers.
    transfer/    The domovoi download laws in TS: fetch + Range from OPFS .part,
                 416/200-on-resume discard, caller-owned promote (sha256 verify +
                 atomic rename), (received, total?) progress, real AbortController.
    ml/          Engine seam (Transcriber/Translator/Speaker interfaces), the
                 transformers.js v4 engines, chunked-job checkpointing, model
                 manifest (pinned repo+revision+sha per tier).
    hearthwire/  Protocol codec + client + server: domovoi-stove/v1 compatible
                 framing, plus the arbor-hearth/v1 endpoint set (sync, job, blob).
                 ChaCha20-Poly1305 via @noble/ciphers; HKDF/PBKDF2 via
                 @noble/hashes (pure JS — works even in non-secure contexts).
    ohbk/        OHBK v2 reader/writer byte-compatible with sanctuary_auth_core,
                 + "bale" chunking for >10MB backups.
    brain/       Brain seam (complete(prompt, opts)) + NoBrain / WllamaBrain /
                 StoveBrain / ByokBrain; the single user-gesture chokepoint.
    ui/          Reader modes, screens, modals, ohStyle tokens.css, a11y traps.
  apps/
    client/      The PWA → GitHub Pages (fleet landing card, copper button).
    rootstock/   The hearth daemon + its LAN console (console reuses packages/ui).
  (separate repo, fleet convention:)
    ArborShell/  Flutter WebView APK + Dart stove/hearthwire bridge via
                 addJavaScriptChannel — domovoi's Dart client code reused as-is.
```

## 2. Content spine — the canonical representation (hard req 2)

Every source normalizes to a **Work** with a materialized **sentence spine**, and every other layer addresses spine indices. Position is a spine coordinate, so it survives any format switch.

```
Work         { id (uuid), contentHash, kind: article|episode|book|chapter|course|note,
               title, language (BCP-47, detected or declared), provenance
               { sourceUrl?, feedId?, guid?, file? }, createdHlc, pinned, decayClass }
Spine        { workId, segmenterVersion, blocks: [{ kind: prose|heading|code|table|
               figure, sentences: [s0..sN] }], sentences: [{ idx, text, charStart,
               charEnd, tokens }] }   // materialized at ingest, NEVER recomputed —
                                      // layers can never drift from it
Layer        one of:
  audio        { mediaRef (blob hash or stream URL), align: sentenceIdx → [t0,t1],
                 wordAlign?: sentenceIdx → [(w,t0,t1)...], alignQuality: 0..1, engine }
  translation  { targetLang, sentences: [idx → text], engine, modelRev }
  tts          { voiceId, mediaRef, align, engine }   // synthesized read-aloud, cached
Position     { profileId, workId, sentenceIdx, charOffset?, mode, mediaTime?, hlc }
Extract      { id, profileId, workId, sentenceRange, focusSpan?, kind:
               passage|vocab|cloze, cardRef }         // cards carry context forever
```

- **Segmentation is versioned and stored.** A light rule-based segmenter (ported from the donor tokenizer) + `Intl.Segmenter` assist; whatever it emits at ingest is the spine forever (`segmenterVersion` stamped). This kills the "layers drift because ICU changed" failure mode.
- **The car→couch story:** stop listening at audio t=1712s → binary-search `align` → sentenceIdx 214 → Position written. Open the phone in scroll mode → resume at sentence 214. Switch the translation strip to Spanish → sentence 214 of the `translation[es]` layer, because translation is per-sentence against the same spine. This is LingQ's paired text+audio mechanic (packet §1) generalized to N layers.
- **Cuttings (`.ohparcel`):** a zip of {Work, Spine, Layers, optional .ohcourse, manifest with content hashes}. A hearth (or any T2 client) can bake one; a T0 phone imports it over WhatsApp/Files/share-target and gets the full bilingual-karaoke experience with zero local ML. Cuttings are how compute travels to potatoes.

## 3. Storage

**Client:** IndexedDB via a thin typed wrapper (`idb`-scale, no ORM) + OPFS for big bytes.
Stores: `works`, `spines`, `layers` (chunked ≤1MB records), `positions` (**own store** — kills the donor's rewrite-the-whole-book-record-on-autosave jank), `extracts`, `cards`, `revlog` (append-only), `feeds`, `episodes` (**profileIdx + guid stamped on write; profile-delete cascades** — fixes the donor's orphan-blob jank), `profiles`, `jobs`, `oplog`, `settings`. Audio blobs and **model weights in OPFS** (not the evictable browser HTTP cache — fixes silent re-download jank), content-addressed, counted in the storage panel. `navigator.storage.persist()` requested; install-to-home-screen recommended on iOS (packet: installed PWAs escape the 7-day sweep).

**Hearth:** the same logical schema in SQLite (better-sqlite3 — synchronous, mature, WAL) + a content-addressed blob directory. When a Rootstock exists it is the **canonical household library**; client stores become synced replicas plus device-local drafts.

## 4. Sync — fold, don't merge (the elegant part)

Three data classes, three trivial merge strategies (StillLife/sanctuary lineage, simplified):

1. **Immutable, content-addressed:** spines, layers, blobs, courses. Merge = set union.
2. **Append-only:** `revlog` (every review: itemId, grade, hlc, deviceId, uuid) and session stats. Merge = union.
   **Scheduler state is a pure fold over the revlog** — `cardState = fold(scheduler, sortedRevlog)`. Merge two devices = union the logs, replay. Deterministic, commutative (property-tested with fast-check), and it gives Trellis the revlog it never had — which is exactly what the FSRS optimizer eats later (packet §7).
3. **LWW-by-HLC:** positions, prefs, feed subscriptions, work metadata, pin/decay flags.

Sync runs over `arbor-hearth/v1` frames: exchange HLC vectors → ship missing ops → fetch missing blobs by hash (chunked AEAD frames). No hearth → no multi-device sync, and we say so; the fleet-standard `.ohbk` file hop remains (per the no-backwards-compat-theater house rule).

## 5. Study engine — reproduce Trellis, then exceed it (hard reqs 1, 4)

**Reproduced verbatim (the 132 tests are the spec, ported to vitest):**
- SM-2 in whole UTC epoch days; q∈{2,3,4,5}; EF′ clamped ≥1.3; lapse resets + same-session relearn requeue with cleared inputs; success base 1|6|round(i·EF′), hard×0.6/easy×1.3, then the **monotonic floor max(·, old+1)** — the crown-jewel property tests (monotonic-growth-under-repeated-Hard, unlocked-never-relocks) port first.
- Mastery = interval ≥7d; node mastery = fraction; unlock iff all prereqs at 1.0; **lock applies to first exposure only**.
- Four item types with their exact grading: normalized cloze all-blanks, discrimination index equality, keyword-coverage thresholds (≤0→again, <0.5→hard, <0.85→good, else easy), cloze keys in first-occurrence text order, suggestion-only-highlights / learner-self-rates.
- `.ohcourse` 1.0 parser: strict/tolerant matrix, referential integrity, DFS cycle rejection, path-qualified errors, never half-imports.

**Exceeded:**
- **FSRS-6 opt-in** per profile via ts-fsrs (MIT, FSRS-6, ships sane defaults; packet: beats SM-2 in 99.6% of benchmark collections). One knob: desired retention (0.90 default). SM-2+floor stays the default scheduler for continuity; mastery in FSRS mode = stability ≥7d. Because state is a revlog fold, switching schedulers is a replay, not a migration; per-user parameter fitting is a later hearth job.
- **`.ohcourse` 1.1** (parser accepts 1.0 and 1.1): adds item type 5 `generation` (Matuschak's generation effect — "write your own example"; your answer is stored and resurfaced for self-comparison at next review) and optional `discourse` hooks on qa/procedure items.
- **Construction and discourse (Brain-gated, gracefully absent):** after reveal on qa/procedure, an optional explain-back turn — the Brain asks exactly one focused Socratic follow-up (prompt template enforces Matuschak's focused/precise/tractable/effortful properties and refuses his named anti-patterns), suggests a grade, and **the learner's self-rating still stands** (Trellis's honesty law). Discourse turns log to the revlog as annotations, never as grades. No Brain → plain reveal + self-rate, byte-identical to Trellis.
- **Mnemonic-medium reading** (opt-in per work): due/new cards minted from this work interleave into the reading flow every few hundred words — Quantum Country's embedded prompts, powered by the extract flow the donor already had.
- **Incremental clozing** (SuperMemo steal, machinery hidden): an extract makes one cloze now and *offers* another at next review; work-level tend-priority (low/normal/high) mixes with deliberate randomization — never a 0-is-highest percent scale.
- **Distillation as a first-class pipeline** (§8) closes the loop: any Work → typed course → Espalier.

## 6. ML runtime per tier + the engine seam (hard reqs 3, 6)

All inference sits behind three interfaces in `packages/ml` — `Transcriber`, `Translator`, `Speaker` — with engines selected by a capability probe (WASM threads? WebGPU? hearth grafted?). The donor's fatal lesson (its untested 60-ai layer is where every owner complaint lived) becomes policy: **engines are tested against recorded fixtures; one live smoke test per engine behind an env flag.** No sticky same-session demotion: a failed worker retries after cooldown or explicit tap (fixes the sticky-flag jank). Platform-aware residency: mobile keeps 1 model resident, desktop 2+ (fixes the evict-everything re-init jank). Full model/size table in ml_plan.

**Checkpointed transcription (the flagship reliability fix):**
1. Enclosure streams **to OPFS**, never RAM (kills the 300MB-buffer OOM); `transfer/` gives Range-resume.
2. Decode in windows via WebCodecs AudioDecoder (whole-file decodeAudioData only under a size gate as fallback); hearth uses bundled ffmpeg-static.
3. Silero-VAD (~2MB ONNX) trims silence first — the packet's documented Whisper-hallucination mitigation.
4. Whisper runs the canonical 30s/5s stride recipe; **every chunk's result is persisted to the `jobs` store as it lands** `{idx, t0, t1, status, text, words?}` with overlap-merge at joins. A killed 40-minute transcript resumes at the next chunk, never restarts (hard req 6, verbatim).
5. UI: streaming sentence view + honest ETA from a rolling realtime-factor, per-chunk progress — not a spinner. Runs in a Worker (not throttled in background tabs per packet) + Screen Wake Lock (universal, iOS 18.4+ fixed).
6. Timeouts are duration-scaled; the 90s stall watchdog guards *model load only* (fixes the 120s-default-kills-every-real-podcast jank).

**Downloads:** `transfer/` fetches model files with AbortController + Content-Range resume into OPFS, sha256-verified in promote, atomic rename, real MB progress, and a **persistent resume card** in the library. Manifest pins (repo, revision, sha) per tier; trust order follows the fleet's model-trust laws (official orgs > known quantizers; ungated only).

## 7. Rootstock — the hearth daemon (the shape's core)

**What it is:** one daemon on the family desktop (Win/mac/Linux), shipped as a single-file executable (Node SEA / bun compile) with a tray icon and a LAN console. It serves:
- **Port 4663 — `domovoi-stove/v1`, unchanged:** the whole fleet's LLM asks (Peckish, Reckon) — one family daemon, not two. Frozen HKDF info string respected.
- **Port 4664 — `arbor-hearth/v1`:** same frame grammar and challenge discipline as the stove (nonce(12)‖ct‖mac(16), ChaCha20-Poly1305 IETF, single-use 60s challenges, constant-shaped 403 `refused`), but its own frozen HKDF domain `openhearth.arbor.hearth.v1` and AAD label `arbor-hearth/v1 | <endpoint> | <challenge>` with endpoint ∈ {sync, job, blob, ask} — no stretching domovoi's frozen contract, no cross-protocol replay. Plus HTTP/3 WebTransport on the same port for browsers (below).

**Jobs** (SQLite-backed queue, crash-safe, chunk-checkpointed exactly like client jobs — same schema from `packages/ml`): transcribe (whisper.cpp large-v3-turbo, GPU where present), translate (NLLB-200 full 200-language coverage), TTS bakes (Piper/Kokoro), **feed fetching with real network access** (no CORS, true conditional GET, household-deduped), overnight auto-download + auto-transcribe of flagged podcast feeds, distillation (§8), .ohparcel baking, .apkg baking, nightly OHBK bale backup to a user-chosen folder/drive. Phone submits a job and goes to sleep; **the stove keeps cooking**; results become layers and sync on next contact. Engines are pluggable: transformers.js v4 in-process by default (zero extra installs — Node WebGPU/CPU, same models and manifest as the client), with auto-detected accelerators: bundled whisper.cpp binaries, and Ollama/llama.cpp if present (Reckon precedent).

**Pairing UX — "graft a device":**
1. Install Rootstock on the desktop; first run shows the **graft card**: a QR + the same info printed as text.
2. The QR carries **no secret**: `{name, LAN addresses[], ports, WebTransport cert hash, fingerprint emoji}`. The household **BIP39 phrase is typed on the device** (the family already has one — sanctuary lineage). Stove law kept verbatim: *the secret IS the pairing; no key ever crosses the wire.*
3. Device derives the frame key (PBKDF2-HMAC-SHA512 "mnemonic"/2048 → HKDF-SHA256 `openhearth.arbor.hearth.v1`), runs challenge/response; both screens show the same fingerprint emoji pair; done. Wrong phrase = constant-shaped 403, no oracle.
4. Re-finding after DHCP churn: APK re-runs mDNS (`_arbor._tcp`); browsers probe all cached candidate addresses in parallel (safe — wrong host can't answer the AEAD).

**Client→hearth transport matrix (honest):**
| Client | Channel | Confidence |
|---|---|---|
| ArborShell APK (Android) | embedded Dart stove/hearthwire client (domovoi code reuse) bridged into the WebView via `addJavaScriptChannel`; cleartext-LAN allowed in shell config — AEAD does confidentiality | **guaranteed** — the family-phone path |
| Browser on the hearth machine | `http://localhost:4664` console **is a secure context** — the family desktop gets a full-powered first-class client for free (SW, WebGPU, everything) | **guaranteed** |
| Chromium/Firefox PWA on LAN | WebTransport with `serverCertificateHashes` (self-rotating ≤14-day ECDSA cert; hash delivered in the graft QR, refreshed via sync) — the standard escape from the mixed-content/PNA wall the packet documents | progressive enhancement, spiked first in P3 |
| iOS/Safari PWA | no direct channel assumed (WebTransport support treated as a risk, not a plan): full T0–T2 + cuttings via share sheet/Files; away-queue exports as file/QR | honest floor |

**Away-from-home (no public infrastructure, ever — the exposure freeze is a design axiom, not a limitation):** clients carry full replicas — everything synced at home reads, plays, and studies offline; revlog folding makes reconciliation on return trivial. Heavy requests made while away become **notes left on the stove** — a queued jobRequest op that syncs and executes on the next LAN contact ("your episode will be ready when you're home"), and the client always offers its own T1/T2 tier as the impatient fallback. If the family already runs its *own* WireGuard/Tailscale, "hearth reachable" is detected generically and everything Just Works — compatible, never required, never ours.

## 8. LLM seam + distillation (hard req 4)

`packages/brain` ports domovoi's seam: `Brain.complete(prompt, opts)` + AskException (user-readable message, cause stays in logs). Implementations: **NoBrain** (T0 — every Brain feature renders as a quiet, absent affordance), **WllamaBrain/WebLLMBrain** (local browser), **StoveBrain** (hearth → Ollama/llama.cpp), **ByokBrain** (Anthropic direct-browser or any OpenAI-compatible endpoint — donor parity, local endpoints skip egress consent). One law, enforced by a single chokepoint + test: **no Brain call without a user gesture in the call graph.** The donor's auto-offered comprehension banner survives as a purely local affordance; the model runs on tap.

**Distillation** — the hearth's crown job: Work spine → concept mining (map over chunks) → DAG assembly → item authoring (prompt encodes Matuschak's properties; refuses long-cloze/binary/orphan anti-patterns; every item cites its source sentence range) → **validated by the strict Trellis parser + cycle/referential checks before import — the parser is the envelope; the model proposes, the checker disposes** (the house openDaisugi philosophy: separate what is *allowed* from what is *decided*). Failed validation = refused course + visible error, never a half-import. T2 clients run distill-lite (cloze+qa only) with Qwen2.5-0.5B; T0 receives finished `.ohcourse` files. The existing trellis-author skill's curriculum design is the prompt spine.

## 9. Feeds + attention sovereignty by structure (hard req 5)

`packages/comms` ports the donor's already-battle-designed layer verbatim (SSRF guard, direct-first, consent-gated proxy fallback naming the third parties, conditional GET, Retry-After/breaker hygiene, size caps). With a hearth grafted, feed traffic moves to the Rootstock: no proxies, no CORS, household dedupe, overnight prefetch.

Sovereignty, structural: the river is **reverse-chronological only** — there is no ranking code to misuse. No unread badges except the due count (set by memory math, not engagement). **Bounded sessions**: fixed review batches (10/20/35) ending in a "the stove is banked" card — Zvi's Get Compact, made a UI. **Ephemera mulch by default** (feed items 30d, episodes by keepN/days — donor policy) unless promoted to Works, which persist. **No streaks, no leaderboards, no guilt notifications** — the only notification in the entire app is "your job finished," and it's local. Honest lifetime stats (words, minutes, retention) stay — they're a mirror, not a lever. Test-enforced: grep-style conformance checks that no notification path exists outside job events and no fetch executes outside the consent chokepoint.

## 10. Surfaces

1. **PWA** at the fleet Pages origin: full T0–T2 app, offline shell (network-first + SWR, all deps vendored and pinned — **no runtime esm.sh; a CDN outage can no longer brick ML**), size-budgeted (core bundle target <2.5MB gz before any model bytes).
2. **ArborShell APK**: Flutter WebView shell (ParlourShell lineage: debug-keystore signing, `releases/latest/download/Arbor.apk`, PopScope back-nav) + the Dart hearth bridge + Android share-target for .ohcourse/.ohparcel/audio/OPML.
3. **Rootstock**: single-file executables + LAN console; the console at localhost doubles as the family desktop's first-class client.
4. **Landing**: one APPS-array entry, copper/pine buttons, per fleet playbook.

## 11. Backup

OHBK v2 envelopes byte-compatible with sanctuary_auth_core (appDomain `arbor`, AAD context `arbor-backup/v1`), covering the irreplaceable kernel: profiles, work metadata, spines, extracts, cards, **revlog**, positions, feeds, prefs. Above 10MB it becomes a **bale**: a zip of numbered OHBK envelopes, each ≤10MB, chunk index in the AAD context — no new cryptography invented. Bulk media/layers are excluded by default (re-derivable or parceled) with opt-in. Restore is destructive, index-last ordering (Trellis law); a silent periodic vault snapshot runs client-side (Trellis parity) and nightly on the hearth. Donor-JSON and Trellis-domain `.ohbk` importers cover migration.

## 12. Signature UI (hard req 8)

ohStyle warm-print heritage (Lora/Nunito, linen, terracotta — glyph-coverage tested, remembering the ≤/≥ tofu trap). Three signatures:
- **The Facing Page**: Loeb-Classical-Library-style aligned reading — original and translation as facing columns on wide screens (interleaved sentences on phones), the current sentence underlit as audio plays. The bilingual karaoke IS the product shot.
- **The Espalier**: the course DAG drawn as an espaliered fruit tree on a warm wall — branches unlock along the trellis wires, items ripen from blossom (new) to fruit (mastered ≥7d). Mermaid diagrams finally render here (lazy-loaded, donor jank closed).
- **The Morning Basket**: the home screen — a small, bounded, reverse-chron basket of what the hearth prepared overnight (fresh transcripts, ready translations), what's due, and what you're mid-way through. Calm, finite, done-able.

## 13. Test strategy (hard req 7)

- **Ported invariants first**: Trellis's 132 tests verbatim (monotonic-interval and unlocked-never-relocks properties are the crown jewels); the rebuild's 108 node tests absorbed into spine/comms/study.
- **Property tests** (fast-check): revlog-fold determinism and merge commutativity (fold(union(A,B)) invariant under interleaving); position round-trip across every layer pair; segmenter stability against stored spines; SM-2/FSRS monotonicity.
- **Cross-implementation vectors**: OHBK frames and stove/hearth frames generated from the Dart implementations (sanctuary_auth_core, domovoi) and replayed against the TS codec — byte-for-byte, both directions.
- **ML seam**: fixture-replay tests for every engine (the donor's fatal gap — its ML layer had zero module tests); chaos tests for jobs (kill -9 mid-transcription → restart → completes without redoing finished chunks); one env-gated live smoke per engine.
- **Behavior**: Playwright for reader modes, TOC pause, two-sided cards, extract preview, ohcourse import, pairing flow (donor precedent, extended); hearth integration tests spin a real server with fake engines.
- **Fleet-values conformance, re-pinned for web**: size budgets (measure–budget–ratchet on gzipped bundle), no-fetch-outside-the-consent-chokepoint as a test, 320dp/3× text-scale a11y sweep via Playwright, glyph coverage, no-notification-outside-jobs.

## 14. Build phases

- **P0 Foundations (≈2 focused wks)**: spine, store, oplog/fold, study engine port green on all 132, OHBK+vectors. Gate: cross-impl vectors pass.
- **P1 The Reader (≈3–4 wks)**: reader modes, library, EPUB/PDF/OCR/TXT/URL/Gutenberg intake, comms port, feeds/river, audio bar, positions. Gate: donor-A parity checklist on real content.
- **P2 Client ML (≈3 wks)**: transfer engine, multilingual Whisper T1/T2 with checkpointed jobs, opus-mt/NLLB, Piper/Kokoro, wllama Brain, extract/review/mnemonic-medium flow. Gate: the canonical user story — a Spanish podcast transcribed on a phone, studied bilingually. **→ v0.5, first delicious release: client-only, already a superset of both donors.**
- **P3 Rootstock (≈4–5 wks)**: hearthwire server+client, job queue, sync, APK bridge, pairing UX, WebTransport spike (week 1 of P3; APK bridge is the guaranteed fallback if it slips), overnight feed/transcribe pipeline, hearth console. Gate: graft two devices, kill the daemon mid-job, everything reconciles.
- **P4 Distillation + discourse (≈2–3 wks)**: distillation pipeline with parser-as-envelope, discourse turns, generation items, .ohparcel baking. Gate: podcast → validated course → studied on a T0 phone.
- **P5 Beauty + conformance + landing (≈1–2 wks)**: Espalier/Facing Page/Morning Basket polish, budgets, a11y sweep, docs spine (VISION/AGENTS/Diátaxis/ADRs), landing card.

## Feature coverage
### Covered
- ohPrimer — all four reading modes: classic RSVP w/ ORP pivot + punctuation pacing, parafoveal ticker w/ Gaussian fade sliders, windowed scroll mode w/ tap-to-seek + inline figures, speak mode (Kokoro)
- ohPrimer — playback engine (WPM 100–1500, wake lock, session recording), centralized seekTo + all seek surfaces (tap zones, swipes, keys, scrub, transport)
- ohPrimer — sentinel segments (table/code/figure pause + modal + always-skip), chapter cards + TOC drawer (EPUB nav/NCX + synthesized), page panel + canvas minimap, context strip
- ohPrimer — translation strip → upgraded to a sentence-aligned translation layer on the spine (position survives language switch); per-work per-language cache kept, now in its own store
- ohPrimer — Whisper transcription → upgraded: MULTILINGUAL whisper (tiny→large-v3-turbo by tier) with language picker + built-in translate task, VAD hallucination mitigation, checkpointed resumable jobs (the canonical language-learner-via-podcast use case now actually works)
- ohPrimer — word-timing audio sync (sentence-level guaranteed on every tier; word-level karaoke where alignment quality passes — see degraded)
- ohPrimer — podcast audio bar (skip ±15/+30, 6 speeds, chapters incl. podcast:chapters JSON + PSC, offline toggle), episode offline caching (now profile-stamped, guid-stamped, cascade-deleted — donor jank fixed)
- ohPrimer — RSS/Atom subscribe w/ auto-discovery, feed refresh hygiene (conditional GET, Retry-After, breaker), auto-download queue (metered + quota aware), river view (reverse-chron, filters, read tracking)
- ohPrimer — library screen (search/sorts/filters/pin/rename/delete/progress), bulk + folder import, reading-list import
- ohPrimer — EPUB parser (TOC, figures, front-matter skip), PDF parser + Tesseract OCR fallback (client lazy; hearth native), plain-text heuristics, tokenizer (hyphen/URL/30-char rules)
- ohPrimer — URL article reader (readability-style extraction, charset handling, feed-XML detect→subscribe), Project Gutenberg browser (Gutendex + boilerplate strip), iTunes podcast directory search
- ohPrimer — .ohcourse import → upgraded: full typed Trellis semantics (no longer flattened to two-sided cards) while keeping the course-as-readable-book behavior
- ohPrimer — AI passage generation, AI review assists (explain/define/paraphrase, make-cloze), AI comprehension check (now user-invoked — the banner is local, the model runs on tap), BYOK providers (Anthropic direct + any OpenAI-compatible; local endpoints skip egress consent; test-connection)
- ohPrimer — extract-to-card flow (E/✧/swipe-up, drag focus span, instant vocab flag), SM-2 review queue w/ interval previews, two-sided cards (answer absent from DOM until reveal), review stats + due badge, Anki CSV export
- ohPrimer — consent-gated egress single chokepoint (proxies, cloud LLMs, model downloads w/ metered warning), SSRF/URL safety + size caps — ported from the donor's already-tested 40-comms module
- ohPrimer — multi-profile (upgraded: household-wide via hearth sync), parent dashboard + salted-SHA-256 PIN, reading stats bar, OPML import/export, share-by-URL + ?url=/?add= deep links
- ohPrimer — settings (high contrast, OpenDyslexic, eviction policy, voice picker w/ preview, AI provider), storage panel + eviction (orphaned-episode accounting fixed), theme system, position persistence (own store — megabyte-rewrite jank fixed), PWA offline shell, modal accessibility (focus trap, Escape, restore)
- ohPrimer — ML worker architecture + model memory management + download UX → rebuilt on the engine seam: real AbortController cancel, Range-resume into OPFS, sha-verified promote, persistent resume card, honest MB/ETA, platform-aware model residency (desktop holds 2+), cooldown retry instead of sticky demotion
- Trellis — SM-2 with monotonic-interval floor, whole-epoch-day UTC, ported verbatim with its property tests
- Trellis — prereq DAG unlock gating, mastery ≥7d, unlock-is-first-exposure-only, node progress math
- Trellis — study session flow with in-session relearn requeue (cleared inputs), four typed recall items with distinct UIs (cloze/qa/discrimination/procedure), rung chips, hints pre-reveal, sources post-reveal
- Trellis — auto-grading + suggested-grade model (all thresholds exact), cloze keys in text order, honest self-rating law preserved even under LLM discourse
- Trellis — .ohcourse 1.0 parser strict/tolerant matrix, referential integrity, cycle rejection w/ path in error, never half-imports; paste-JSON import PLUS file picker + share-target (donor jank fixed)
- Trellis — course repository (bundled index + imported-overrides-bundled, cache keyed by raw text, corrupt-skip), bundled 26-concept Kalman course ships
- Trellis — card state persistence → upgraded to append-only revlog + deterministic fold (gives Trellis the review history it documented as missing)
- Trellis — course map → the Espalier, incl. mastery bars, locks, due chips, presentable-due FAB; diagramMermaid FINALLY rendered (lazy-loaded)
- Trellis — encrypted .ohbk backup/restore (OHBK v2 byte-compatible, destructive index-last restore, preview-validates-like-restore), silent startup vault snapshot
- Trellis — Anki .apkg export → upgraded: available on EVERY surface via sql.js-wasm (~1MB, lazy) with the same genanki-faithful structure, stable sha1 guids, subdeck-per-node, MathJax mapping; no longer native-only
- Trellis — no-remote-fetch markdown law (course images render placeholders, never a GET), RSVP strip math ($$→[equation])
- NEW beyond both donors (the superset gains): household hearth (Rootstock) with overnight transcription/translation/feeds/distillation, real multi-device household sync, FSRS-6 opt-in with desired-retention knob, generation items + Socratic discourse turns, mnemonic-medium inline reading prompts, incremental clozing, .ohparcel cuttings for potato devices, distillation of any source into a validated .ohcourse, one family daemon also serving the fleet's stove asks
### Degraded
- Word-level timing sync: the donor claimed per-word RSVP-follows-audio (English-only, via fragile alignment). Arbor guarantees sentence-level sync on every tier and every language; word-level karaoke lights up only where alignment passes a quality gate — best on the hearth (whisper.cpp DTW token timings), fragile in-browser (the _timestamped ONNX exports have documented broken-timestamp and fp16-precision issues per the research packet). Honest tiering of a feature that was janky theater before.
- Kokoro voices: the donor's settings named ~54 voices; the current Kokoro-82M v1.0 ONNX browser package exposes 28 voices, English (US/GB) only. Multilingual read-aloud is carried by Piper voices (~60MB each, dozens of languages) instead — better coverage, lower naturalness than Kokoro's English.
- Voice-clone read-aloud: the FUNCTION (synthesize a whole document in a chosen voice, cached for replay) survives on Kokoro/Piper with streaming playback + checkpointed synthesis (fixes the 5–15-minute all-or-nothing jank). The SPECIFIC SpeechT5 + 4 CMU-ARCTIC preset 'clone' voices are retired — a generation behind in quality at 200MB, and their exact timbres are not reproduced.
- NLLB-200 at low tiers: T1 (WASM) does not offer NLLB (packet: >800MB download, 2–5s per sentence in browser). T1 gets opus-mt per-pair (~110MB/direction, chosen-pair); NLLB-200's full coverage is T2-opt-in and standard on the hearth. Donor parity requires up to 612MB anyway, so nothing that worked is lost — but a T1 user who wants a long-tail language must wait for T2 hardware or a hearth.
- Legacy JSON backup: importable forever (migration path from both donors), but no longer the export format — export is encrypted OHBK bales + Anki. A donor user's exact export-format muscle memory changes.
- iOS PWA: full T0–T2, but no background jobs (iOS suspends the page — packet), no assumed hearth channel (WebTransport on Safari treated as risk), and model caches live under Safari's eviction regime (install-to-home-screen mitigates). Android APK is the first-class family-phone surface; iOS is honestly second.
### Dropped
- The dormant encrypted relay-sync code (entry points already threw in the donor; ADR-0007 had already reduced it to file backup). Superseded by hearth LAN sync — and deliberately NOT replaced by any public relay: the exposure freeze is a design axiom.
- The single-file-HTML deliverable property: ohPrimer was one copyable index.html; Arbor is a built, vendored PWA bundle (the 8065-line single file is the cautionary tale — Parlour keeps that flag flying for the fleet). Users who shared the app by copying one file lose that trick; share-by-URL and the APK remain.
- Runtime CDN dependence (esm.sh imports): dropped on purpose — all deps vendored and pinned. Listed here because it changes observable behavior a donor user might have relied on (instant upstream lib updates); the gain is that a CDN outage can no longer brick every ML feature.

## Potato story
The canonical potato: a ~$80 Android phone, Chrome, 1–2GB RAM, prepaid data that comes and goes.

T0 (no ML, no server): She opens the PWA once on wifi (<2.5MB core; not one model byte without consent) and installs it. She reads — RSVP, scroll, facing-page — imports EPUBs and pasted articles, subscribes to three feeds (direct fetch first; the app asks once, naming names, before any public proxy sees a URL), and streams podcast episodes (cross-origin audio plays fine; caching an episode offline may need the consented proxy). She studies full typed .ohcourse files shared into WhatsApp — prereq Espalier, all four item types, SM-2 with the monotonic floor, Anki CSV out. Positions, cards, and the revlog live on the phone; offline everything cached still works, and feeds catch up at the next signal. Crucially, she can import a cutting (.ohparcel) baked on anyone's hearth or T2 laptop: the episode arrives already transcribed, translated, and sentence-aligned — her potato renders the full bilingual karaoke experience because the compute happened somewhere else. Platform TTS (speechSynthesis) offers read-aloud with an honest 'voice quality and privacy depend on your OS' note.

T1 (she opts into WASM ML): whisper-tiny int8 (~41MB, multilingual, language picker, translate task) — a 40-minute Spanish podcast transcribes in roughly a lunch break at 0.5–2× realtime, screen on with wake lock, checkpointed every 30-second chunk with a live sentence stream and a truthful ETA; if the phone dies at minute 30 it resumes at minute 30. One opus-mt pair (~110MB) covers her language pair; one Piper voice (~60MB) reads articles aloud.

T2 (a newer phone or the family laptop, WebGPU): whisper-base (77MB) or small (248MB) makes transcription minutes-not-hours; Kokoro (92MB) for lovely English TTS; optionally Qwen2.5-0.5B (~500MB, Apache, ungated) for make-cloze and comprehension checks on-device.

T3 (a cousin or parent runs Rootstock on any desktop): she scans the graft QR, types the household phrase, and her phone becomes a thin client of the family hearth. Overnight the stove fetches her feeds (no proxies ever again), transcribes new episodes with large-v3-turbo, translates them with NLLB-200, and distills the one she flagged into a course. Her Morning Basket is full when she wakes. Away from home, everything already synced still reads, plays, and studies; anything heavy she asks for becomes a note left on the stove, ready when she's back on the LAN — and her T1 tools remain if she can't wait. No account was created at any point, and nothing she did was visible to anyone but her family.

## ML plan
One engine seam, four tiers; every model pinned (repo, revision, sha) in a manifest and pulled by the ported domovoi transfer engine (Range-resume into OPFS, sha-verified promote). Runtime is transformers.js v4 (Feb 2026, rewritten C++ WebGPU runtime, ~200 architectures, runs in browser AND Node — the packet's 'target v4 not v3') so client and hearth share model specs and test fixtures.

T0 — none. Platform speechSynthesis only, honestly labeled. All ML arrives as .ohparcel layers baked elsewhere.

T1 — WASM (threads where COOP/COEP allows; single-thread floor): ASR onnx-community/whisper-tiny int8 ~41MB, multilingual + language picker + task=translate, 30s/5s stride recipe, silero-VAD (~2MB) preprocessing (packet's hallucination mitigation). Packet rule honored: int8/q8 below whisper-small (q4 decoders are LARGER than int8 on tiny/base). MT: Xenova opus-mt per-pair ~110MB/direction (NLLB excluded at T1: >800MB, 2–5s/sentence in browser per packet). TTS: Piper WASM ~60MB/voice, CPU 3–5×RT, multilingual, MIT.

T2 — WebGPU (default-on in all majors incl. Safari 26 per packet): ASR whisper-base int8 77MB (default) / whisper-small int8 248MB (good phones/laptops) / whisper-large-v3-turbo q4f16 ~563MB (strong desktops); encoder kept fp32/int8 on WebGPU (documented fp16 precision bug #1590); word-level _timestamped exports used only behind a quality gate (#1357, #820 fragility). MT: opus-mt default; NLLB-200-distilled-600M int8 opt-in (~600–800MB) for long-tail coverage, CPU-int8 (WebGPU NLLB issue #1286). TTS: Kokoro-82M v1.0 ONNX q8 92.4MB (28 EN voices) + Piper for other languages. LLM: wllama (llama.cpp WASM+WebGPU, MIT, OPFS-streamed — memory-friendlier than WebLLM per packet) running Qwen2.5-0.5B-Instruct q8 ~500MB (Apache-2.0, UNGATED — the only friction-free family for a no-account FLOSS product) for make-cloze/comprehension/distill-lite; WebLLM Qwen3-1.7B as an alternative where its prebuilt list fits. Chrome's built-in Translator API used as free progressive enhancement where present (desktop Chromium only), never a foundation.

T3 — Rootstock (family desktop): default engines are transformers.js v4 in Node (zero extra installs, same manifest); auto-detected accelerators: bundled whisper.cpp binaries (large-v3-turbo q5_0 ~574MB / q8_0 ~874MB ggml; CUDA/Metal/Vulkan where present; faster-than-realtime on modest GPUs; native DTW token timestamps → the best word-level alignment in the system), NLLB-200-distilled-600M int8 for 200-language translation at desktop speed, Piper native + Kokoro for TTS bakes, ffmpeg-static for decode, silero-VAD always. LLM: Ollama/llama.cpp if present (Reckon/domovoi precedent; stove upstream default http://127.0.0.1:11434/v1) — recommended household model Qwen3-4B-Instruct q4 ~2.5GB; BYOK Anthropic as the opt-in cloud rung. Model acquisition follows the fleet trust laws (official orgs > known quantizers like bartowski; ungated only; no mirrors).

Scale-to-zero honesty: mobile keeps one model resident (iOS ~1GB tab budget), desktop residency 2+; no sticky demotion — cooldown retry. Long jobs run in Workers (unthrottled in background per packet) + Screen Wake Lock (universal; iOS 18.4 bug fixed), checkpointed every chunk so suspension is a pause, not a loss.

## Risks
- Browser↔hearth transport is the moatiest bet: WebTransport-with-serverCertificateHashes needs a maintained Node HTTP/3 implementation and Safari support is unproven — mitigated by scheduling it as the FIRST spike of P3, with the APK native bridge (guaranteed) and the localhost console (guaranteed) as the load-bearing paths, and by designing all hearth value to also travel as synced data and .ohparcel files.
- Reader-port scope: donor A is 8065 lines and its riskiest layer (60-ai) has zero module tests — the rebuild's verbatim-extraction + regression-ID method and its 108 existing tests reduce but do not remove the chance that P1/P2 run long; the phase gates make slippage visible early.
- Word-level timestamp fragility (broken _timestamped exports, fp16 encoder precision, no streaming word timestamps per packet): mitigated by promising sentence-level everywhere and gating word-level karaoke on measured alignment quality — but the demo-magic moment is weaker on hearth-less browsers, and marketing must not overclaim.
- transformers.js v4 is ~6 months old; a rewritten runtime will have sharp edges — pinned versions, fixture tests per engine, and whisper.cpp/opus-mt fallbacks bound the blast radius, but some churn tax is certain.
- Sync correctness: fold-over-revlog is deterministic by construction, but LWW/HLC metadata merge and segmenter versioning have edge cases (clock skew, re-ingest of the same source) — property tests + cross-device chaos tests are budgeted in P3, and the StillLife sync-clock bug history (20 concurrent stamps→1) is the cautionary precedent to test against explicitly.
- Rootstock packaging: Node SEA / bun-compile single binaries with native deps (better-sqlite3, ffmpeg-static, whisper.cpp) per-OS is real build-engineering; fallback is a documented 'npx arbor-rootstock' path for technical families while installers mature — acceptable for a FLOSS v1, must not stay the only path.
- iOS storage eviction and suspension: model caches and long client-side jobs are structurally worse on iOS (7-day sweep, page suspension) — install-to-home-screen guidance and the hearth are the mitigations; the iOS-only family without a desktop gets a genuinely lesser T1/T2 and the docs must say so plainly.
- Owner adoption risk of the hearth itself: the exposure freeze could extend to running ANY daemon — mitigated structurally (LAN-only bind, no listener on 0.0.0.0 beyond the LAN, no cert authority, no telemetry, the fleet's existing stove precedent already crossed this line) and by the client-only v0.5 being delicious on its own.
- Scope-vs-artisan: four surfaces, one artisan + agents; if P3+ slips, v0.5 (client-complete superset) is a real, shippable, honest product — the phasing is the hedge, not a promise of the full vision by a date.
- Distillation quality: LLM-authored courses validated by the strict parser are structurally safe but can still be pedagogically mediocre — mitigated by encoding Matuschak's prompt properties, citing source sentences per item, and keeping the trellis-author skill's curriculum design as the prompt spine, with human-editable output (it's just a .ohcourse file).

## Build cost
Estimated in focused artisan+agents weeks (the fleet's demonstrated cadence: sanctuaryAuth fleet-wide in days, Peckish/StillLife-scale features in 1–2 weeks each). P0 foundations ≈2 wks (spine, stores, oplog/fold, 132 Trellis tests green, OHBK cross-impl vectors). P1 reader/library/feeds port ≈3–4 wks (the big one: 8065-line donor, but the rebuild method + 108 tests exist). P2 client ML tiers ≈3 wks (transfer engine, checkpointed multilingual Whisper, translation/TTS, review flow). **First delicious release v0.5 at ≈8–9 focused weeks** (~2.5–3 calendar months part-time): client-only, already a strict superset of both donors, canonical Spanish-podcast story working on a phone. P3 Rootstock + sync + APK bridge ≈4–5 wks (WebTransport spike week 1; APK bridge is the guaranteed fallback). P4 distillation + discourse ≈2–3 wks. P5 beauty/conformance/docs/landing ≈1–2 wks. **Full vision ≈15–18 focused weeks (~4.5–6 calendar months part-time)**, roughly 250–400 agent sessions. Honest caveats: P1 is the likeliest overrun (reader breadth), P3 carries the only true research risk (browser transport) and is explicitly hedged so its slippage cannot sink v0.5; no step depends on public infrastructure, so nothing waits on the owner unfreezing anything.
