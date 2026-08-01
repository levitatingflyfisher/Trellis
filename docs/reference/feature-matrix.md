# Feature matrix — the "nothing lost" ledger

The commission: a feature **superset** of both donors. This ledger is the
check. Sources: exhaustive donor inventories (`../research/inventory-*.md`,
59 ohPrimer + 23 Trellis features, each with file:line evidence) mapped
through the adopted architecture (`../research/proposal-2.md`).

Statuses: **covered** (parity or better) · **degraded** (kept, worse — how is
stated) · **dropped** (gone, with the reason and the roadmap cure). As phases
land, entries gain a `✅ shipped` mark; until then this is the plan of record.

## Covered (60)

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
- Translation strip per-segment with persisted per-language layers. Mechanism v1, whisper's own built-in translate task (X->EN, timestamp-projected onto the transcript's segments) — this entry previously claimed an LLM-translation mechanism through the Brain boundary; that was never actually built for translation and the claim was wrong (caught auditing ADR-0008). Mechanism v2, ADR-0008 "Babel": a real on-device Marian engine (en->es, `opus-mt-en-es`) — a per-work sentence-indexed store (schema v13), a cancellable/resumable "Translate to Spanish" batch action gated on the model actually being downloaded, and a scroll-mode "Show Spanish" dual display pairing each original sentence with its stored translation, subordinate in style — see degraded for what's still open.
- Whisper transcription UPGRADED: multilingual tiny/base/small + built-in translate task + language picker + detected-language on the work — the language-learner-via-podcast case works for the first time. ADR-0008 shipped the organ the FOUNDING DREAM actually needs (real on-device en->es MT) AND wired it through: the reader can translate a work, show the pairing, and — see below — speak it. See degraded for the honesty caveats that come with that.
- Speak-in-Spanish (ADR-0008 "Babel" Phase 4): with Show Spanish on, a session-only toggle makes the speak loop substitute each STORED translated sentence for whichever voice is speaking (system TTS or the downloaded Supertonic voice) while the karaoke cursor keeps advancing through the ORIGINAL sentences — a sentence with no stored translation (or a stale one) speaks English from the original, no gap. `supertonicSupportedLangs` widened from English-only to include Spanish — see degraded for the verdict behind that and what remains unverified.
- Word-timing audio sync: token-level timestamps -> Alignment rows; RSVP cursor follows audio; tap word seeks audio; both directions
- Podcast audio bar: ±15/+30, 6 speeds, sleep timer (durations or end-of-episode, fade, shake-to-extend — Campaign 1 ✅ shipped), smart resume (Campaign 1 ✅ shipped), per-podcast speed/skip-intro/skip-outro (Campaign 1 ✅ shipped), Up Next queue with auto-advance (Campaign 1 ✅ shipped). Corrected (Campaign 7): this row previously also claimed podcast chapters ("podcast:chapters JSON + PSC") — `comms_core`'s feed parser DOES parse `<podcast:chapters>`/`<psc:chapters>` into `FeedItem.chapters`/`chaptersUrl`, but `feed_ingest.dart`'s `ingestFeedItems` never reads either field; the parse exists, nothing downstream consumes it, and no chapters UI for feed episodes exists. Wiring that is out of scope for the campaign that found it (`docs/adr/0013-audiobooks-are-a-door.md`). Corrected earlier: this row previously also claimed background playback via audio_service and lock-screen controls; that was never wired (`just_audio_player.dart` names it explicitly deferred) — see Degraded.
- Episode offline caching to real files, profile-stamped, works never deleted by storage reclaim — only the audio FILE, per a feed's own keep-latest-N setting, archived rows dimmed with a re-download affordance (Campaign 1 Phase 4, "archive, never forget" ✅ shipped). Corrected: this row previously claimed the file-level eviction already existed "in the eviction cascade"; the pre-existing cascade (`deleteWork`/`deleteFeedCascade`) only ever removed database rows, never an audio file — Campaign 1 is what actually adds file-level eviction. Corrected again (Campaign 6): through 8a1af19 the cached file was never actually PLAYED from — `playWork` called `setUrl(work.sourceUrl)` unconditionally, so the local copy existed only to feed transcription and streaming happened regardless of what was on disk. `PlayerController.playWork` now prefers the local file over the network URL whenever one exists (`docs/adr/0012-offline-dsp.md`), so eviction/re-download now compose with playback for real: the file's presence or absence actually changes what plays. The download itself no longer requires requesting a transcript either — a standalone "Download" item on each audio row's menu (through the same one consent dialog transcribe uses) fetches the audio for offline listening on its own; a quiet indicator marks a row already on disk, and the item is not offered once one is.
- Feed subscriptions RSS2/Atom/Media-RSS + auto-discovery (Substack/Medium/YouTube/WP guesses) — direct fetch on native, zero proxies
- Feed hygiene: conditional GET ETag/Last-Modified, 429/503 Retry-After, failure breaker, pull-to-refresh. UPGRADED beyond both donors: RFC 5005 paged-feed archive following — an explicit, capped, per-feed "Fetch older episodes" action recovers episodes a host's RSS truncation hid, with an honest note when the feed offers no archive at all (see `docs/reference/feed-archives.md`)
- Beyond both donors (Campaign 5, ADR-0011, the Inoreader/Miniflux lesson) — per-feed rules: skip / mark-read-on-arrival / auto-keep, matched on title or description (contains/not-contains, case-insensitive), evaluated in order at ingest, before an item ever becomes a row. Editable from each feed's own settings screen.
- Beyond both donors (Campaign 5, ADR-0011) — cross-feed dedup: a canonical-URL match (after tracker-parameter stripping) or an exact-normalized title within 48h hides the younger copy of a story syndicated across feeds; never within the same feed (a repost is the author's own choice). Suppressed rows are hidden, never deleted, and un-hide themselves if the canonical row they duplicate is later removed.
- Beyond both donors (Campaign 5, ADR-0011, the Miniflux lesson) — tracker-parameter stripping: a curated, documented list (utm_*, ad-platform click ids, newsletter send tracking) stripped from stored article links and dedup comparisons; never from feed fetch URLs or episode audio URLs, whose query params can be load-bearing.
- River view: reverse-chronological only, unread/audio/text filters, read tracking, ephemera decay. Campaign 5 (ADR-0011) added the triage verbs Keep and Let it pass (swipe or overflow menu — every row now has one; text/article rows had none before), both undoable to the exact prior state; no new "Kept" filter chip exists, by law — kept things live in the library.
- Library: pin/delete, progress bars. Corrected: this row previously also claimed "debounced search, sorts, ... rename, ... source lines, feed tiles" — none of that existed; `LibraryScreen` had no search, sort, or filter of any kind, and no rename action, before Campaign 5. What Campaign 5 (ADR-0011) actually built: instant (not debounced) title search, a filter model (type/feed/read-state/pinned, any combination) with saveable, reorderable, deletable named views shown as chips. Sort controls, rename, and per-row feed/source display are still not built — not removed by this campaign, never present.
- Text intake has no bulk/folder-import door — corrected (Campaign 7): this
  row previously claimed "Bulk multi-file + true folder import on native
  (file_picker directory mode)" for text works. No such door was ever built:
  grepping the app for `getDirectoryPath`/multi-file `pickFiles` outside
  single-file pickers (EPUB, course import, OPML, backup) turns up nothing.
  Every text-intake door (paste, EPUB, web, Gutenberg) is single-source. The
  claim was never backed by code (`docs/adr/0013-audiobooks-are-a-door.md`
  §Context) — the audiobook door below is the app's first real bulk/folder
  import, for audio, not text.
- EPUB parser ported pure-Dart (archive+xml): spine walk, nav/NCX TOC, figure blobs, front-matter skip, charset quirks — donor heuristics as test fixtures
- PDF text extraction on native via pdfium (pdfrx) with column/footnote heuristics ported
- Plain-text/MD heuristics (chapter headings, dividers, code blocks, pipe tables)
- Tokenizer ported with donor tests (hyphen split, URL abbreviation, >30-char placeholder, per-token pacing, block start map)
- URL article reader: readability-style container scoring in Dart html; feed-XML detection offers subscribe; direct fetch on native
- Project Gutenberg browser (Gutendex, boilerplate strip, line unwrap) and iTunes podcast directory search
- .ohcourse import — Trellis strict parser is the single authority (schemaVersion, per-type validation, prereq referential integrity, cycle rejection, never half-imports)
- AI passage generation via Brain seam (topic/level/length)
- Extract-to-card flow (tap/drag focus span, instant vocab flag) PLUS new per-word known/learning/new ledger (LingQ mechanic) feeding context-carrying cards
- SM-2 review queue with monotonic-interval floor — Trellis scheduler verbatim, sealed; epoch-day UTC; in-session relearn with cleared inputs. The "183 tests" figure elsewhere in this repo's docs (VISION.md, ADR-0001) names the FULL donor Trellis app's suite — domain plus Flutter UI/session/backup/export — as the eventual porting target, not what has landed. As of the study-crown campaign (2026-08), `packages/study_core`'s actual landed suite is 104 tests across sm2_scheduler_test.dart (23), grading_test.dart (42), curriculum_parser_test.dart (38) and progress_unlock_test.dart (1) — verified by running `flutter test` in the package, not read off a comment. The remaining ~132 load-bearing invariants (line below) are still to port into `app/`.
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
- Settings: high contrast, eviction policy, word timestamps, voice pickers with preview, AI provider. **Honesty fix (Campaign 4, ADR-0010):** this line previously also claimed "OpenDyslexic bundled (C7 cmap-checked)" and that no settings screen existed — neither was true. The pubspec bundles exactly two faces (Lora, Nunito), both C7-checked; OpenDyslexic was never added. A real reader-typography settings screen ✅ shipped in Campaign 4 Phase 1 (`reader_typography_settings_screen.dart`) — see the "Beyond both donors — reader depth" section below for what it actually covers.
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
- Audiobooks (Campaign 7 ✅ shipped, `docs/adr/0013-audiobooks-are-a-door.md`):
  pick a folder's worth of MP3/M4A/M4B/OGG/OPUS/FLAC files (multi-select —
  the folder-vs-files distinction collapses on Android, see the ADR),
  natural-sort ordering (the "1, 2, 10" problem, RED-first tested pure
  function; disc/track-tag ordering is real and tested but unwired — no
  probe populates a tag yet), an editable guessed title, copy into app
  storage (the referenced-vs-copied verdict is "copied, always" — this
  app's one shipped native tier can't back a durable reference). M4B/M4A
  chapter atoms (chpl, verified against ffmpeg's own reader) parsed
  live when the Chapters drawer opens; an MP3 or a chapterless M4B is one
  chapter per file. Playback goes through the SAME player every episode
  uses — gapless multi-file auto-advance via `just_audio`'s own playlist
  engine (no auto-advance code exists; the engine does it), shared sleep
  timer/smart-resume/Up-Next-queue, per-book speed override (a parallel
  column, not a generalized `Feeds` one — see the ADR), one-touch
  bookmark reusing the study crown's Captures table (file-index-tagged).
  Position law: (fileIdx, offset), never a single cross-file millisecond.
  Library tile shows New/Started/Finished + a file-count-coarse progress
  bar (never time-precise — a file's duration is learned lazily, the
  first time it plays). The read↔listen handoff for a TRANSCRIBED
  audiobook (this campaign's own stretch goal) was investigated and NOT
  built — three named structural blockers in `TranscribeCoordinator`/
  `Alignments`, recorded precisely in the ADR's own Phase 3 section rather
  than forced.

## Degraded (12)

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
- Translation: v1's whisper-transcript mechanism is unchanged (X->EN only, timestamp-projected onto the transcript's segments) — a prior version of this entry claimed a Brain-routed LLM-translation mechanism (Qwen2.5 local / stove / BYOK); that was never built and the claim was wrong (caught auditing ADR-0008, corrected there). ADR-0008 "Babel" shipped a SECOND mechanism end to end: opus-mt-en-es (int8, ~246MB, not the ~110MB first guessed) behind a per-work sentence store, a downloaded-model gate, a resumable batch action, a scroll-mode dual display, and speak-in-Spanish through both voices. Two things remain genuinely unverified, not just "not built": (1) the ONNX Runtime sessions — Marian's AND Supertonic's — have never opened on a real device, only proven against faked session boundaries and, for Marian specifically, against the real model in Python; (2) Supertonic speaking Spanish is an UNTESTED capability, not a confirmed one — the M1 voice embedding was reviewed for English only, `supertonicSupportedLangs` was widened to `{'en','es'}` on the strength of an architectural finding (the model and engine already support all 5 of Supertonic v2's languages; there is no separate Spanish voice file upstream to gate on instead), and nobody has heard the result. NLLB's 200-language long tail remains unavailable. The UI names the translating model so quality expectations stay honest.
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
- Background podcast playback (audio_service, lock-screen controls): not wired — `just_audio_player.dart` names it deferred by design, and `audio_service` isn't a pubspec dependency. Foreground playback (the mini player bar, sleep timer, per-podcast settings, Up Next) is unaffected; what's missing is continuing audio and transport controls when the app is backgrounded or the screen is locked.
- Auto-download queue: not wired (Campaign 5, ADR-0011 §5 — corrected from a prior "Covered" claim of "metered + disk-space guards, re-checked between downloads", none of which was ever built). `Feeds.autoDownload` is a column with a DAO setter and zero callers; no filter UI exists to set it from; no episode-audio-download path exists anywhere outside the transcription pipeline, which is itself gated behind `confirmDownload`'s consent screen. Left unwired deliberately, not for lack of time: an automatic refresh-time download would bypass ADR-0003 law 6's one egress consent gate silently, a sovereignty-law violation independent of whether metered/disk guards are also added.

## Dropped (4)

- Tesseract OCR fallback for scanned PDFs — no mature Dart/FFI Tesseract path worth one artisan's maintenance; scanned PDFs get an honest 'no text layer found' message with the file kept. Roadmap: tesseract FFI or OCR-via-household-desktop.
- SpeechT5 + x-vector preset voices — a generation behind per the research packet; replaced by Supertonic/Kokoro rather than ported (Piper was the original replacement, ADR-0006; Supertonic replaced Piper in turn, ADR-0007).
- Dormant encrypted relay sync code — both donors already ship without it (entry points throw); the file-backup-only stance is retained deliberately; .ohbk is the device-to-device medium.
- Public-CORS-proxy fetching as a primary path — native surfaces fetch direct; the proxy chain survives only as the web surface's consent-gated fallback. (A mechanism removal, listed for completeness.)

## Beyond both donors — the study crown (2026-08, ADR-0009)

Neither donor had these; they are not donor-parity items and are listed
separately for that reason. Statuses follow the same convention as above.

- ✅ shipped — **FSRS-5 as an opt-in scheduler, reachable end to end.** A
  second pure scheduler function (`study_core/lib/src/fsrs_scheduler.dart`)
  beside the sealed SM-2 one, same (state, grade, day) -> new-state shape.
  Per-profile `Profiles.scheduler` ('classic'|'fsrs') is set from a real
  settings menu on the Courses tab (one honest sentence of copy on the way
  in; instant, no-dialog on the way back out) and `study_session_screen.dart`
  now reads it and dispatches grading accordingly — Classic byte-for-byte
  as it always graded, FSRS through `scheduleFsrs`, seeded lazily from a
  card's classic history on its first FSRS grade. A card's FSRS half rides
  the existing `Cards.stateJson` blob under `fsrs`-prefixed keys, so
  switching schedulers never erases the other's stored progress — grading
  under one leaves the other's fields exactly as they were. **Stated scope
  limit, not a gap**: curriculum progression (unlock/mastery) stays
  Classic-`CardState`-based regardless of the active scheduler —
  `study_core`'s prereq DAG (`progress.dart`) is untouched surface this
  campaign did not extend, so a course studied entirely under FSRS still
  unlocks/masters exactly as a Classic profile's would.
- ✅ shipped — **Read<->listen handoff verbs.** "Listen from here" (reader
  app bar, when a work has aligned audio) and "Read from here" (karaoke
  view app bar) over the SAME `Positions` row and the SAME
  `Spine.positionAtAudioTime`/`projectAudioTime` projections the player
  and reader already used implicitly — made explicit and discoverable,
  not new state. The round trip holds at sentence (segment) granularity,
  not word — `Alignment` carries no word-level timing, a pre-existing
  property of this data model, not a regression introduced here (property-
  tested in `packages/loom_core/test/cursor_law_test.dart`).
- ✅ shipped, degraded — **Capture-while-listening.** One-tap capture on
  the player surface (`MiniPlayerBar`) and the karaoke view, sentence-
  snapped via the same alignment projection (never a raw ±15s guess — the
  Snipd quality bar named in ADR-0009). A capture taken before a
  transcript exists still saves, unbound, and is backfilled automatically
  once transcription completes. **Not built**: the playback-notification
  capture action (`audio_service` isn't a dependency; adding one plus a
  background-playback lifecycle to satisfy one sub-bullet was judged out
  of scope for an additive campaign — see ADR-0009) and "make this an
  extract" (there is no extract/passage-authoring entity in this
  checkout to feed — see the next entry).
- ✅ shipped, degraded — **Daily review (zero-effort resurfacing).** A
  two-button (Soon/Eventually -> the sealed scheduler's again/good)
  surface over the word ledger and captures, in a new `DailyReviewCards`
  table keyed by (profileId, sourceType, sourceId) rather than a
  once-and-for-all foreign key, since a review item comes from either
  source. **Degraded**: the spec's "front = passage context with the
  focus span blanked" needs an extract-authoring mechanism this checkout
  does not have — `grep -rin extract app/lib/features/reader` found no
  extract-creation UI, and the word ledger (`WordLedger`) is word-only, no
  `segmentIdx`/`wordIdx`, no SM-2 fields of its own. The front actually
  shipped is honestly plainer: a bare word for a ledger entry, the bound
  sentence for a capture that has one. Note the natural fit that emerged:
  captures (above) already carry passage context once bound, so they are
  a real (if partial) realization of "extract" for this queue — not
  invented to fill the gap, just the closest thing that already existed.

## Beyond both donors — offline DSP (Campaign 6, ADR-0012)

Neither donor had this — Overcast's Smart Speed/Voice Boost is the
comparison point, not a donor feature, so it's listed here rather than
claimed as covered-with-shape against a donor row that never existed.

- ✅ shipped — **Offline trim-silence & even-out-volume, on downloaded
  episodes, on this device.** Architectural rather than imitative:
  streaming playback is never touched; a conservative
  `silenceremove` (only silences over 1.5s, shrunk to 0.5s — a natural
  pause is never trimmed) chained with single-pass `loudnorm` to the
  podcast-standard -16 LUFS runs once, offline, right after an episode
  actually downloads (never on the stream). Fail-closed: a sanity
  check (non-zero size, a plausible duration) gates the atomic
  promote, so a bad encode leaves the original completely untouched.
  A per-feed toggle (default: the household setting, also configurable)
  is the only door — there is no separate manual "process now" action,
  a stated scope limit matching the feature's own "processed on
  download" promise. The lifetime "time saved" counter (the Overcast-
  style loyalty number) sums every processed episode's own saved
  seconds, shown only when positive (the fleet's positive-framing law).
  **Also required, and shipped alongside it, not separately**: the
  local-file playback foundation this feature turned out to need —
  through 8a1af19 downloaded episode audio was never actually read for
  playback (`playWork` streamed the network URL unconditionally); a
  standalone "Download" door decoupled from transcription (previously
  the only way audio ever landed on disk); and a licensing fix (the
  pinned ffmpeg dependency was Full-GPL, contradicting ADR-0007's
  "MIT-clean APK" claim — swapped for the same publisher's LGPL-only
  audio variant, ~22MB smaller per arm64 ABI as a side effect). Full
  accounting in `docs/adr/0012-offline-dsp.md`.

## Beyond both donors — reader depth (2026-08, ADR-0010)

Neither donor had a fused typography-settings screen, restored priming
visuals as a single toggle, an on-device dictionary, spoiler-safe recaps,
or a private year-in-review — listed separately for the same reason as
the study crown above. Statuses follow the same convention.

- ✅ shipped — **Reader typography settings.** A real settings screen
  (`reader_typography_settings_screen.dart`) with live preview: typeface
  (Lora/Nunito — the two faces actually bundled, both C7 cmap-checked;
  never OpenDyslexic, see the honesty fix above), line height, font
  scale, justification. Applies to the scroll/print reader only — RSVP
  and the ticker keep their own tuned displays, which never needed this
  control. **Honest ceiling**: justified text has no hyphenation (the
  reader's own per-word `Wrap`, not `Text.justify`), so wide gaps can
  appear on narrow screens or short lines; the settings copy says so.
- ✅ shipped — **Parafoveal mode and the ORP anchor fix.** The donor's
  lost third RSVP display (its own name "ticker" was already taken by
  this app's existing classic mode's test vocabulary, so it ships here
  as "Parafoveal") — Gaussian neighbor fade/scale/blur ported verbatim
  from the donor's math, a sigma slider, and guide+tick marks in classic
  mode. **Not a stronger claim than the donor's own CSS achieves**: the
  ORP anchor reserves a constant before-pivot width per ORP bucket,
  removing glyph-width jitter — it is a jitter fix, not a perfect 50%
  anchor, since the free-width after-span can still shift a row's center
  for words of very different lengths (see ADR-0010's own honest
  accounting).
- ✅ shipped — **Follow-along guided pacing (scroll mode).** Reuses the
  RSVP cursor/timer wholesale (`_wordIdx`/`_step`) to auto-scroll the
  currently-read segment into view (`Scrollable.ensureVisible`, the
  karaoke view's own `_followPlayback` pattern) — no second highlighter,
  no second dwell path.
- ✅ shipped — **On-device dictionary lookup.** A pure-Dart StarDict
  parser (`packages/stardict_core`) with real dictzip random access (no
  whole-file decompress), one pinned starter dictionary
  (`wiktionary-en-en-stardict`, dual CC-BY-SA-3.0/GFDL-1.3,
  sha256-verified), and a tap-hold definition sheet that ABSORBS the
  reader's existing "add to word ledger" long-press rather than stacking
  a second gesture on the same word. **Honest ceiling**: the sheet's
  empty state cannot distinguish "no dictionary downloaded" from "word
  not in the one you have" — the information exists in `DeviceServices`
  but isn't threaded through yet.
- ✅ shipped — **"Catch me up?" session recaps.** A dismissible chip on
  a work reopened after more than 3 UTC days untouched with real (>10%,
  <100%) progress, offering a Brain-generated spoiler-safe summary in a
  bottom sheet — never saved, gone when the sheet closes. Spoiler-safety
  is two layers: the prompt is assembled from segments strictly before
  the reader's own cursor (a pure, independently tested filter), and the
  prompt itself also instructs the model not to invent anything beyond
  what it was shown. Reuses the distill flow's exact consent order
  (gesture → cloud-tier egress consent naming the host → Brain call).
- ✅ shipped, degraded — **Trellis Echo (lifetime totals + a private
  year-in-review).** The spec asked for three headline totals — words
  read, minutes listened, works finished — and only the third is
  computable from this schema; verified, not assumed (orientation found
  no words-read counter and no listening-duration tracking anywhere).
  Extended the household layer's existing lifetime-totals dashboard
  (`HouseholdDao.lifetimeBuiltOf`, pre-dates this campaign) with an
  `activeReadingDays` tile from a new per-day append-only table
  (`ReadingDays`) rather than building a parallel query. Echo itself is
  a new, reader-facing (never PIN-gated) screen off the Courses tab:
  works finished, active reading days, words collected, cards
  mastered/reviewed, captures, and audio position **reached** (not
  "minutes listened" — furthest position reached, summed per work, is
  what this schema actually tracks; see `LifetimeBuilt`'s own doc
  comment). A shareable card (RepaintBoundary → PNG → share sheet) is
  native only; the web tier gets the screen with no share button.
  **Degraded**: the spec's "Export highlights" doesn't exist as
  specced — there is no highlight/passage/marginalia table in this
  schema, so the export is named for what it actually produces (the
  word ledger plus captures, plain Markdown + JSON). **Cut**: "top
  works"/"top feeds" — no already-reviewed cheap aggregation exists for
  either; left for a future pass rather than building one unverified
  this pass.

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
