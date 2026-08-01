# Espalier (working name "PrimingTrellis") — an espalier is a tree trained on a trellis to bear more fruit in less space. You train the tree; the tree never trains you.

**Stack:** Flutter (Android APK + Linux/Windows/macOS desktop + web PWA) · Riverpod codegen + go_router + Drift/drift-wasm · pure-Dart domain packages in a melos monorepo · dart:ffi to whisper.cpp, llama.cpp, Piper, onnxruntime · flutter_gemma (LiteRT) on Android · direct Dart deps on domovoi, sanctuary_auth_core, sanctuary_backup_ui, openhearth_design, oh_fleet_conformance.

## Architecture
# Espalier — Flutter-everywhere architecture

## 0. Why this shape wins

Four load-bearing fleet assets are **already Dart**. In this shape they are `path:`/git dependencies; in any web shape they are rewrites:

1. **The study engine.** Trellis's domain layer (`lib/features/study/domain/{sm2_scheduler,progress,grading}.dart`, `lib/features/curriculum/data/curriculum_parser.dart`) is pure Dart with zero Flutter imports. The 183-test suite — including the two crown jewels, *monotonic-interval-growth-under-repeated-Hard* and *unlocked-concept-never-relocks* — moves into `packages/study_core` **unmodified**. No other stack starts with its hardest-won invariants already green.
2. **Backup.** `sanctuary_auth_core` (OHBK v2: `"OHBK"` magic, ChaCha20-Poly1305 IETF, AAD = header‖context, per-app HKDF `openhearth.<appDomain>.<purpose>.v1`) is a direct dep, proven in 9 fleet apps. The web stack would re-implement the wire format from code-as-spec with no yellow paper.
3. **Downloads + household AI.** domovoi is pure Dart by design ("so the CLI runs where Flutter can't"): `ResumableTransfer` (Range resume from `.part` length, 416/200-on-resume restart laws, integrity in the caller's atomic `promote`), the `Brain` seam, model trust laws, and the **stove client** (port 4663, ChaCha20-Poly1305 frames, challenge single-use, secret-IS-pairing). The ground-truth packet is blunt: a *browser* stove client is **not feasible today** (no CORS on `stove_server.dart`, https-PWA-cannot-fetch-http-LAN). The household-brain tier is a native-app feature, full stop — this shape gets it by importing `stove_client.dart`.
4. **Conformance.** `oh_fleet_conformance` C1–C7 runs only under `flutter_test`. C4 makes the Android permission surface a *test both directions incl. the release merged manifest*; C3 ratchets APK+web size; C5 sweeps 320dp×3.0 incl. dialogs; C7 catches the Lora/Nunito ≤/≥ tofu trap. The web stack re-pins these values by hand; we inherit the harness.

And the native APK **structurally deletes** the four worst donor janks: CORS proxies (native fetch is CORS-free), RAM-bound one-shot transcription (files + chunk checkpoints + foreground service), evictable browser-cache model weights (real files + domovoi resume + sha256 fail-closed promote), and background-tab throttling / iOS-suspends-everything (audio_service playback + Android foreground service survive screen-off — the packet confirms no PWA can do this on iOS at all).

## 1. Surfaces

| Surface | What it is | Tier ceiling |
|---|---|---|
| **Android APK** (primary) | Real native app, `com.openhearth.espalier`, GitHub Release `Espalier.apk` per fleet playbook (debug-keystore precedent). Share-target intake, background audio, foreground-service jobs. | T0–T3 |
| **Desktop** (Linux/Win/mac) | Same codebase; the natural T2/T3 machine — big Whisper models, llama.cpp 3B–7B, and (roadmap) itself a stove server for the family's phones. | T0–T3 |
| **Web PWA** (gh-pages, drift-wasm) | Full reader/feeds/study/courses/backup surface. v1.0: **no local ML** (honest); BYOK cloud LLM works (ohPrimer precedent: Anthropic direct-browser). Phase 6 adds a transformers.js-v4 interop tier. | T0 (+BYOK) |

One Flutter codebase; per-surface capability is a `Capabilities` object resolved at boot, and every ML/FFI seam has an inert web implementation (domovoi's own documented pattern: "web surfaces keep their own inert variants").

## 2. Module map (melos monorepo)

```
espalier/
  packages/
    loom_core/        # content spine: Work/Segment/Layer/Position, tokenizer,
                      # EPUB/TXT/MD parsers, readability extraction, front-matter,
                      # sentinel classification — pure Dart, donor heuristics + tests ported
    study_core/       # Trellis domain VERBATIM: sm2_scheduler, progress, grading,
                      # curriculum_parser + the 183 tests. New: revlog model, study-ahead policy.
    comms_core/       # SSRF guard (assertSafeFetchUrl port, STRICTER — native reaches real LANs),
                      # conditional GET (ETag/Last-Modified/Retry-After), RSS2/Atom/Media-RSS,
                      # feed auto-discovery, OPML, iTunes/Gutendex clients, size caps mid-stream.
                      # Pure Dart over an http seam; proxy-chain strategy web-only.
    ml_runtime/       # seams: Transcriber, Synthesizer, Translator, Vad.
                      # impls: whisper_cpp (FFI), piper (FFI), kokoro_onnx (FFI),
                      # system_tts (flutter_tts), inert_web. Model registry (id, files[{url,sha256,bytes}]).
    jobs_core/        # checkpointed-job engine: job rows, chunk protocol, resume laws,
                      # honest ETA (moving-average chunk time). Pure Dart; platform executors in app.
    brain_wiring/     # domovoi Brain tier resolution (local LiteRT / llama.cpp / stove / BYOK),
                      # Distiller (source → .ohcourse w/ parser-validation repair loop),
                      # Discourse prompts, translation-via-Brain adapter, provenance stamping.
  app/                # Flutter: features/{library, reader, player, feeds, river, study,
                      # espalier_wall, extracts, models, profiles, settings, sanctuary_backup}
                      # Clean Architecture per fleet convention; Riverpod codegen; go_router.
  natives/            # cmake builds: whisper.cpp, llama.cpp, piper, onnxruntime, silero-vad
                      # → jniLibs (arm64-v8a, armeabi-v7a where viable) + desktop .so/.dll/.dylib
```

Direct external deps: `domovoi` (Brain, ResumableTransfer, StoveClient, model trust), `sanctuary_auth_core` + `sanctuary_backup_ui` (v0.2.0 retention), `openhearth_design`, `oh_fleet_conformance`, `flutter_gemma`, `just_audio` + `audio_service`, `wakelock_plus`, `file_picker`, `pdfrx` (pdfium), `ffmpeg_kit_flutter` community fork (PunctumTemporis precedent), `drift`.

## 3. The content spine (canonical representation)

Everything — podcast episode, article, EPUB chapter, feed item, pasted text, distilled course intake — normalizes to one shape:

```
Work        id, profileId, kind{book|article|episode|course_intake|generated|note},
            source{url|file|feedId+guid}, title, detectedLang,
            persistence{work|ephemeron}, pinned, finishedAt
Segment     workId, idx, kind{prose|heading|code|table|figure}, text, tokenCount
            — sentence/block-level; THE atom of cross-modal identity
Layer       workId, segmentIdx, lang, kind{original|transcript|mt|human},
            text, provenance{modelId|brainTier|human}
MediaAsset  id, workId, filePath, bytes, mime, durationMs
Alignment   workId, segmentIdx, tStartMs, tEndMs, wordTimings(blob)
Position    profileId, workId, segmentIdx, wordIdx, lastModality{read|listen|speak}, updatedAt
```

**The cursor law (spine invariant, tested):** a `Position` never references a modality or a language. Renderers *project* it — RSVP projects (segment,word); the audio player projects via `Alignment`; a translation layer projects the same segmentIdx in another language. Stop listening in the car mid-sentence; open the reader; the same segment is highlighted — possibly in the translation layer. Format switch = zero data movement, it's the same row.

This schema also structurally fixes donor janks: position saves write one tiny row (ohPrimer rewrote the whole multi-MB book record); translations are per-segment layers, not blobs inside the book; episode cache rows are profile-stamped (donor leaked them across profiles and orphaned them on delete).

**Ephemera decay (sovereignty by structure):** feed items and un-promoted episodes are `ephemeron`; a sweep deletes them after a default 30 days. Promotion to `work` is *earned by the user's hand* — extract, pin, or finish. Works persist forever. The river is reverse-chronological only; no ranking code path exists to test because none is written.

## 4. Storage

- **Drift (SQLite)** everywhere — native file DB; drift-wasm on web (fleet-proven: StillLife PWA, deploy playbook). Tables: profiles, works, segments, layers, media_assets, alignments, positions, courses, cards, **revlog** (new — every grade with timestamps/intervals; FSRS food), word_ledger, feeds, episodes, jobs, models, consents.
- **Media on disk** via path_provider (native) / OPFS-backed blobs (web): episode audio, model weights, Piper voices, rendered TTS WAVs. DB stores metadata only. `navigator.storage.persist()` + install prompt on web (Safari 7-day eviction: installed home-screen apps keep a separate usage counter, per packet).
- Trellis's SharedPreferences cold-start jank dies: course bodies and cards live in Drift. `CourseRepository`/`CardRepository` **interfaces are preserved** so the 183 tests and the backup serializer's read surface port without edits; only the impl behind the seam changes.
- Storage panel: real disk accounting, per-feed audio buckets (including the donor's orphaned clone/episode buckets), purge per-feed/all, keepN/days eviction policies at boot.

## 5. ML runtime per tier

Seams in `ml_runtime` (all `Stream`-based so progress and partial results are first-class):

```dart
abstract class Transcriber {
  Stream<TranscriptChunk> transcribe(PcmChunkSource src,
      {String? lang, WhisperTask task = WhisperTask.transcribe, bool wordTimings = true});
}
abstract class Synthesizer { Stream<AudioChunk> synthesize(Iterable<Segment> s, Voice v); }
abstract class Vad { Future<bool> hasSpeech(Float32List window); }
```

- **ASR — whisper.cpp via FFI**, multilingual ggml models with a language picker and the built-in `translate` task (X→English). Runs in a dedicated isolate; whisper's own threads = cores−1. Word timings from token-level timestamps (`--max-len 1` segmentation) → `Alignment` rows. **Silero VAD (~2MB, onnx)** gates silent windows — the packet's "Careless Whisper" citation: ~1% hallucinated phrases concentrated in silences; VAD is the named mitigation. Non-English timestamp drift is a documented caveat surfaced in the UI, not hidden.
- **Audio decode:** streamed to a 16kHz mono PCM *file* via the pinned ffmpeg_kit community fork (PT precedent) — never a giant Float32Array in RAM (the donor's 3h-episode ≈ 700MB OOM).
- **TTS ladder:** system TTS via flutter_tts (0 bytes, every Android phone, many languages) → **Piper** (~60MB/voice, multilingual, CPU 3–5× realtime, MIT — the packet's "multilingual browser-TTS answer" is equally the native one) → **Kokoro-82M q8 92.4MB** (ONNX, 28 EN voices — the donor's ~54-voice claim was the Python path, per packet) for premium English. Speak-mode audio streams sentence-by-sentence as it renders; whole-doc renders are cached WAV files (the donor blocked 5–15 minutes before playing anything).
- **LLM:** see §7.
- **Translation:** v1 via the Brain seam (any tier that has one) + Whisper's translate task for speech→English. Phase 6 ships `onnx_seq2seq` (greedy decode + SentencePiece FFI) serving **opus-mt int8 ~110MB/pair** and **NLLB-200-distilled-600M** for the long tail. Honest sequencing: a hand-rolled seq2seq decode loop is the single riskiest ML item, so it does not gate v1.0.
- **Memory residency:** platform-aware (fixes donor evict-to-one jank): desktop holds several models; phones hold one, freed before sibling load; transient failures get a cooldown retry, never a session-long sticky demotion.

## 6. Study engine — Trellis semantics, then past them

**Verbatim (183 tests unmodified):** SM-2 with q(2/3/4/5), EF clamp ≥1.3, lapse reset + same-session relearn with cleared inputs, success base 1|6|round(i·EF′), hard ×0.6 / easy ×1.3, **monotonic floor max(·, old+1)**; whole-epoch-day UTC; mastery = interval ≥7d; DAG unlock on prereq mastery 1.0; **unlock-is-first-exposure-only**; four typed items (cloze/qa/discrimination/procedure) with their distinct UIs, hints, rungs, sources; auto-grading (normalized cloze, discrimination index, keyword coverage → suggested grade that only *highlights* a button — the learner's self-rating drives the SRS, a law we keep even with an LLM judge available); cloze key text-ordering; strict `.ohcourse` parser with referential-integrity + cycle rejection.

**Exceeding — construction and discourse (Brain-gated, gracefully absent):**
- **Explain-back:** after intake, "teach it back in your own words"; the Brain probes one gap Socratically (elaborative interrogation — Dunlosky's moderate-utility tier, vs highlighting's low).
- **Graded free recall:** for qa/procedure the Brain writes a short rubric-anchored critique and *suggests* a grade; the tap is still the learner's.
- **Generation-effect prompts:** "give an example the author didn't" — Matuschak's prompt properties (focused/precise/consistent/tractable/effortful) are literally encoded in the Distiller's system prompt.
- **Incremental cloze:** SuperMemo's law — one cloze per visit from an extract, not all at once; machinery hidden behind defaults, never a 0-is-highest priority scale.
- **Word ledger (new, LingQ mechanic):** per-profile per-language known/learning/new state painted over every text; tap-to-flag feeds vocab cards carrying sentence + source + (when aligned) the audio span — Migaku's one-click capture, offline and unowned.
- **Study-ahead affordance:** the documented Trellis empty-app jank (144 of the first 200 days due-empty) gets a bounded, opt-in "prepare tomorrow's row" session — displayed mastery bar unchanged.
- **Revlog from day one** so FSRS-6 (packet: beats SM-2 in 99.6% of collections, ~20–30% fewer reviews *in simulation*) can land later as a pure-Dart port validated against reference vectors — SM-2 stays the shipped scheduler until then; no regression risk to the invariants.

## 7. The LLM seam

domovoi `Brain` (`abstract class Brain { Future<String> complete(String prompt); }` + `AskException`) with tier resolution the user pins explicitly — never silent fallback *upward* in egress (local → stove is LAN; anything cloud requires the sticky consent chokepoint):

| Tier | Impl | Precedent |
|---|---|---|
| none | every Brain feature hidden; keyword-coverage suggestions still work | Trellis today |
| local (Android) | flutter_gemma / LiteRT — litert-community **Qwen2.5-1.5B-Instruct** (Apache, ungated; Reckon's default `ModelType.qwen`) or 0.5B for low RAM | Peckish 1.0.0-rc.1, Reckon 0.13.2 |
| local (desktop) | llama.cpp FFI — Qwen2.5-3B/7B-Instruct GGUF q4 | fleet llama.cpp research |
| household | domovoi **StoveClient**, port 4663, secret-IS-pairing via the household BIP39 phrase | shipped in domovoi, adopted by Peckish + Reckon |
| BYOK | Anthropic direct + OpenAI-compatible (Ollama/LM Studio/OpenRouter); local endpoints skip egress consent | ohPrimer + Reckon |

**Distiller invariant (tested):** any Brain-generated `.ohcourse` must pass `study_core`'s strict parser (schema, prereq integrity, cycle rejection) before it is saved; up to 3 repair rounds with the parser's path-qualified errors fed back; then a visible failure — never a half-imported course. Every generated layer/course/card carries provenance (`brainTier`, model id).

Stove reality, stated honestly: the 1MiB ask cap means stove v1 carries **text** (distill this transcript, translate this segment, critique this recall) — not audio. Household transcription offload = run the desktop app on the episode; results travel by `.ohbk`/file share. A chunked-transfer stove endpoint (new AAD label, frozen HKDF info untouched) is roadmap.

## 8. Feeds, podcasts, intake

- Subscribe by URL with auto-discovery; RSS2/Atom/Media-RSS; conditional GET, Retry-After, 5-failure breaker; OPML both ways (import validates by fetching); iTunes search; Gutendex browser; reading-list JSON import.
- **Native surfaces fetch direct — the entire public-CORS-proxy layer (cors.eu.org/allorigins/codetabs) vanishes** along with its rate limits and stripped conditional-GET headers. The web surface keeps the donor's consent-gated proxy chain, ported with its tests.
- Auto-download queue: per-feed opt-in latest-N, metered-connection guard (connectivity_plus), disk-space guard, re-checked between downloads; episodes cached as files, profile-stamped, in the eviction system.
- Player: just_audio + audio_service — lock-screen controls, background playback, ±15/+30, 6 speeds, chapters (podcast:chapters JSON + PSC). Listening position writes the same `Position` row the reader reads.
- Intake: EPUB (pure-Dart port of donor parser: spine walk, nav/NCX, figure blobs, front-matter skip, charset quirks — donor heuristics as fixtures), TXT/MD heuristics, paste, URL (readability-style scoring ported to Dart `html`), PDF via pdfium text extraction with column/footnote heuristics (native), bulk/folder import, **Android share-target** (share a podcast episode or article from any app straight into Espalier — better than the donor's ?url= deep link, which the web surface keeps).

## 9. Reliability engineering

**Model downloads** = domovoi `ResumableTransfer` + a model registry (pinned URLs + sha256 + bytes, per the fleet's model-trust laws): true Range resume from `.part`, 416/200-on-resume restart correctness, sha256 verified in `promote` before an atomic rename — **fail-closed**; honest cumulative MB/% + ETA; a persistent "resume download" card; cancel keeps the partial. Weights are files: no browser-cache eviction can silently re-trigger 612MB (the donor's exact wound).

**Transcription as a checkpointed job (jobs_core):**
1. enclosure → file via ResumableTransfer (its own resumable step)
2. decode → 16k PCM file (checkpoint: decoded)
3. 30s windows, 5s overlap (the packet's canonical recipe); VAD-gated
4. per window: whisper → merge overlap by timestamp midpoint → transcript segments + `jobs.checkpoint` committed in **one Drift transaction**
5. kill the app anywhere → resume at the last committed window. **Property test: for every kill point, the final transcript is byte-identical to the uninterrupted run.**
6. Android foreground service + progress notification (chunks done / total, moving-average ETA). A 40-minute episode on a phone survives screen-off, reboots resume, and *never restarts from zero* — the donor persisted only on full completion and re-ran everything on the main thread after a 120s worker timeout.

Whole-doc TTS renders and Phase-6 translation prefetch run on the same job engine.

## 10. Backup & migration

- `.ohbk` via sanctuary_auth_core: appDomain `espalier`, aadContext `espalier-backup/v1`; envelope payload = profiles, works (+optional media manifest; big audio opt-in, PT-montage precedent), segments/layers/alignments, courses (bodies for imported only, Trellis rule), cards + revlog, word ledger, feeds/OPML, consents-excluded (consents never travel). Destructive restore preserves Trellis's index-last write ordering; startup vault snapshot (7-day) kept.
- **Migration, both donors:** import Trellis `.ohbk` (decrypt with appDomain `trellis` + `trellis-backup/v1`, re-encrypt under espalier) and ohPrimer's plaintext JSON backup (sanitized exactly as the donor did: prototype-pollution keys, id re-scoping, dedupe). No user data is stranded.
- Anki: `.apkg` on native (Trellis's genanki-faithful exporter — subdecks per node, stable sha1 guids, MathJax conversion) behind the existing conditional-export facade; CSV export everywhere including web.

## 11. Attention sovereignty by structure (each a law, most a test)

1. River is reverse-chronological only — no ranking code exists.
2. Ephemera decay by default; works persist; promotion requires the user's hand.
3. Bounded sessions: a study session names its size before it starts and has an end screen ("Get Compact" — Zvi); no infinite queue.
4. The Brain never runs unprompted — every inference is user-initiated (tested: no Brain call reachable from timers/boot).
5. No streaks, no leaderboards, no guilt notifications; v1 ships **zero** notifications except live job progress. Stats are additive lifetime "rings."
6. Single egress chokepoint with sticky per-profile consent (proxies/web, cloud LLM, model downloads w/ metered warning); WeatherGlass-style "what leaves your device" screen.
7. C4 makes the permission surface a test: INTERNET, FOREGROUND_SERVICE(+dataSync/mediaPlayback), POST_NOTIFICATIONS, WAKE_LOCK — and nothing else, both directions, release merged manifest.

## 12. Signature UI — the Espalier Wall

Course DAG rendered as a **trained fruit tree on a warm plaster wall** (linen `#FBF8F4` ground, hearth terracotta `#A85040`, Lora/Nunito, C7-checked with the ≤/≥ trap on record): cordon branches are prerequisite lines, each concept a fruit that ripens (green→blush→terracotta) with mastery, locked buds further up the lattice. The river sheds leaves as ephemera decay — deletion made visible and calm. The reader is print-like: generous margins, drop-cap chapter cards, the heritage red ORP pivot preserved from both donors. Dark theme is the same wall at dusk. Goldens pin all of it.

## 13. Test strategy

- **study_core:** the 183 donor tests verbatim; new property tests for study-ahead and revlog append-only.
- **Ported-semantics tests:** ohPrimer rebuild's 108-test manifest re-expressed in Dart for tokenizer/parsers/comms/privacy (verbatim-extraction porting method from rebuild/README); donor EPUB/TXT heuristics as golden fixtures.
- **jobs_core:** kill-point sweep property test (every chunk boundary → identical transcript); ETA monotonicity.
- **Transfer:** domovoi's engine arrives tested; our registry gets fake-HTTP tests — sha mismatch → fail-closed, resume-after-416, cancel-keeps-partial.
- **Brain:** FakeBrain scripts; Distiller repair-loop tests; "generated course must parse" invariant; provenance stamping.
- **FFI:** every native behind a pure-Dart seam with recorded-fixture fakes for CI; a small on-device integration lane (whisper.cpp's canonical jfk.wav, a 90s multilingual clip) run locally, not in CI.
- **UI:** widget tests per feature; goldens for reader modes + wall; C5 320dp×3.0 sweep incl. dialogs; visual-loop skill for web/APK screenshots.
- **Conformance:** C1–C7 wired in Phase 0; C3 budgets ratcheted from first release (APK ~35MB with FFI libs, web gz budget).
- Sovereignty laws as tests where expressible (no-ranking, no-unprompted-Brain, permission surface).

## 14. Build phases (each shippable)

- **P0 (wk 1):** monorepo, Drift schema, study_core lands with 183 green, conformance harness, ohStyle wiring.
- **P1 (wk 2–4):** spine + reader (RSVP/ticker/scroll + system-TTS speak) + EPUB/TXT/MD/paste/URL intake + library + positions + profiles. **Alpha APK + PWA.**
- **P2 (wk 4–6):** feeds/podcasts/player/river/OPML/auto-download/eviction/ephemera decay.
- **P3 (wk 6–9):** model registry + downloads + whisper.cpp FFI + checkpointed jobs + word-timing sync + translate task + foreground service. *The canonical friend can now study her podcasts in her language.*
- **P4 (wk 9–11):** Brain tiers (LiteRT/llama.cpp/stove/BYOK) + Distiller + discourse study + word ledger + extract flow.
- **P5 (wk 11–13):** Piper/Kokoro, backup + both-donor migration, .apkg, Gutenberg/iTunes, parent dashboard + PIN, storage panel, Espalier Wall polish, landing card. **v1.0 "delicious."**
- **P6 (post-1.0):** onnx_seq2seq MT (opus-mt pairs, NLLB long tail), transformers.js-v4 interop tier for the web surface, FSRS-6 from revlog, mermaid rendering, OCR, stove chunked-transfer endpoint.

## Feature coverage
### Covered
- RSVP classic mode: ORP red pivot, guide ticks, punctuation dwell, long-word shrink (both donors merged into one reader core)
- Parafoveal ticker mode with Gaussian fade + sigma/window settings (CustomPainter port)
- Scroll mode: windowed rendering, past-word dimming, inline figures, tap-to-seek
- Speak mode: system TTS at T0 (0-byte, every Android), Piper multilingual / Kokoro EN at T2+, streaming sentence-by-sentence with word highlight
- Playback engine: WPM 100-1500, pacing multipliers, wake lock (wakelock_plus), session recording
- All seek surfaces: tap zones, swipes, swipe-up extract, arrow keys, scrub, transport buttons
- Sentinel segments (tables/code/figures pause + show modal + always-skip pref)
- Chapter cards + TOC drawer (EPUB nav/NCX or synthesized from headings)
- Page panel + minimap on wide layouts; context strip
- Translation strip per-segment with persisted per-language layers (mechanism v1 = Brain seam; see degraded)
- Whisper transcription UPGRADED: multilingual tiny/base/small + built-in translate task + language picker + detected-language on the work — the language-learner-via-podcast case works for the first time
- Word-timing audio sync: token-level timestamps -> Alignment rows; RSVP cursor follows audio; tap word seeks audio; both directions
- Podcast audio bar UPGRADED to background playback (just_audio + audio_service, lock-screen controls), ±15/+30, 6 speeds, chapters (podcast:chapters JSON + PSC)
- Episode offline caching to real files, profile-stamped and in the eviction cascade (fixes donor orphan/cross-profile leak)
- Feed subscriptions RSS2/Atom/Media-RSS + auto-discovery (Substack/Medium/YouTube/WP guesses) — direct fetch on native, zero proxies
- Feed hygiene: conditional GET ETag/Last-Modified, 429/503 Retry-After, failure breaker, pull-to-refresh
- Auto-download queue with metered + disk-space guards, re-checked between downloads
- River view: reverse-chronological only, unread/audio/text filters, read tracking, ephemera decay
- Library: debounced search, sorts, filters, pin/rename/delete, progress bars, source lines, feed tiles
- Bulk multi-file + true folder import on native (file_picker directory mode)
- EPUB parser ported pure-Dart (archive+xml): spine walk, nav/NCX TOC, figure blobs, front-matter skip, charset quirks — donor heuristics as test fixtures
- PDF text extraction on native via pdfium (pdfrx) with column/footnote heuristics ported
- Plain-text/MD heuristics (chapter headings, dividers, code blocks, pipe tables)
- Tokenizer ported with donor tests (hyphen split, URL abbreviation, >30-char placeholder, per-token pacing, block start map)
- URL article reader: readability-style container scoring in Dart html; feed-XML detection offers subscribe; direct fetch on native
- Project Gutenberg browser (Gutendex, boilerplate strip, line unwrap) and iTunes podcast directory search
- .ohcourse import — Trellis strict parser is the single authority (schemaVersion, per-type validation, prereq referential integrity, cycle rejection, never half-imports)
- AI passage generation via Brain seam (topic/level/length)
- Extract-to-card flow (tap/drag focus span, instant vocab flag) PLUS new per-word known/learning/new ledger (LingQ mechanic) feeding context-carrying cards
- SM-2 review queue with monotonic-interval floor — Trellis scheduler verbatim, 183 tests unmodified; epoch-day UTC; in-session relearn with cleared inputs
- Prerequisite DAG unlock gating + unlock-is-first-exposure-only + mastery threshold + course map (reborn as the Espalier Wall with due chips and presentable-due FAB)
- Four typed recall items (cloze/qa/discrimination/procedure) with distinct UIs, hints ExpansionTile, rungs, post-reveal sources
- Auto-grading + suggested grade (normalized cloze, discrimination index, keyword coverage; learner self-rating drives SRS — kept as law even with LLM judge)
- Cloze key text-ordering; RSVP math/code stripping; no-remote-fetch markdown/LaTeX rendering (ADR-0005 law kept)
- Two-sided cards with answer absent until reveal; review stats + due badge; NEW full revlog
- Anki export: .apkg native (genanki-faithful, subdecks, stable guids, MathJax) + CSV everywhere incl. web
- AI review assists (explain/define/paraphrase, make-cloze with parser validation) and AI comprehension check — expanded into construction-and-discourse study (explain-back, Socratic follow-ups, graded free recall, generation-effect prompts, incremental cloze)
- BYOK: Anthropic direct + OpenAI-compatible (Ollama/LM Studio/OpenRouter); local endpoints skip egress consent; test-connection
- Consent-gated egress single chokepoint (web proxies, cloud LLM, model downloads with size + metered warning) + what-leaves-your-device screen
- SSRF/URL safety ported and stricter on native (real LAN reachability): scheme/loopback/link-local/private/metadata rejection, mid-stream size caps
- Multi-profile (per-profile prefs/stats/feeds/library/cards/ledger, cascade delete incl. episodes) + parent dashboard + salted-SHA-256 PIN
- Reading stats bar (lifetime words/minutes/avg WPM/sessions)
- Backup: encrypted .ohbk (sanctuary_auth_core, appDomain espalier) superseding donor JSON; BOTH donor formats importable (Trellis .ohbk re-encrypt, ohPrimer JSON sanitized import); startup vault snapshot kept; index-last destructive restore
- OPML import/export (import validates by fetching); reading-list JSON import
- Share/deep-link: ?url= on web kept; Android share-target intake on APK (superior)
- Settings: high contrast, OpenDyslexic bundled (C7 cmap-checked), eviction policy, word timestamps, voice pickers with preview, AI provider
- Storage panel with real disk accounting, per-feed buckets incl. previously-orphaned ones, purge, boot eviction
- Theme auto/light/dark + OS listener + high-contrast/dyslexia modes (fleet conventions)
- Position persistence — structurally fixed: tiny Position row + flush on pause/background, not whole-record rewrites
- PWA offline shell (Flutter web SW, drift-wasm, persist() request, slow-boot spinner per fleet playbook)
- Model download UX: domovoi ResumableTransfer — true Range resume, sha256 fail-closed promote, honest MB/ETA, persistent resume card, cancel keeps partial
- Model memory management platform-aware (desktop holds several, phone one; cooldown retry replaces session-sticky demotion)
- Transcription as checkpointed resumable job with foreground service and kill-anywhere property tests (donor had none — full restart on any failure)
- Modal/dialog accessibility via Flutter semantics + C5 320dp x 3.0 sweep incl. dialogs
- Course repository bundled+imported behind the same seam (Drift-backed; import cache keyed by raw text); paste-JSON import KEPT plus file picker and share-target (fixes Trellis jank)
- Bundled starter courses (Kalman 26-concept + a new language-learning starter)
- Study-ahead affordance answering Trellis's documented empty-app jank — bounded, opt-in, display mastery unchanged
- Behavior + visual test harness: widget/golden/integration + visual-loop skill + oh_fleet_conformance C1-C7
### Degraded
- Web-surface local ML at v1.0: NO in-browser Whisper/translation/Kokoro at launch — browser users get the full T0 app + BYOK cloud LLM + SpeechSynthesis system TTS; the transformers.js-v4 interop tier (whisper-tiny int8 ~41MB, WASM/WebGPU) is Phase 6. Until then a browser-only user cannot transcribe locally, which the donor could do (slowly, unreliably, English-only).
- Translation: v1 mechanism is Brain-seam LLM translation (Qwen2.5 local / stove / BYOK) + Whisper's translate task for speech-to-English — strong for major languages, but NLLB's 200-language long tail is unavailable until the Phase-6 onnxruntime seq2seq engine (opus-mt ~110MB/pair, NLLB-600M ~600-800MB). The UI names the translating model so quality expectations are honest.
- Voice-clone read-aloud: whole-doc synthesize+cache kept via Piper (multilingual, 3-5x realtime, streams immediately vs the donor's 5-15-minute block), but the 4 SpeechT5/CMU-ARCTIC preset voice identities do not carry over.
- Kokoro voice picker: 28 English voices (the ONNX-path reality per the research packet; the donor's ~54-voice claim belonged to the Python path), native-only.
- PDF intake on web: native-only in v1 (pdfium); web PDF waits for a pdf.js interop pass. Web folder (webkitdirectory) import: multi-file picker only.
- diagramMermaid: parsed and displayed as description + source block; true diagram rendering (offline mermaid in a native WebView) is roadmap — the donor parsed it and rendered nothing, so this is parity-plus-honesty, not regression.
- Stove household tier on the web surface: impossible today (stove server has no CORS; https PWA cannot fetch http LAN — packet finding); household brain is native-only until the server grows CORS + a serving-context answer.
- Word-level timestamps on non-English audio: shipped with a documented drift caveat + VAD mitigation (the donor was English-only and never faced this; forced alignment a la WhisperX is out of scope).
- 32-bit (armeabi-v7a) potato phones: full T0 app + whisper-tiny (slow); LiteRT local LLM is arm64-only, so their Brain tiers are stove/BYOK.
### Dropped
- Tesseract OCR fallback for scanned PDFs — no mature Dart/FFI Tesseract path worth one artisan's maintenance; scanned PDFs get an honest 'no text layer found' message with the file kept. Roadmap: tesseract FFI or OCR-via-household-desktop.
- SpeechT5 + x-vector preset voices — a generation behind per the research packet; replaced by Piper/Kokoro rather than ported.
- Dormant encrypted relay sync code — both donors already ship without it (entry points throw); the ADR-0007 file-backup-only stance is retained deliberately; .ohbk is the device-to-device medium.
- Public-CORS-proxy fetching as a primary path — native surfaces fetch direct; the proxy chain survives only as the web surface's consent-gated fallback. (A mechanism removal, listed for completeness.)

## Potato story
The canonical potato: a $90 Android phone, 2GB RAM, intermittent data.

T0 in the browser (no install, no ML): the PWA loads from GitHub Pages, installs to home screen, and works offline via the service worker + drift-wasm. She can read EPUB/TXT/MD/paste (RSVP, ticker, scroll — all modes), follow feeds through the consent-gated proxy chain, stream podcast audio (cross-origin <audio> plays; caching episode bytes needs proxy consent, 300MB-capped as in the donor), import any .ohcourse someone shares — including one her family's desktop distilled — and run the FULL study engine: DAG, four item types, SM-2 with the monotonic floor, extracts, word ledger, Anki CSV export, encrypted .ohbk backup (pure-Dart crypto runs fine in wasm). Read-aloud works via the browser's SpeechSynthesis system voices. What she cannot do: local transcription, local translation, local LLM — the app says so plainly on the 'what runs on this device' screen instead of pretending. If she has an API key, BYOK works from the browser (ohPrimer precedent).

T0 with the APK (same phone, one sideload, ~35MB): everything above gets better — feeds fetch direct with zero proxies, podcast playback goes background with lock-screen controls, any app can share an article or episode straight into Espalier, system TTS reads in her language, .apkg export appears. Still zero models downloaded; the app is complete without them.

T1 (she opts into ML on that phone): whisper-tiny multilingual, a ~41MB one-time download with true resume — transcription runs as a checkpointed foreground-service job at roughly realtime, so a 40-minute episode finishes during a charge, survives screen-off, and NEVER restarts from zero on interruption. Her podcast becomes synced text in her target language; the translate task gives her an English layer; tapped words become ledger cards with audio spans. A local 0.5B LLM is possible but honestly marginal on 2GB — the app recommends the stove instead.

T2 (a mid phone or any desktop): whisper-base/small, Piper voices, Qwen2.5-1.5B via flutter_gemma (Reckon/Peckish precedent) for make-cloze/explain-back offline, two models resident on desktop.

T3 (the household has any desktop): pair once by entering the household phrase — the secret IS the pairing, nothing crosses the wire. Her phone sends the transcript over the LAN stove (port 4663, ChaCha20-Poly1305) and the family desktop's 7B model distills it into a typed .ohcourse and grades her explain-backs. Intermittent internet is irrelevant: the stove is LAN, and every T0 function needs no network at all. The cloud is never load-bearing at any tier.

## ML plan
Per-tier, with packet citations:

T0 (all surfaces): zero models. System TTS (flutter_tts native / SpeechSynthesis web). Keyword-coverage grading (Trellis grading.dart) stands in for the LLM judge.

T1 native (any Android incl. potato): whisper.cpp FFI, multilingual ggml — tiny at the packet's ~41MB int8 class (ggml q5_1 ~32MB), base ~77MB class; language picker + task transcribe|translate + token-level word timestamps; Silero VAD ~2MB onnx gating silence (Careless Whisper hallucination mitigation, per UX packet). whisper.cpp maturity: the packet rates its WASM at 2-3x realtime tiny/base on CPU — native NEON is faster, and it is the fallback-proven engine of the whole local-ASR ecosystem.

T2 native (good phone / desktop): whisper-small ~248MB class; Piper TTS ~60MB/voice (multilingual, CPU 3-5x realtime, MIT — packet's multilingual answer); Kokoro-82M q8 92.4MB (Apache, 28 EN voices — packet corrects the donor's 54-voice claim); Android LLM via flutter_gemma (shipped precedent: Peckish 1.0.0-rc.1, Reckon ^0.13.2) with litert-community Qwen2.5-0.5B (~500MB q8, 'runs in 1-2GB browser memory' per packet — ungated Apache, the fleet's clean-license pick) or 1.5B on 4GB+ phones; desktop LLM via llama.cpp FFI, Qwen2.5-3B/7B-Instruct GGUF q4 (~2-4.5GB).

T2.5 desktop ASR: whisper-large-v3-turbo at the packet's ~563MB q4f16 class for best-quality household transcription.

T3 household: domovoi StoveClient to the family desktop (port 4663, HKDF info openhearth.domovoi.stove.v1, ChaCha20-Poly1305 frames, 1MiB text asks) fronting llama.cpp/Ollama models of any size; BYOK Anthropic / OpenAI-compatible as the explicit cloud rung with egress consent.

Phase 6 additions: (a) onnx_seq2seq engine (onnxruntime FFI + SentencePiece FFI, greedy decode) serving opus-mt int8 ~110MB/pair for common pairs and NLLB-200-distilled-600M (~600-800MB class; packet: >800MB and 2-5s/sentence in-browser — native int8 is smaller and faster) for the 200-language tail; (b) web-surface T1/T2 via transformers.js v4 interop (packet: v4 shipped Feb 2026 with the rewritten C++ WebGPU runtime; whisper-tiny int8 ~41MB; int8 beats q4 below small — packet's quant anomaly). Until Phase 6 the web surface runs no local models, by honest design rather than by janky accident.

## Risks
- FFI build matrix (whisper.cpp/llama.cpp/Piper/onnxruntime x Android arm64+armv7 x Linux/Win/mac) maintained by one artisan — mitigated by pinned submodules, CI cross-compile, prebuilt release artifacts; but it is real ongoing cost the pure-web shape does not pay.
- ffmpeg_kit_flutter is retired upstream; we pin the community fork (PunctumTemporis already ships it) — fallback is a miniaudio FFI decoder for mp3/aac/opus if the fork rots.
- Whisper word-timestamp drift and hallucination on non-English/disfluent audio (packet-documented) — VAD + UI caveat shipped, but the aligned-text promise is softer for exactly the flagship language-learner case; forced alignment is a research-grade add we are NOT committing to.
- flutter_gemma churn: Peckish is on 1.0.0-rc.1, Reckon on 0.13.2 with known sqlite3/grpc constraint friction (visible in Peckish's pubspec comments) — isolated behind the Brain seam so it can never infect the app, but Android local-LLM stability rides a fast-moving dependency.
- Web-surface disappointment: v1.0 web has zero local ML where the donor (jankily) had some — if the 'what runs on this device' honesty screen and Phase-6 commitment aren't front-and-center, browser users may read it as regression.
- Hand-rolled onnx seq2seq decode loop (Phase 6 NLLB/opus-mt) is genuinely hard (KV cache, SentencePiece, beam vs greedy) — correctly kept off the v1.0 critical path, but until it lands the 200-language claim is not redeemable offline.
- Scope: this is the largest app in the fleet (superset of an 8065-line PWA plus a full Flutter app) — mitigated by every phase being independently shippable and the study engine arriving pre-tested, but a 13-week solo estimate has honest +/-40% error bars.
- APK size vs C3: FFI libs + bundled fonts push toward ~35MB — needs ABI splits and a ratcheted budget from day one or the conformance check becomes theatre.
- Stove's 1MiB ask cap means no audio offload to the household desktop in v1 — transcribe-on-desktop results travel by file/.ohbk, which is a manual step the marketing must not oversell as 'seamless'.
- F-Droid: whisper.cpp/llama.cpp/Piper are FLOSS-clean (no ML Kit exclusion) but Flutter reproducibility and model-download-at-runtime will draw anti-feature flags; GitHub Releases APK remains the primary channel (fleet norm).

## Build cost
Honest phased estimate, one artisan + AI agents (fleet velocity as the yardstick: Peckish v0.9 and the sanctuaryAuth fleet rollout each ran multi-week):

P0 bootstrap + study_core (183 green) — 1 week. P1 spine + reader + intake + library = installable alpha APK/PWA — 2-3 weeks. P2 feeds/podcasts/player/river — 2 weeks. P3 whisper.cpp FFI + downloads + checkpointed jobs (the riskiest native work) — 3 weeks. P4 Brain tiers + distillation + discourse — 2 weeks. P5 TTS + backup/migration + polish + Espalier Wall = v1.0 'delicious' — 2 weeks.

Total to first delicious release: ~12-13 part-time weeks / roughly 60-75 agent working sessions, alpha in hand by week 4-5. Error bars +/-40%, dominated by the FFI build matrix (P3). Phase 6 (onnx MT, web transformers.js tier, FSRS) is another 4-6 weeks post-1.0 and gates nothing. Cash cost: $0 — GH Pages hosting, ungated Apache/MIT models, existing signing and landing infrastructure. The premium over the web-stack shape is the native build matrix (~2-3 weeks of P3 + ongoing maintenance); what it buys is the entire T1-T3 ladder actually working on phones, background reliability no PWA can offer, and four fleet libraries consumed instead of rewritten.
