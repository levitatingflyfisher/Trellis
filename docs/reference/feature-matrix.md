# Feature matrix — the "nothing lost" ledger

The commission: a feature **superset** of both donors. This ledger is the
check. Sources: exhaustive donor inventories (`../research/inventory-*.md`,
59 ohPrimer + 23 Trellis features, each with file:line evidence) mapped
through the adopted architecture (`../research/proposal-2.md`).

Statuses: **covered** (parity or better) · **degraded** (kept, worse — how is
stated) · **dropped** (gone, with the reason and the roadmap cure). As phases
land, entries gain a `✅ shipped` mark; until then this is the plan of record.

## Covered (58)

- RSVP classic mode: ORP red pivot, guide ticks, punctuation dwell, long-word shrink (both donors merged into one reader core)
- Parafoveal ticker mode with Gaussian fade + sigma/window settings (CustomPainter port)
- Scroll mode: windowed rendering, past-word dimming, inline figures, tap-to-seek
- Speak mode: sentence-unit architecture ✅ shipped (ADR-0006) — system TTS
  at T0 (0-byte, every platform) now ticks sentence-by-sentence instead of
  whole-paragraph (the fix for Chrome's long-utterance stall). One
  downloadable Supertonic voice (English, MIT engine, OpenRAIL-M weights,
  Android — ADR-0007 replaced the original sherpa-onnx/Piper rung so the
  APK stays MIT-clean) joined the models door with a verified license, and
  the gapless synthesis-ahead pipeline (reusing the podcast player's own
  audio queue) IS threaded into the reader's actual speak loop — a real
  fork on engine type, a settings escape to pin the system voice on
  purpose, generation fencing across both paths — proven end to end
  through fakes (`reader_speak_synthesis_test.dart`). Not yet proven on a
  real device: the ONNX Runtime sessions actually opening and producing
  audible PCM. No UI for pause (the engine/pipeline support it; the existing
  speak-toggle is binary and a third state would be new surface, declined
  this pass). NOT planned to ship at all in v1: word highlight (no engine
  exposes word timing — sentence-exact is the permanent contract, not a
  placeholder), a multilingual voice, and Kokoro — recorded, not built, in
  ADR-0006.
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

## Degraded (10)

- Web-surface fetching is CORS-bound (measured from the deployed origin,
  2026-08-12): the PWA fetches directly from the browser with **no proxy
  fallback, by design** (structural privacy — the donor's consent-gated
  public-proxy chain was deliberately not wired; its ladder survives in
  comms_core behind a consent that never grants). Any site that doesn't opt
  into cross-origin reads is refused by the browser: nearly every article
  site (Substack included), Substack RSS, and gutenberg.org book files
  (gutendex search itself works). The intake doors state this upfront and
  the failure sentence names the browser, not the site. Always-working web
  lanes: paste, EPUB import, .ohcourse import, OPML import, BYOK; podcast
  hosts that serve permissive CORS still fetch fine. The installed app
  fetches everything directly. **The Skein exception:** serve the PWA
  from `packages/skein` on the family desktop (`dart run skein
  --web-root app/build/web`, localhost-only) and this wall comes down —
  the page and its fetcher share one origin, so every fetch above works,
  same-origin, same as the installed app. LAN/phone access to that same
  daemon is an open problem (docs/adr/0005), not shipped.
- Web-surface local ML at v1.0: NO in-browser Whisper/translation/Kokoro at launch — browser users get the full T0 app + BYOK cloud LLM + SpeechSynthesis system TTS; the transformers.js-v4 interop tier (whisper-tiny int8 ~41MB, WASM/WebGPU) is Phase 6. Until then a browser-only user cannot transcribe locally, which the donor could do (slowly, unreliably, English-only).
- Translation: v1 mechanism is Brain-seam LLM translation (Qwen2.5 local / stove / BYOK) + Whisper's translate task for speech-to-English — strong for major languages, but NLLB's 200-language long tail is unavailable until the Phase-6 onnxruntime seq2seq engine (opus-mt ~110MB/pair, NLLB-600M ~600-800MB). The UI names the translating model so quality expectations are honest.
- Voice-clone read-aloud: the donor's 4 SpeechT5/CMU-ARCTIC preset voice
  identities do not carry over — v1's Supertonic voice is one English
  voice, not a clone gallery (ADR-0007). Whole-doc synthesize+cache,
  multilingual voices, and measured throughput are unbuilt/unmeasured
  (ADR-0006 ships the sentence-level pipeline; per-work caching is
  unstarted; ADR-0007 notes widening to the model's other four covered
  languages is a registry-only change once another voice is reviewed).
- Kokoro voice picker: unbuilt. ADR-0006 records Kokoro (a ~686MB fp32
  bundle) as the quality rung above the starter voice, deliberately
  deferred — the donor's ~54-voice Python-path claim never applied to the
  ONNX path either (28 English voices is the real ceiling there).
- PDF intake on web: native-only in v1 (pdfium); web PDF waits for a pdf.js interop pass. Web folder (webkitdirectory) import: multi-file picker only.
- diagramMermaid: parsed and displayed as description + source block; true diagram rendering (offline mermaid in a native WebView) is roadmap — the donor parsed it and rendered nothing, so this is parity-plus-honesty, not regression.
- Stove household tier on the web surface: impossible today (stove server has no CORS; https PWA cannot fetch http LAN — packet finding); household brain is native-only until the server grows CORS + a serving-context answer.
- Word-level timestamps on non-English audio: shipped with a documented drift caveat + VAD mitigation (the donor was English-only and never faced this; forced alignment a la WhisperX is out of scope).
- 32-bit (armeabi-v7a) potato phones: full T0 app + whisper-tiny (slow); LiteRT local LLM is arm64-only, so their Brain tiers are stove/BYOK.

## Dropped (4)

- Tesseract OCR fallback for scanned PDFs — no mature Dart/FFI Tesseract path worth one artisan's maintenance; scanned PDFs get an honest 'no text layer found' message with the file kept. Roadmap: tesseract FFI or OCR-via-household-desktop.
- SpeechT5 + x-vector preset voices — a generation behind per the research packet; replaced by Supertonic/Kokoro rather than ported (Piper was the original replacement, ADR-0006; Supertonic replaced Piper in turn, ADR-0007).
- Dormant encrypted relay sync code — both donors already ship without it (entry points throw); the file-backup-only stance is retained deliberately; .ohbk is the device-to-device medium.
- Public-CORS-proxy fetching as a primary path — native surfaces fetch direct; the proxy chain survives only as the web surface's consent-gated fallback. (A mechanism removal, listed for completeness.)

## Donor inventories (the checklist this ledger must satisfy)

### ohPrimer (59)

- **Classic RSVP mode** — One word at a time with red ORP pivot letter, guide ticks, punctuation-driven pacing delays, long-word font shrink.
- **Parafoveal (ticker) mode** — Center word plus ±2-8 neighbors faded by Gaussian opacity/scale/blur; sigma and window sliders.
- **Scroll mode** — Windowed 800-word flowing text, past-word dimming with incremental reconciliation, inline figure images, tap word to seek.
- **Speak mode (Kokoro TTS)** — Reads block text aloud via Kokoro-82M, speed tied to WPM, approximate word highlight interpolated over audio duration.
- **Playback engine** — Play/pause/toggle, WPM 100-1500, pacing multipliers, screen wake-lock, session recording into per-profile stats.
- **Seek surfaces** — Centralized seekTo; tap zones (left/center/right), swipe gestures, swipe-up extract, arrow keys, progress-bar scrubbing, transport buttons.
- **Sentinel segments** — Tables/code/figures pause playback with a banner; Show opens modal (image or pre), Skip advances, always-skip pref.
- **Chapter cards + TOC drawer** — Brief chapter-title overlay on crossing; TOC drawer from EPUB nav/NCX or synthesized from headings, opens paused, resumes on close.
- **Page panel + minimap** — Desktop side panel showing current page text with clickable words, canvas minimap with caret, auto-open pref at ≥900px.
- **Context strip** — Toggleable strip showing ±few surrounding words under the display, current word highlighted.
- **Translation strip (NLLB)** — Per-block on-device translation into 22 languages, inline language picker, per-book per-language cache persisted on the book record.
- **Voice-clone read-aloud (SpeechT5)** — 🎤 synthesizes entire doc in one of 4 CMU ARCTIC preset voices; WAV cached in episodes store keyed clone:bookId:preset.
- **Audio transcription (Whisper)** — Any audio file → 16kHz resample → whisper-tiny.en (English-only) → text book in library; optional per-word timestamps.
- **Word-timing audio sync** — Whisper word chunks aligned to doc words; RSVP cursor follows audio playback; tapping a word seeks the audio.
- **Podcast audio bar** — Persistent player: ±15/+30 skip, seek slider, 6 playback speeds, chapter list (podcast:chapters JSON + PSC inline), offline download toggle.
- **Episode offline caching** — ⬇ caches episode blob in IDB episodes store; cached playback via object URL; playedAt bumped for eviction.
- **Feed subscriptions (RSS/Atom)** — Subscribe by any URL with feed auto-discovery (link tags, Substack/Medium/YouTube/WP guesses); parses RSS2/Atom/Media-RSS enclosures.
- **Feed refresh hygiene** — Conditional GET (ETag/Last-Modified), 429/503 Retry-After throttling, 404→broken, 5-failure breaker, per-feed spinner, pull-to-refresh.
- **Auto-download queue** — Per-feed opt-in caches latest N episodes; skips metered connections and >80% quota; re-checks quota between downloads.
- **River view** — Aggregated newest-first stream across all feeds with unread/audio/text filters and read tracking (capped 500 URLs).
- **Library screen** — Search (debounced), 5 sorts, filters (in-progress/unstarted/finished/pinned/feeds), pin/rename/delete, progress bars, source lines, feed tiles.
- **Bulk/folder import** — Multi-file and webkitdirectory folder ingestion of epub/pdf/txt/md with per-file allSettled results toast.
- **EPUB parsing** — JSZip + DOMParser: spine walk, nav/NCX TOC, figure blobs extracted, front-matter detection/skip, charset handling, path-quirk image lookup.
- **PDF parsing + OCR fallback** — pdf.js text layer with 2-column detection and footnote stripping; scanned PDFs offered Tesseract OCR (~10MB, on-device) with per-page progress.
- **Plain-text heuristics** — Chapter headings, dividers, indented code blocks, pipe tables become blocks/segments; zero-width char strip.
- **Tokenizer** — Hyphen splitting, URL abbreviation with original preserved, >30-char token skip with placeholder, per-token pacing, segment sentinels, block start map.
- **URL article reader** — Fetch (direct then CORS proxies), charset-aware decode, readability-style extraction (best-scoring container), feed-XML detection offers subscribe instead.
- **Project Gutenberg browser** — Gutendex search + 10 curated picks, covers, plain-text download with boilerplate strip and line unwrap, proxy fallback.
- **Podcast directory search** — iTunes Search API modal; tapping a show subscribes to its RSS feed.
- **.ohcourse import** — Course nodes become a readable book (chapters+TOC); every cloze/qa/discrimination/procedure item becomes a linked two-sided review card.
- **AI content generation** — Topic+reading-level+length modal generates a passage via configured LLM, saved to library as source kind 'ai'.
- **Extract-to-card flow** — E key/✧/swipe-up opens preview; tap or drag tokens to pick focus span; saves passage card. V flags vocab word instantly.
- **SM-2 review queue** — Due-card queue via byNextReview index; Again/Hard/Good/Easy with interval previews; skip/delete; grade history appended.
- **Two-sided cards** — Passage/vocab fronts blank the focus span (answer not in DOM until reveal); cloze cards blur answer until tap.
- **Review stats** — Day streak, retention %, total cards; incremental accumulators per grade, full rescan on delete; home-screen due badge.
- **Anki CSV export** — All extracts exported as Front/Back/Tags CSV with cloze/vocab/passage-specific formats and book tags.
- **AI review assists** — Explain/Define/Paraphrase button per card; 'Make cloze' generates a fill-in-blank card from a passage via LLM.
- **AI comprehension check** — After 100+ words read, banner offers LLM-generated question; free-text answer graded PASS/REVIEW with explanation.
- **AI providers (BYOK)** — Anthropic direct-browser API or any OpenAI-compatible endpoint (Ollama/LM Studio/OpenRouter); local endpoints skip egress consent; test-connection button.
- **Consent-gated egress** — Single sticky per-profile chokepoint for anything leaving the device: CORS proxies, cloud LLMs, model downloads (with metered warning).
- **SSRF/URL safety** — Rejects non-http(s) schemes, loopback/link-local/private-LAN/metadata hosts before any fetch; 25MB text and 300MB audio caps, 8MB XML cap.
- **Multi-profile** — Named reader profiles with word-based PIDs, own prefs/stats/feeds/library; switching tears down open book; delete cascades books+extracts.
- **Parent dashboard + PIN** — Per-family reading stats (words/minutes/sessions/books/cards); optional salted-SHA-256 PIN with legacy plaintext upgrade.
- **Reading stats bar** — Per-profile lifetime words read, minutes, average WPM, session count under the reader.
- **Backup export/import JSON** — Profile+books (figures stripped)+extracts to JSON file; import sanitizes prototype-pollution keys, re-scopes ids, dedupes, merges feeds.
- **OPML import/export** — Subscriptions interchange with other RSS readers; import validates each feed by fetching before committing.
- **Reading-list import** — Paste or URL-fetch a JSON array of {title,url}; each fetched into the library sequentially.
- **Share-by-URL + deep link** — Share button emits raw source URL (navigator.share/clipboard); opening app with ?url=/?add= auto-loads into reader+library.
- **Settings modal** — Accessibility (high contrast, OpenDyslexic), eviction policy, translation, word timestamps, voice clone, Kokoro voice picker (~54 voices) with preview, AI provider.
- **Storage panel + eviction** — Quota usage with 80% warning, per-feed cached-audio breakdown, purge per-feed/all; boot-time eviction by keepN or days policy.
- **Theme system** — Auto/light/dark cycle per profile, OS-change listener, theme-color meta sync, high-contrast and dyslexia data attributes.
- **Position persistence** — Debounced 4s position autosave with change-skip, flush on stop/visibility-hidden/doc-swap; resume on library open.
- **PWA offline shell** — SW: network-first shell, stale-while-revalidate for fonts/esm.sh/jsdelivr; persistent-storage request; online/offline toasts.
- **ML worker architecture** — Blob-URL module worker runs translate/tts/kokoro/transcribe off-thread; per-task sticky fallback flags; 120s default watchdog; transferable buffers.
- **Model memory management** — Worker evictExcept keeps ONE model resident (disposes others); main thread free-before-allocate sibling eviction for NLLB↔SpeechT5 (iOS ~1GB budget).
- **Model download UX** — Sticky consent naming size (MODEL_SIZES_MB), cellular/Data-Saver warning, cumulative MB/% status with Cancel, 90s no-progress stall watchdog, resume-from-browser-cache retry.
- **Modal accessibility** — Central MutationObserver marks dialogs, traps Tab, restores focus on close, Escape closes Settings; extract preview owns keyboard.
- **Dormant encrypted sync (removed)** — HKDF/AES-GCM seed-channel relay sync retained but entry points throw; product decision is file-based backup only.
- **Behavior + visual test harness** — 11 Playwright behavior tests (TOC pause, two-sided cards, extract preview, ohcourse, share); screenshot/reflow scripts; 108 node tests in rebuild/.

### Trellis (23)

- **SM-2 scheduler with monotonic-interval floor** — Pure function scheduleSm2: grade->q (again=2,hard=3,good=4,easy=5); EF'=EF+(0.1-(5-q)(0.08+(5-q)*0.02)) clamped >=1.3; q<3 lapse resets interval=0/reps=0/due=today/lapses++; success base=firstIntervalDays|6|round(interval*newEase), hard x0.6, easy x1.3, then floor max(newInterval, oldInterval+1) so successful recall never shrinks or plateaus.
- **Whole-epoch-day UTC time base** — All scheduling in whole days since Unix epoch UTC (epochDayNow) — timezone-stable, deterministic tests.
- **Node progress + mastery threshold** — Item mastered iff intervalDays>=7 (masteryIntervalDays default); item due iff no card yet OR dueEpochDay<=today; node mastery=mastered/total.
- **Prerequisite DAG unlock gating** — Node unlocked iff every prereq node's mastery==1.0 (all items at 7-day interval). nodeUnlockedFrom variant reads precomputed progress map to avoid O(n^2) rebuild cost.
- **Unlock-is-first-exposure-only rule** — Session queue skips a locked node only if unstarted: a node with any existing card stays studyable, so a prereq interval dip never buries owned reviews. Course map counts due only for started-or-unlocked nodes.
- **Study session flow with in-session relearn** — Queue = per unlocked node with due items: intake step then due item steps; graded card saved fire-and-forget; a lapse (due today) re-queues the item at session end with its typed responses cleared.
- **Four recall item types with distinct UIs** — cloze ({{cN::ans}} blanks, per-blank TextField + check icons), qa (free-text + reveal answer/rubric), discrimination (radio choices, correct/wrong coloring, explanation), procedure (free-text + numbered steps reveal). Hints in pre-reveal ExpansionTile; sources shown post-reveal; rung chip (1=cued..4=free).
- **Auto-grading + suggested-grade model** — normalizeAnswer (lowercase/trim/collapse-ws); gradeCloze all-blanks exact-normalized (missing key=wrong, extras ignored); gradeDiscrimination index equality; keywordCoverage=found/total anchors (empty anchors skipped, 0 anchors->0.0); suggestGrade: <=0 again, <0.5 hard, <0.85 good, else easy; no-anchor free recall: empty attempt->again else good. Suggestion only highlights a button — learner self-rates.
- **Cloze key text-ordering** — clozeKeysInTextOrder: blanks listed in first-occurrence text order (not lexicographic, so c10 doesn't sort before c2), missing answer keys appended.
- **RSVP speed reader** — One-word streamer with ORP pivot (len<=1:0, <=5:1, <=9:2, else 3) pinned to center guides; dwell multipliers (sentence-end 2.2, ;: 1.6, comma/paren 1.4, >12 chars 1.3); delay=60000/wpm*dwell; WPM slider 150-800 default 350; play/pause/replay, progress, didUpdateWidget resets on new text.
- **RSVP text stripping** — strippedForRsvp: $$..$$->[equation], $..$->[eqn], code/markdown symbols/LaTeX commands dropped, whitespace collapsed, memoized. Rendered MdText cards remain the surface for actual math.
- **.ohcourse parser (schemaVersion 1.0, strict/tolerant)** — Required: schemaVersion=='1.0', course id+title, non-empty nodes; node id+title+intake+non-empty items; item id+rung(int)+type. Optional w/ defaults: subtitle/subject/level/description, srsDefaults{algorithm'sm2',initialEase 2.5,firstIntervalDays 1}, node summary/prereqs/diagramMermaid, item hints/sources. Per-type: cloze{text,answers non-empty str->str}, qa{prompt,answer,acceptable[],rubric?}, discrimination{prompt,choices non-empty,correctIndex in-range,explanation?}, procedure{prompt,steps non-empty,rubric?}. Unknown top-level (provenance) ignored. Path-qualified FormatException messages.
- **Prereq referential integrity + cycle rejection** — Import rejects unknown prereq ids, self-prereqs, and cycles (DFS color-map, cycle path in error) — a cycle would make nodes permanently unreachable.
- **Course repository (bundled + imported)** — Bundled courses from assets/courses/index.json (deterministic, not AssetManifest), parsed once; imported courses in prefs ('imported_ids' index + 'course:<id>' raw JSON), imported overrides bundled by id, cache keyed by raw text so re-import/restore is picked up; corrupt course skipped not fatal; list sorted by title.
- **Paste-JSON course import UI** — Library '+' opens dialog; parse errors shown inline; success invalidates coursesProvider + snackbar; controller disposed (leak fix).
- **Card repository (SM-2 state persistence)** — 'cards:<courseId>' -> JSON map itemId->{ease,intervalDays,dueEpochDay,reps,lapses}; malformed entries skipped individually; corrupt blob returns {} instead of crashing startup; keyPrefix public for backup enumeration.
- **Course map screen** — Overall mastery % bar; per-node tiles with lock/book/check avatar, mastery bar, due-count chip; Study FAB with total actually-presentable due count; progress computed once per node per rebuild.
- **Encrypted .ohbk backup/restore (sanctuary)** — BackupEnvelope{app:'trellis',schemaVersion:1,createdAt,payload:{importedIds,courses,cards}}; cards dumped for ALL course ids incl. bundled, course bodies only for imported; destructive restore wipes owned keys then writes data before index (never observe id w/o data); preview describeBackup validates like restore; appDomain 'trellis', aadContext 'trellis-backup/v1'; restore raw-string round-trip (no re-serialize).
- **Silent startup vault snapshot** — Post-frame fire-and-forget: if newest vault snapshot >7 days old and a key exists, take one — safety net for the non-atomic prefs restore.
- **Anki .apkg export (native only)** — Pure-Dart genanki-faithful sqlite build: Trellis Basic + Trellis Cloze models, subdeck per node 'Course::Node', tags 'courseId nodeId rung-N', guid=base64url(sha1('courseId:itemId')[0:8]), sha1 checksum of stripped first field, cloze card per distinct {{cN::}} ordinal, $-math -> MathJax \(..\)/\[..\], hints/rubric/sources appended to Back; scheduling left to Anki; zip(collection.anki2+media); shared via share_plus; conditional-export facade hides button on web.
- **No-remote-fetch markdown rendering** — MdText (gpt_markdown: markdown + LaTeX + tables) with imageBuilder returning a placeholder icon — untrusted course markdown can never trigger a network GET (ADR-0005). Intake split into lazily-built paragraph blocks.
- **Bundled starter course** — multi-target-tracking / Kalman-filter .ohcourse (26 concepts, ~463KB) ships in assets so first launch has content.
- **Load-bearing invariant tests (port these)** — Exact SM-2 values (1,6,round(i*EF')), hard<good<easy with UPDATED ease (28/50/68 from base 20), ease floor 1.3, monotonic-growth-under-repeated-Hard property, lapse-only shrink, purity/no-mutation; unlocked-concept-never-relocks property (30 Hard reviews, must eventually unlock); parser rejection matrix; grading boundaries (0.5->good, 0.85->easy); lapsed-item-comes-back-blank + hint-not-sticky regressions; RSVP passage-change reset; corrupt-store tolerance; import-cache invalidation by raw text; apkg structure; backup wiring/serializer round-trip; fleet conformance + goldens. 132 test() cases.
