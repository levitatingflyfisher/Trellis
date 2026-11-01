# Feature matrix — the "nothing lost" ledger

The commission: a feature **superset** of both donors. This ledger is the
check. Sources: exhaustive donor inventories (`../research/inventory-*.md`,
59 ohPrimer + 23 Trellis features, each with file:line evidence) mapped
through the adopted architecture (`../research/proposal-2.md`).

Statuses: **covered** (parity or better) · **degraded** (kept, worse — how is
stated) · **dropped** (gone, with the reason and the roadmap cure). As phases
land, entries gain a `✅ shipped` mark; until then this is the plan of record.

## Covered (61)

- RSVP classic mode: ORP red pivot, guide ticks, punctuation dwell, long-word shrink (both donors merged into one reader core)
- Nearby words (the donors' Parafoveal/ticker mode) with Gaussian fade + a Focus spread slider (the donor's sigma), shown as a labelled chip under Words mode; the mode, speed, nearby words and spread are remembered per reader
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
  purpose (Use the system voice, in Reading settings), generation fencing across both paths — proven end to end
  through fakes (`reader_speak_synthesis_test.dart`). Not yet proven on a
  real device: the ONNX Runtime sessions actually opening and producing
  audible PCM. (1.5.8: the voice registers at T1, the tier the app runs
  at, so a downloaded voice is actually used: `registry_test.dart`,
  `device_services_real_tier_test.dart`. 1.5.9: heard in a release build
  on an x86_64 emulator, with an episode loaded; an arm64 phone is still
  a release check. See ADR-0007’s last section.) No UI for pause (the engine/pipeline support it; the existing
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
- Translation strip per-segment with persisted per-language layers. Mechanism v1, whisper's own built-in translate task (X->EN, timestamp-projected onto the transcript's segments) — this entry previously claimed an LLM-translation mechanism through the Brain boundary; that was never actually built for translation and the claim was wrong (caught auditing ADR-0008). Mechanism v2, ADR-0008 "Babel": a real on-device Marian engine, en->es only at first (`opus-mt-en-es`) — a per-work sentence-indexed store, a cancellable/resumable batch action gated on the model actually being downloaded, and a scroll-mode dual display pairing each original sentence with its stored translation. Campaign 8 "Babel widens" (ADR-0014) generalized ALL of it: a language-parameterized picker over whatever the work's own declared source language and downloaded pairs allow (en<->de, en<->ru, both directions; en<->zh reverse only — see degraded), a per-work source-language selector, and speak-in-⟨language⟩ verified per script family (Latin/Cyrillic/CJK), each correctly forced onto the system voice where Supertonic's own coverage (`{'en','es'}`) doesn't reach. A CJK segmentation baseline (`loom_core/src/cjk.dart`) replaces the old single-`…`-placeholder collapse for space-less scripts. See degraded for what's still open. 1.5.5 (ADR-0008's last section): 25 pairs with English on one end (fr, de, es, it, pt, nl, ru, zh, ar, hi, uk both ways; ja, ko, pl into English), X->Y via English, download from the reader's Translate sheet, the source language resolved from the work, then its feed, then whisper, and a killed run resuming on the next open.
- Whisper transcription UPGRADED: multilingual tiny/base/small + built-in translate task + language picker + detected-language on the work — the language-learner-via-podcast case works for the first time. ADR-0008 shipped the organ the FOUNDING DREAM actually needs (real on-device en->es MT) AND wired it through: the reader can translate a work, show the pairing, and — see below — speak it. See degraded for the honesty caveats that come with that.
- Speak-in-Spanish (ADR-0008 "Babel" Phase 4): with Show Spanish on, a session-only toggle makes the speak loop substitute each STORED translated sentence for whichever voice is speaking (system TTS or the downloaded Supertonic voice) while the karaoke cursor keeps advancing through the ORIGINAL sentences — a sentence with no stored translation (or a stale one) speaks English from the original, no gap. `supertonicSupportedLangs` widened from English-only to include Spanish — see degraded for the verdict behind that and what remains unverified.
- Word-timing audio sync: token-level timestamps -> Alignment rows; RSVP cursor follows audio; tap word seeks audio; both directions
- Podcast audio bar: ±15/+30, 6 speeds, sleep timer (durations or end-of-episode, fade, shake-to-extend — Campaign 1 ✅ shipped), smart resume (Campaign 1 ✅ shipped), per-podcast speed/skip-intro/skip-outro (Campaign 1 ✅ shipped), a queue (the Queue tab) with auto-advance (Campaign 1 ✅ shipped). Corrected (Campaign 7): this row previously also claimed podcast chapters ("podcast:chapters JSON + PSC") — `comms_core`'s feed parser DOES parse `<podcast:chapters>`/`<psc:chapters>` into `FeedItem.chapters`/`chaptersUrl`, but `feed_ingest.dart`'s `ingestFeedItems` never reads either field; the parse exists, nothing downstream consumes it, and no chapters UI for feed episodes exists. Wiring that is out of scope for the campaign that found it (`docs/adr/0013-audiobooks-are-a-door.md`). Corrected earlier: this row previously also claimed background playback via audio_service and lock-screen controls; that was never wired (`just_audio_player.dart` named it explicitly deferred) — see the next row, shipped Campaign 9 Phase 2e. Corrected (Campaign 9 "the shakedown," Phase 2a–d): the mini bar used to render nothing at all after an app restart (`current == null` → `SizedBox.shrink`, no thread back to what was playing); it now rehydrates PAUSED at the last-played work's saved position (`Profiles.readerPrefsJson`'s `lastPlayedWorkId`, no schema hop, no autoplay ever), and a first Play tap correctly dispatches to `playWork`/`playAudiobook` depending on which kind was rehydrated. The queue, once reachable ONLY from inside the mini player bar and then from a door in Latest's menu, is now the Queue tab (1.5.3: Latest · Queue · Library · Courses, opening on Latest); the mini bar's queue button switches to it, and it reloads when the playing episode changes. History (what played) has its door on the Queue bar, beside what plays next; it left Latest's menu. "Up Next" is now called Queue on screen (naming ruling).
- Background podcast playback: lock-screen and pull-down-tray transport controls (Campaign 9 Phase 2e, ADR-0015 Decision 3) — `just_audio_background`'s `JustAudioBackground.init()` runs once at startup (Android/iOS; a no-op stub keeps the web build unchanged), and every episode/audiobook/rehydrated play tags its audio with the work's id/title, the feed's title as album, and its downloaded artwork when one exists (`lockScreenTagFor`, unit-tested pure). The Android manifest gained the package's own required service + media-button receiver; `FOREGROUND_SERVICE_MEDIA_PLAYBACK`, already declared and unused, is now true. **Honesty note**: everything above is proven up to the tag reaching the player — lock-screen RENDERING itself is device-only and this row does not claim it verified; it awaits the user's next device test.
- Episode offline caching to real files, profile-stamped, works never deleted by storage reclaim — only the audio FILE, per a feed's own keep-latest-N setting, archived rows dimmed with a re-download affordance (Campaign 1 Phase 4, "archive, never forget" ✅ shipped). Corrected: this row previously claimed the file-level eviction already existed "in the eviction cascade"; the pre-existing cascade (`deleteWork`/`deleteFeedCascade`) only ever removed database rows, never an audio file — Campaign 1 is what actually adds file-level eviction. Corrected again (Campaign 6): through 8a1af19 the cached file was never actually PLAYED from — `playWork` called `setUrl(work.sourceUrl)` unconditionally, so the local copy existed only to feed transcription and streaming happened regardless of what was on disk. `PlayerController.playWork` now prefers the local file over the network URL whenever one exists (`docs/adr/0012-offline-dsp.md`), so eviction/re-download now compose with playback for real: the file's presence or absence actually changes what plays. The download itself no longer requires requesting a transcript either — a standalone "Download" item on each audio row's menu (through the same one consent dialog transcribe uses) fetches the audio for offline listening on its own; a quiet indicator marks a row already on disk, and the item is not offered once one is.
- Feed subscriptions RSS2/Atom/Media-RSS + auto-discovery (Substack/Medium/YouTube/WP guesses) — direct fetch on native, zero proxies
- Feed hygiene: conditional GET ETag/Last-Modified, 429/503 Retry-After, failure breaker, pull-to-refresh, and on Android a background check about every 4 hours through WorkManager (ADR-0018: battery not low, Wi-Fi only by default, backoff honoured, no notification; the Subscriptions header says when feeds were last checked). Not on the web build. UPGRADED beyond both donors: RFC 5005 paged-feed archive following — an explicit, capped, per-feed "Fetch older episodes" action recovers episodes a host's RSS truncation hid, with an honest note when the feed offers no archive at all (see `docs/reference/feed-archives.md`)
- Beyond both donors (Campaign 5, ADR-0011, the Inoreader/Miniflux lesson) — per-feed rules: skip / mark-read-on-arrival / auto-keep, matched on title or description (contains/not-contains, case-insensitive), evaluated in order at ingest, before an item ever becomes a row. Editable from each feed's own settings screen.
- Beyond both donors (Campaign 5, ADR-0011) — cross-feed dedup: a canonical-URL match (after tracker-parameter stripping) or an exact-normalized title within 48h hides the younger copy of a story syndicated across feeds; never within the same feed (a repost is the author's own choice). Suppressed rows are hidden, never deleted, and un-hide themselves if the canonical row they duplicate is later removed.
- Beyond both donors (Campaign 5, ADR-0011, the Miniflux lesson) — tracker-parameter stripping: a curated, documented list (utm_*, ad-platform click ids, newsletter send tracking) stripped from stored article links and dedup comparisons; never from feed fetch URLs or episode audio URLs, whose query params can be load-bearing.
- Latest (the donors' river; "River" was retired as a coined word, and "Inbox" by the naming ruling of ADR-0019): reverse-chronological by publish date only, unread/audio/text filters, read tracking. A permanent archive (ADR-0019, superseding ADR-0003 law 2): nothing decays and nothing is hidden by age; schema v27 un-hid whatever the retired 30-day sweep had hidden, and restoring an older backup does the same. Rows the old sweep had already deleted are gone from the database; a feed that still lists them re-adds them on refresh. Read 60 rows at a time by keyset, with the next page fetched as the list nears its end; a row action re-reads that row, a bulk change re-reads only what is loaded, and a publish-time index keeps the first page fast on a 20k-episode archive. A quiet "New since you last looked" line marks rows published since the profile's previous visit (a cold start or a return from the background, not a tab switch: Latest keeps its pages and place across tabs); no count, no badge. Campaign 5 (ADR-0011) added the triage verbs Keep and Let it pass (in the overflow menu; every row has one; text/article rows had none before), both undoable to the exact prior state; no new "Kept" filter chip exists, by law — kept things live in the library.
- Episode rows you can tell apart (ADR-0016 step 1): one shared row for Latest and the podcast page. Played rows fade (title in the muted text colour, artwork dimmed; a test pins 4.5:1 contrast in light and dark), a half-heard episode shows a thin bar and "23 min left", every row that knows its length shows it (`itunes:duration` is now parsed at ingest, and the player's measured length still overwrites it), and small worded markers say New, Downloaded, In Queue and Transcript. Per-episode artwork (`itunes:image` on the item) is fetched at ingest for the newest 20 distinct images that differ from the show's, named by URL so a shared image downloads once; older rows fall back to the show's art. "Played" is a recorded fact (`episodes.finished_at_ms`, schema v23): set when playback ends or enters its last 30 s, or by Mark played; Mark unplayed clears it and the saved position. Mark played never promotes the work (ADR-0003 law 2). **Not built**: the Video marker exists but the parser still drops non-audio enclosures, so it never shows. Auto-download landed with ADR-0018; see the Auto-download row.
- The podcast page (ADR-0016 step 1): a show's own episodes as a place to listen from. Rows play, download (through the one consent dialog) and queue; newest or oldest first, remembered per show; "Play from here" puts this episode and the unplayed ones after it, in the order shown, at the front of the Queue and plays it; "Add unplayed to Queue" appends the rest; "Podcast settings" opens the show's settings. The failing-feed reason and the RFC 5005 "Fetch older episodes" footer stay. The Queue advances on its own only through what the listener put there (and, with "keep finished episodes" on, now moves past the episode that just ended instead of replaying it).
- Library: pin/delete, progress bars. Corrected: this row previously also claimed "debounced search, sorts, ... rename, ... source lines, feed tiles" — none of that existed; `LibraryScreen` had no search, sort, or filter of any kind, and no rename action, before Campaign 5. What Campaign 5 (ADR-0011) actually built: instant (not debounced) title search, a filter model (type/feed/read-state/pinned, any combination) with saveable, reorderable, deletable named views shown as chips. Sort controls, rename, and per-row feed/source display are still not built — not removed by this campaign, never present. Changed (board-0161, owner 12 Nov: "what is library if 'latest' has all, text, and audio?" and "library filter search didn't seem to work"): Latest is what arrives from your shows, newest first; the Library is what you keep. A plain line under each title says so. The Library's chips are its own kinds, one tap each and only those it holds: Books, Articles, Texts (pasted or imported), Audiobooks, Episodes (kept as they came) and Made episodes; they wrap, so none sits off a narrow screen. A made episode the person asked for is kept, so it is in the Library; one made ahead by a show's switch arrives like any episode and make ahead may take its room back. Made episodes made before 1.6.x's change keep their old state (Keep puts one in the Library). Search: the words went into a field inside the Filter sheet, which covered the list they filtered, so nothing on screen answered them (`features/library_search_test.dart` reproduces it). The Library now has Latest's own search bar and search screen, the same code (`SearchScreen`, `SearchStore`), kept to what the Library holds, with no shows section; the Filter sheet keeps read state, pinned and show, and Saved views. A saved view from before keeps its other parts and drops its words and any kind it no longer names. The line, the search bar and the chips scroll with the rows on both screens, so a short screen at large text keeps room for the list (`features/library_kinds_test.dart`, `db/search_store_test.dart`).
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
- PDF with a text layer, native tiers (1.6.0): PDFium through dart:ffi behind a seam (`app/lib/features/intake/pdf_reader*.dart`; the `pdfium_flutter` binary plugin only, not the `pdfrx` viewer), and a pure rebuild of reading order in `intake_core` (`pdf_blocks.dart`): paragraphs, headings by type size, two columns, running heads and page numbers dropped, words broken at a line end made whole. Lands as a book through "Import a file" or the share sheet. **Degraded, honestly:** pages set in more than two columns keep the file's order and are named on the work's page; footnotes are not kept apart from the body; tables are not rebuilt; a file that is only pictures of pages is refused in plain words (OCR is the next step); not on the web tier, which has no PDFium.
- Plain-text/MD heuristics (chapter headings, dividers, code blocks, pipe tables)
- Tokenizer ported with donor tests (hyphen split, URL abbreviation, >30-char placeholder, per-token pacing, block start map)
- URL article reader: readability-style container scoring in Dart html; feed-XML detection offers subscribe; direct fetch on native
- Project Gutenberg browser (Gutendex, boilerplate strip, line unwrap) and iTunes podcast directory search
- .ohcourse import — Trellis strict parser is the single authority (schemaVersion, per-type validation, prereq referential integrity, cycle rejection, never half-imports)
- AI passage generation via Brain seam (topic/level/length)
- Extract-to-card flow (tap/drag focus span, instant vocab flag) PLUS new per-word known/learning/new ledger (LingQ mechanic) feeding context-carrying cards
- SM-2 review queue with monotonic-interval floor — Trellis scheduler verbatim, sealed; epoch-day UTC; in-session relearn with cleared inputs. The "183 tests" figure elsewhere in this repo's docs (VISION.md, ADR-0001) names the FULL donor Trellis app's suite — domain plus Flutter UI/session/backup/export — as the eventual porting target, not what has landed. As of the study-crown campaign (2026-08), `packages/study_core`'s actual landed suite is 104 tests across sm2_scheduler_test.dart (23), grading_test.dart (42), curriculum_parser_test.dart (38) and progress_unlock_test.dart (1) — verified by running `flutter test` in the package, not read off a comment. The remaining ~132 load-bearing invariants (line below) are still to port into `app/`.
- Prerequisite DAG unlock gating + unlock-is-first-exposure-only + mastery threshold + course map (the donor's espalier wall, with due chips and presentable-due FAB; its ripeness ramp darkens steadily from pale green to deep terracotta so mastery reads without hue)
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
- Backup: encrypted .ohbk (sanctuary_auth_core, appDomain espalier) superseding donor JSON; BOTH donor formats importable (Trellis .ohbk re-encrypt, ohPrimer JSON sanitized import); startup vault snapshot kept; index-last destructive restore; the phrase is issued, never presupposed: "No phrase yet? Make one" mints it with the fleet generator (`OpenHearthMnemonic.generate` via `EspalierBackup.newPhrase`), shows it (sanctuary_backup_ui `SeedPhraseModal`) and asks it back before it fills the field, and a phrase typed from memory is asked back once before the first write. Every backup is re-opened in memory before it is saved, and only a blob that decrypts back to the exact payload is saved and reported ("Backup saved and checked."). Once confirmed, the phrase is kept in the OS keychain through the fleet's `SecureKeyStore` (`oh_mnemonic_v1` + `oh_seed_ack_v1`, the sanctuary_backup_ui apps' key model; `BackupCustody` in `app/lib/features/backup/`), so later backups ask for nothing; a restore or Trellis import whose file was made under other words asks for those words. A keychain that cannot be read degrades to asking every time. Until the phrase is kept, a persistent but dismissible "Finish setup: save your recovery phrase" line sits above the tabs with a Set up door to Backup (operator ruling 48); a dismissal is remembered on the device
- OPML import/export (import validates by fetching); reading-list JSON import
- Share/deep-link: ?url= on web kept; Android share-target intake on APK (superior)
- Settings: high contrast, eviction policy, word timestamps, voice pickers with preview, AI provider. **Honesty fix (Campaign 4, ADR-0010):** this line previously also claimed "OpenDyslexic bundled (C7 cmap-checked)" and that no settings screen existed — neither was true. The pubspec bundles exactly two faces (Lora, Nunito), both C7-checked; OpenDyslexic was never added. A real reader-typography settings screen ✅ shipped in Campaign 4 Phase 1 (`reader_typography_settings_screen.dart`) — see the "Beyond both donors — reader depth" section below for what it actually covers.
- Storage panel with real disk accounting, per-feed buckets incl. previously-orphaned ones, purge, boot eviction
- Theme: light, dark or follow the phone (the default), the first group in Settings (Follow phone, Light, Dark; two taps from any tab: Settings, then the choice; it replaced an app-bar "Auto" button whose purpose was a mystery until tapped, then a group in every tab's ⋮), stored per device + high-contrast/dyslexia modes (fleet conventions)
- Position persistence — structurally fixed: tiny Position row + flush on pause/background, not whole-record rewrites
- PWA offline shell (Flutter web SW, drift-wasm, persist() request, slow-boot spinner per fleet playbook)
- Model download UX: domovoi ResumableTransfer — true Range resume, sha256 fail-closed promote, honest MB/ETA, persistent resume card, cancel keeps partial
- Model memory management platform-aware (desktop holds several, phone one; cooldown retry replaces session-sticky demotion)
- Transcription as checkpointed resumable job with foreground service and kill-anywhere property tests (donor had none — full restart on any failure)
- Modal/dialog accessibility via Flutter semantics + C5 320dp x 3.0 sweep incl. dialogs
- Course repository bundled+imported behind the same seam (Drift-backed; import cache keyed by raw text); paste-JSON import KEPT plus file picker and share-target (fixes Trellis jank)
- Bundled example course (Kalman), offered as an example on a tap and never installed as the reader’s own; no language-learning starter was made
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

## Degraded (11)

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
- Translation: v1's whisper-transcript mechanism is unchanged (X->EN only, timestamp-projected onto the transcript's segments) — a prior version of this entry claimed a Brain-routed LLM-translation mechanism (a local model / stove / BYOK); that was never built and the claim was wrong (caught auditing ADR-0008, corrected there). ADR-0008 "Babel" shipped a SECOND mechanism, en->es only; Campaign 8 "Babel widens" (ADR-0014) generalized it to any registered pair. Shipped pairs: en<->de, en<->ru (both directions, verified excellent), zh->en (verified excellent), en->zh (verified usable but demoted — see below). Evaluated and NOT shipped: en<->pt (no clean-licensed ONNX conversion clears the trust ladder), en<->jap (pure `<pad>`-token collapse at decode step one; incoherent even past that — Japanese needs a Brain, not the offline floor). Three things remain genuinely unverified or deliberately withheld, not just "not built": (1) the ONNX Runtime sessions — Marian's AND Supertonic's — have never opened on a real device, only proven against faked session boundaries and, for Marian specifically, against the real models in Python; (2) Supertonic speaking Spanish (or any of the five languages `supertonicSupportedLangs` architecturally claims) is UNTESTED, not confirmed — nobody has heard the result, and de/ru/zh route through the system voice entirely regardless, since Supertonic's own coverage never reached them; (3) `opus-mt-en-zh` (English->Chinese) is registered nowhere — a golden-test render of the scroll-mode display showed the translated Chinese text as tofu boxes (the app's bundled fonts carry no CJK glyphs, and a measured 8.3MB single-region font subset doesn't fit the remaining APK size budget), so the pair is withheld until either is fixed; `opus-mt-zh-en` (English output) is unaffected. A `BrainTranslator` rung (chunked Brain requests, strict JSON parsing, per-sentence fail-closed) is built and fully tested but has zero call sites in the live app — no tier ladder, consent routing, or UI picker reaches it yet (ADR-0014 Phase 5). NLLB's 200-language long tail remains unavailable. The UI names the translating model so quality expectations stay honest. Superseded in part by 1.5.5: en->zh, en->ar and en->hi are now registered, relying on Android's system fonts for display, which nobody has seen on a device. pt ships through en-ROMANCE with `>>pt<<`, and ja->en through a newer `ja` model, quality unchecked. Still missing: en->ja, en->ko, en->pl (no trusted ONNX export). Gap (1) above is narrower since 1.5.7 and 1.5.9: release builds keep ONNX Runtime’s Java classes (`android_keep_classes_test.dart`), and in 1.5.9 a release build on an x86_64 emulator ran both a Marian pair (en→ru) and the Supertonic voice; an arm64 phone is a release check (ADR-0020).
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
- A language change in the middle of an episode: **not handled.** Every window is decoded in one language, the work's or its show's, else the one whisper detects on the first window with words, so a passage in another language comes out written in the locked one's spelling. Checking again cheaply needs whisper's own confidence for each window (token probabilities and the no-speech probability, both already computed as it decodes); the native shim does not export them yet, so nothing is built. Detecting the language of every window would cost a second encoder pass each, on every episode.
- 32-bit (armeabi-v7a) potato phones: full T0 app + whisper-tiny (slow); LiteRT local LLM is arm64-only, so their Brain tiers are stove/BYOK.
- Auto-download queue: built (ADR-0018), Android only. A per-show switch, "Download new episodes", on the podcast's settings page, turned on through the one consent dialog (ADR-0003 law 6: the consent is given once, at the switch, for up to 3 per check on Wi-Fi only). After a check finds something new, WorkManager runs a pass only on an unmetered network. The pass fetches the newest min(3, keep-latest) new rows through the download coordinator, so they get job rows, show on the Jobs screen and fall under keep-latest eviction. **Degraded vs the donor**: no disk-quota guard (dart:io has no cheap free-space call, ADR-0017); a full disk fails the job with its own reason. History: before ADR-0018 this row said the flag was left unwired on purpose, because a refresh-time download would have bypassed the consent gate. Moving the consent to the switch is what answers that.

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
- ✅ shipped (1.5.3) — **Read a transcript without playing.** A
  transcribed episode's row (Latest, a show's page, History and search)
  has Read beside Play. It opens the transcript view for that work from
  the database, whatever is playing: titled "Transcript", nothing lit
  unless that episode is the one in the player, and a tap on a line plays
  the episode from there (`PlayerController.playWorkAt`, which starts at
  the line with no blip from the resume point). The mini player's synced
  text opens the same view, live. The Queue and Library rows are their
  own widgets and do not offer Read yet.
- **Make new episodes ahead, for shows you pick** (ADR-0021). A switch on
  a show's page, off by default. New episodes are translated and voiced
  ahead so the row's second button plays at once. On Wi-Fi while charging
  only, at most 3 waiting per show, with a storage limit (2 GB by default)
  that removes the oldest made-ahead audio first and never touches what
  you made by tapping or marked Keep. Android only lets this start while
  the app is open or a job is already running, so a phone left alone with
  Trellis closed makes nothing. Not on the web.
- **Listen in the learning language, in one tap, from the list.** An
  episode's row has a second button beside Play, on every list that
  shows episodes: Latest, a show's page, the Queue, the Library, History
  and search results. Play is unchanged and plays the original at once.
  The second button is the episode in the language being learned, and
  it is one of three things. Not made yet: a tap makes it (transcribe,
  translate, speak, save), after the one consent dialog when anything
  must be downloaded, without leaving the list. Being made: the button
  shows a ring and how far the stage is, and a tap offers Stop. Ready: a
  tap plays it. With no learning language chosen the button is a
  translate glyph and the first tap asks which language. It names the
  language in full where the row has room and by its two-letter code on
  a narrow phone; its tooltip and screen-reader label always say the
  whole sentence ("Listen in French", "Making it in French: translating,
  40%", "Play in French"). There is no button where the episode cannot
  be made in that language: no translator from the episode's language,
  no voice that can be saved, an episode already in that language, a
  text item, an audiobook, an episode that is itself a made translation,
  and the whole web tier. One episode is made at a time; a second tap on
  another row puts that episode in line and says so. The progress
  belongs to one owner for the whole app (`ListenJobs`), so it is the
  same on every list and survives leaving the list. A finished episode
  plays by itself only when the app is in front and nothing else is
  playing; otherwise the app says it is ready and the button plays it.
  On the episode's page the learning language is a row of its language
  list that makes it (the four choices became one Play, one Read and
  that list in board-0161), with the progress and Stop under Play;
  Change learning language is in the page's ⋮. Proven through tests with stand-in engines
  (`listen_row_button_test.dart`, `listen_wiring_test.dart`,
  `work_page_four_choices_test.dart`); **not yet run on a real phone**.
  **Not built**: making picked shows ahead of time.
  Board-0126: the voice that saves it is the downloaded voice where it
  speaks the language and is here, else the phone's own text-to-speech
  voice, so any language the phone speaks and a translator reaches can
  be kept (Russian and German from English; Japanese once an English to
  Japanese translator exists). The language dialog names what it leaves
  out and why, with a button to Android's text-to-speech settings
  (`listen_languages_test.dart`, `phone_saved_voice_test.dart`,
  `learning_language_dialog_test.dart`). The browser cannot record its
  voices, so the web still has none of this: see
  `docs/reference/tts-voices.md`.
- **The learning language as a setting** (board-0128). Settings has a
  row "Learning language" that names the choice ("Spanish", or "Not
  chosen"). It opens the same list
  as an episode's page. With no episode in view the list is every
  language some episode could be made in: a voice on this phone can save
  it, and a translator reaches it from English or from any language
  Trellis translates. The note under it still says why a language is
  missing, and the current choice is ticked. Change beside the language
  on an episode's page shows even when only one language is offered, so
  the list and its note can always be reached
  (`learning_language_setting_test.dart`,
  `work_page_four_choices_test.dart`). Not on the web.
- **How clearly the voice speaks** (the founding request's follow-up:
  "choose how much they enunciate"). Settings › Learning has a row under
  Learning language with four steps, Natural by default. Each step slows
  the voice, lengthens the pause written after each sentence and each
  paragraph, and on the downloaded voice asks for more denoising steps:

  | Step | Pace | Pause after a sentence / a paragraph | Downloaded voice steps |
  |---|---|---|---|
  | Natural | 1.0 (the voice's own) | 250 / 450 ms | 8 |
  | Clear | 0.9 | 500 / 800 ms | 12 |
  | Slow and clear | 0.75 | 800 / 1200 ms | 12 |
  | Very slow | 0.6 | 1200 / 1800 ms | 12 |

  The downloaded voice (Supertonic) divides the length its duration
  model predicts by the pace, as upstream's own speed setting does. The
  phone's voice takes the pace as Android's speech rate, set on every
  sentence; Android has no setting for more careful sounds. The pauses
  are silence Trellis writes itself, so the stored sentence times count
  them and the page still lights the right word. The step applies to
  episodes made after it is chosen, by a tap and by make ahead alike;
  the episode stores it (`episodes.clearness`, schema v35) and its page
  names it ("spoken slowly and clearly by a machine-made voice"). A tap
  on an episode made at another step asks whether to play it as it is
  or make it again; the old audio plays until the new one is ready
  (`listen_clearness_test.dart`, `listen_clearness_setting_test.dart`,
  `listen_chain_test.dart`, `listen_row_button_test.dart`,
  `phone_voice_pace_test.dart`, `supertonic_speech_engine_test.dart`).
  **Not heard on a phone**: nobody has listened to any step yet, and
  whether 12 denoising steps sound cleaner than 8 is upstream's claim,
  not ours. **Not built**: the casual end of the request ("totally
  colloquial street speech"). Neither voice can sound more casual than it
  does; that would take a casual translation and a voice trained on
  casual speech. A word-by-word step is not built either: saying each
  word alone would lose the sentence's tune and multiply the work. Not
  on the web.
- **Episodes on this phone** (boards 0127, 0129, 0131, 0161). Latest has
  a chip "Downloads" (the owner's word) beside All, Text and Audio. The
  chips wrap onto a second line rather than scroll sideways, so it is on
  screen at 320 dp and large text; at the end of a sideways row it sat
  off the edge of a narrow phone, where the owner never found it. It
  shows only the
  episodes whose audio is on the phone, made episodes in any language
  included, biggest first, each with its size; the total is at the top.
  Each row has a button to remove that episode's audio, and the app's
  own selection (long-press) removes several at
  once, with Remove audio first in the bar. One plain confirm says how
  much space comes back. Removing audio keeps the episode, its
  transcript, your place and your study cards, and the decoded copy left
  by transcribing goes with it. Audio is not kept in Recently deleted, so
  the space comes back at once and the confirm says so. A downloaded
  episode can be downloaded again; a made episode is made again by the
  same Listen tap on its original. An episode playing, transcribing or
  being processed keeps its audio. In Models & storage the Episode audio
  row has See episodes, which opens this view, and Clear all as the
  second choice. The filter leaves books and texts out: their text is
  small, and deleting it would lose the book itself, not a copy that can
  be fetched again. The Library has no All, Text and Audio chips, so the
  chip is on Latest only. Audio left by an episode that no longer exists
  is not listed; Storage by item and Clear all still reach it
  (`features/storage/on_phone_test.dart`). Not on the web.
- **This episode in other languages** (board-0130). An episode's page
  lists the episode in every language it has, on the original's page and
  on each made episode's page alike: the original first, then each other
  language, one row each, saying whether that language's audio is on the
  phone ("Audio on this phone", "Text only, no audio yet", "Text only,
  its audio was removed"). It replaces the Language section on an
  episode, so no language shows twice. Since board-0161 it is the one
  language switch for listening and reading on the original's page: a
  row chooses its language, Play then plays that language's made audio
  when it is on the phone and Read reads its text; the learning language
  not yet made is the row that makes it. On a made episode's page the
  others are their own episodes, and a row goes to one. Reading
  a translation says at the top of the reader whether that language has
  audio: "This is the Spanish text. There is no Spanish audio yet." with
  Make the Spanish audio (the one tap, in that language, where this
  episode can be made in it), or "The Spanish audio is its own episode."
  with Play the Spanish audio (`features/works/episode_versions_test.dart`,
  `work_page_four_choices_test.dart`). Books and articles keep their
  Language section.
- ✅ shipped: **The episode's page, one main action** (board-0161, owner
  12 Nov: "clicking an episode is insane when there are immediately 12
  buttons", "all formatted CRAZILY"). Play is the one filled button, full
  width: in the learning language when that episode is made and its
  audio is here, else the original, with one line under it saying which
  (or how far a download has got). Beside it, on one grid line of equal
  cells, three: Read, Queue (Play next and Play last as one) and one
  download control (Download, Stop while it runs, Downloaded, which
  offers to remove it); where their words can't fit whole at the text
  size, they stack at full width instead. A text's page has Read as its
  main action and Listen beside it. Below is the language list (above).
  Keep, Transcribe, Stream now or Download, then play, Change learning
  language and the deletes are in the ⋮. No control is shown greyed out:
  where something is not offered, one plain line says why (Translate
  without a transcript, Read on an audiobook). Counted the owner's way
  (buttons, greyed ones too, tappable rows and the ⋮) for an untouched
  episode being learnt in Spanish: 14 before, 7 after. Held at 320, 360
  and 412 dp, at 1.0, 1.3 and 2.0 text
  (`features/works/work_page_layout_test.dart`).
- ✅ shipped (1.5.3) — **A visible Play in the reader.** One button where
  the thumb rests (a floating button in Scroll and Lines; beside RSVP's
  own Play in RSVP): Listen / Pause for a work with aligned audio, and
  Play / Pause for the silent pacer otherwise ("Follow along", which hid
  in ⋮). A work with aligned audio no longer offers the silent pacer in
  Scroll and Lines; the button listens instead.
- ✅ shipped — **Read<->listen handoff verbs.** Listen (the reader's
  visible Play button when a work has aligned audio; 1.5.3, it was
  ⋮ → "Listen from here") and "Read from here" (transcript view app bar) over the SAME `Positions` row and the SAME
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
  (`reader_typography_settings_screen.dart`, "Reading style", opened from
  Settings or from the reader's Reading settings) with live preview: typeface
  (Lora/Nunito — the two faces actually bundled, both C7 cmap-checked;
  never OpenDyslexic, see the honesty fix above), line height, font
  scale. Applies to the scroll/print reader only — RSVP and the ticker
  keep their own tuned displays, which never needed this control. The
  justification switch was removed in 1.6.0: it stretched the gaps
  between words, and the text is always ragged-right now.
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
- ✅ shipped, degraded — **What you've built, formerly "Trellis Echo" (lifetime totals + a private
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

## Beyond both donors — the shakedown (Campaign 9, ADR-0015)

Neither donor had these; the first real device test of 1.3.0 surfaced
them instead. Listed here rather than folded into Covered/Degraded
above because every item traces to a specific user observation, not a
donor-parity checklist.

- ✅ shipped — **Full-content feeds** (ADR-0015 Decision 1). A feed
  item's body now comes from `content:encoded`/`content` (a NEW,
  uncapped `FeedItem.contentHtml` field) through the SAME
  `extractArticle` path URL intake already uses, whenever that's
  meaningfully longer than the existing 300-char `desc` — a
  Substack-shaped feed reads as the actual post, not a stub. Podcast
  episodes keep show-notes as their body (that's what show-notes are).
  **Honesty note**: only recovers what a feed actually ships in RSS — a
  paywalled/truncated feed still yields an excerpt.
- ✅ shipped — **Library/river honesty** (ADR-0015 Decision 2). The
  library query now excludes `persistence: 'ephemeron'` works by
  exclusion (`isNotValue`, not an allow-list of one) — the river owns
  ephemera, the library only ever shows promoted works, and every
  library row gained a date subtitle (published date for a kept
  episode, added date otherwise) matching a pattern the river already
  had.
- ✅ shipped — **River artwork.** Channel-level `<itunes:image href>` /
  `<image><url>` parsed into `Feeds.imageUrl` (schema v20), fetched ONCE
  per feed (never at render) to `artwork/{feedId}.img` via the app's
  existing resumable-download engine, and shown as a ~40dp rounded
  thumbnail leading each river row with the unread dot moved to a
  corner badge — the device report was "excluding the podcast image...
  makes it hard to scroll the river and find something." Rows without
  artwork keep the prior layout. Gated on `localMlAvailable`, not on a
  services object merely being non-null, so the web tier never attempts
  a file read it can't make. `MediaItem.artUri`/`LockScreenTag.artUri`
  now points at this same file, gated on the SAME `existsSync()` check
  (ADR-0015 Decision 3, shipped as Phase 2e) — see below.
- ✅ shipped — **Lines: a third reading mode.** "there's still no
  line-by-line option... just line by line, audio NOT playing." A new
  scroll-family `ReaderMode` highlighting one VISUAL LINE at a time
  (`TextPainter.getBoxesForSelection`-grouped, `reader/
  line_paced_view.dart`), advancing on the SAME word-level clock RSVP
  and Scroll's follow-along already share — a line's dwell time is the
  SUM of its own words' `msPerWord`, never a separate `wordCount/wpm`
  formula that would discard the tokenizer's punctuation-dwell weights.
  The mode switcher (`mode-toggle`) is now a labeled three-way picker
  (Scroll / Words / Lines) rather than a binary cycling toggle.
- ✅ shipped — **The reader follows the player.** "the highlighted
  section didn't update as the audio moved; it just sat there." When
  audio for the OPEN work is playing — already under way, or started
  via Listen — the reader now attaches to `PlayerController`
  and advances its own cursor on every position tick, through the same
  `Spine.positionAtAudioTime` mapping the karaoke view already proved.
  A "Following audio" / "Resume following" chip shows and controls the
  state; a manual seek (tap a word, drag-scroll) or playback moving to
  a different work both detach — the user's hand always wins.
- ✅ shipped — **Identity: the lattice logo.** Every Android mipmap and
  PWA icon was byte-identical to Flutter's stock template; no logo
  asset existed in the repo. `assets/brand/trellis-logo.svg` (verified
  byte-for-byte against the live landing page before anything was
  generated) now backs the legacy launcher icons, a full adaptive icon
  (foreground/background/monochrome layers, Android's own safe-zone
  fraction), the PWA's maskable variants, and the favicon — regenerable
  any time the logo changes via `tool/generate_brand_icons.py`.
- ✅ shipped, pending device confirmation — **The media-session
  package.** ADR-0015 Decision 3: first deferred mid-campaign
  (`just_audio_background` researched, then removed again), then
  implemented as Phase 2e once orchestrator review overruled that
  deferral — the user's #1 device finding, the one this campaign is
  named after. `JustAudioBackground.init()` runs once at startup
  (Android/iOS only; a no-op stub on the web tier, verified with
  `flutter build web` after wiring). Every `AudioSource` the player
  loads — episode, audiobook, the Phase 2c rehydration path — now
  carries a `LockScreenTag` (id/title/album/artUri), built by a pure,
  unit-tested function (`lockScreenTagFor`). The Android manifest
  gained the package's own required service + media-button receiver,
  no new permission (`FOREGROUND_SERVICE_MEDIA_PLAYBACK` was already
  declared and unused). **Honesty note**: proven up to the tag reaching
  the player; lock-screen RENDERING itself is device-only and stays
  unverified by any test — see the "Background podcast playback" row
  above, moved from Degraded to Covered and worded the same way.

## Beyond both donors: 1.5.8 and 1.5.9

Owner reports from daily use, fixed release by release. Every line names
the test that holds it. Paths are under `app/test/` unless they say
otherwise.

### 1.5.8 (2026-10-27)

- ✅ shipped: **Follow along** lights each word as it is heard, at any
  speed up to 4×, with one “Back to audio” in every mode
  (`features/reader_follows_player_test.dart`,
  `features/reader_speak_speed_test.dart`).
- ✅ shipped: **Translations in every reading mode**: RSVP, Line and
  Follow along, as Translation only or Both, remembered per work (schema
  32; `features/reader_translation_modes_test.dart`,
  `db/translation_view_db_test.dart`).
- ✅ shipped: **Pages open inside their tab**, so the bottom bar stays;
  + Add in the Library, and Subscriptions is a tab of its own
  (`features/tab_navigation_test.dart`).
- ✅ shipped: **Storage by item**: Remove download, Delete transcript and
  Delete translation on the work page (`models/storage_by_item_test.dart`,
  `db/work_storage_db_test.dart`).
- ✅ shipped: **The neural voice is used once downloaded**: it registers
  at T1 (`packages/ml_runtime/test/registry_test.dart`,
  `services/device_services_real_tier_test.dart`; ADR-0007).

### 1.5.9

- ✅ shipped: **Recently deleted.** Deleting a transcript or a
  translation no longer asks first. A copy of every row it removes is
  saved beside the database, listed under Recently deleted in Models &
  storage (title, kind, language, date, size; Restore, and ⋮ Delete now)
  and let go after 30 days at start-up. A restore that would mix with a
  newer transcript or translation, or whose transcript changed, or whose
  item is gone, is refused with a plain sentence. A translation being
  made can’t be deleted (`features/storage/recently_deleted_test.dart`,
  `bootstrap_io_test.dart`). The web tier keeps no copy, so there the
  delete still asks.
- ✅ shipped: **The player bar.** One slim row (at most 72 px at text
  scale 1.0, fits 320 dp at 2.0): art and title open the episode, a drag
  across them scrubs (cancel puts it back), Back 15, Play/Pause, speed
  and X. ⋮ holds Go to show and the rarer controls (Headphone buttons
  moved to Settings, board-0131). X closes the bar for
  good, in every state (playing, paused, buffering, mid-skip, at the end
  of an episode with another queued), and keeps the place heard
  (`features/player/mini_player_bar_test.dart`, `features/player_test.dart`).
- ✅ shipped: **One primary Play per screen.** At most one filled action
  on the work page, the show page and the reader. A playing row shows
  “Playing” and pauses on a tap. The RSVP pacer is “Start”, not a second
  Play. One voice at a time: Read aloud pauses the episode, and the
  episode playing again stops Read aloud
  (`features/works/work_page_actions_test.dart`).
- ✅ shipped: **Read aloud on podcast transcripts with the neural
  voice.** The voice drives its own native player instead of competing
  with the episode for `just_audio_background`’s single slot; calls and
  unplugged headphones pause it, and a failed voice ends the run with a
  plain sentence (`reader/speech/just_audio_speech_queue_test.dart`,
  `reader/speech/speech_playback_pipeline_test.dart`). Heard on an x86_64
  emulator release build; an arm64 phone is a release check.
- ✅ shipped: **Read aloud in the translation’s language.** Translation
  only reads the translation; Both reads each sentence, then its
  translation, by default (“Read the ⟨language⟩ aloud too”, which replaced
  “Speak in ⟨language⟩”). A voice per language is picked in ⋮ › Read
  aloud voices and remembered. If the downloaded voice can’t read every
  language in the run, the whole run uses the phone’s voices. With no
  voice for a language, nothing is read and a plain sentence points at
  Android’s Text-to-speech settings; Russian is never read by an English
  voice (`features/reader_speak_translation_test.dart`,
  `features/reader_speak_spanish_test.dart`,
  `services/flutter_tts_speaker_test.dart`, `features/reader_entry_test.dart`).
  **Degraded:** in Both with Russian, the English is read by the phone’s
  voice too, not the downloaded one; on the web a picked browser voice is
  not applied (the browser answers nothing), so the first voice for the
  language reads.
- ✅ shipped: **A Russian read-aloud voice can be found** (board-0161,
  owner 12 Nov: "I can't get a read-aloud Russian voice"). Three causes,
  each fixed with a test. (1) A text whose language nobody set (a pasted
  text, an imported file: intake keeps none) went to the downloaded
  voice, whose letters are Latin only, so Russian was read as nothing;
  such a text in another alphabet is now refused with a plain line to
  set its language, after which that language's voice reads it. (2)
  Settings › Read aloud voices listed only the languages of works and
  shows, so a Russian translation of an English episode left Russian
  off the list; translations' languages are listed now. (3) A phone
  with no Russian voice downloaded lists none (Android marks such voices
  "not installed"), and the sheet only said so: it now has "Open
  text-to-speech settings", and the message when read aloud stops has
  "Voice settings", both through the app's own door to Android's
  settings (`features/reader_speak_translation_test.dart`,
  `db/langs_in_use_test.dart`). Whether the owner's phone has a Russian
  voice downloaded is a device check.
- ✅ shipped: **Translation downloads are less than half the size.** The
  six oldest pairs take Xenova’s int8 decoder after a parity check (about
  249 → 116 MB a pair). A pair already on the phone reads “Update
  available” with its size; the old decoder is pruned at start-up, which
  downloads nothing (`packages/ml_runtime/test/translation_catalog_test.dart`,
  `models/model_store_prune_test.dart`, `models/models_screen_test.dart`,
  `features/reader_translate_test.dart`, `bootstrap_io_test.dart`; the
  parity table is in ADR-0020).
- ✅ shipped: **The unused Qwen download is gone.** The registry has no
  Qwen spec, and a copy already on a phone is pruned
  (`packages/ml_runtime/test/registry_test.dart`,
  `models/model_store_prune_test.dart`).
- ✅ shipped: **The listening place is kept whichever way Play was
  pressed.** Saved every 10 seconds while playing, whenever playback
  stops (the app, the lock screen, the notification, a headset), and
  after every seek. A scrub from the lock screen while paused sticks. An
  older place never overwrites a newer one, and a reader left open with
  an untouched cursor no longer writes over the player’s place
  (`features/player/listening_place_test.dart`,
  `features/reader_keeps_listening_place_test.dart`).
- ✅ shipped: **Calmer reading spacing.** Follow along steps lines by
  the line height like Line does, sets words a real space apart at any
  text scale, and moves no word as the highlight moves; the current word
  is a solid chip that stands out in light and dark. A translation sits
  close under its sentence; Line’s Both spacing changed slightly too
  (`features/reader_spacing_test.dart`,
  `features/reader_cursor_contrast_test.dart`,
  `visual/reader_spacing_golden_test.dart`).
- ✅ shipped: **Starting a translation into a new language** no longer
  shows or reads the old language’s sentences while it starts
  (`features/reader_speak_translation_test.dart`, “a new language started
  while another is stored”).

## Beyond both donors: owner asks, November 2026

Paths are under `app/test/` unless they say otherwise.

- ✅ shipped: **The example course is an example.** It stays in the
  bundle (it is small and needs no network), but nothing installs it: the
  empty Courses tab offers “Try an example course”, the course list marks
  it “Example course”, the Add sheet stops offering it once it is there,
  and any course can be removed from its map with its cards and their
  history (`features/courses_flow_test.dart`).

- ✅ shipped: **Share sends the made audio.** Share on an episode made
  in the learning language sends its audio file, named by its title
  (“Harbour episode (Spanish).ogg”), with words that say the voice is
  machine made and give the original’s link; the file’s own tag says the
  same, the WAV kept when no encoder takes it included. With the audio
  gone from the phone it sends those words alone, never the made
  episode’s address, which can’t be fetched. An ordinary episode whose
  audio is on the phone offers “Send the link” or “Send the audio file”
  (`features/listen/spoken_share_test.dart`,
  `features/listen_chain_test.dart`, `db/voice_kind_db_test.dart`). The
  web has no files to send, so there Share sends words.
- ✅ shipped: **A host’s own voice stays behind its own switch.** A made
  episode stores the kind of voice that said it (schema 33). Share sends
  a file spoken in a copy of a real person’s voice only when Settings ›
  Listening › “Share audio made in a host’s own voice” is on; it is off
  by default, and otherwise Share sends words only. No such voice exists
  in Trellis yet; the switch is there before it is
  (`features/listen/spoken_share_test.dart`,
  `features/settings/settings_screen_test.dart`).

- ✅ shipped: **Make and edit a card by hand.** A course’s map has
  Cards: every card step by step, Add card, and a tap to change one.
  Two kinds are made by hand, front and back, and cloze written the Anki
  way as `{{c1::word}}` (a hint after a second `::` is not part of the
  answer; blanks with one number are asked together), with “Hide the
  selection” to make a blank. A card keeps its id when changed, so its
  history stays; a step keeps its last card. A card can be changed in
  the middle of a session (Edit card, before the answer shows), and the
  session asks the new words. “Make a card” on the Courses tab, and on
  the sheet a held word opens in the reader, puts the card in **My
  cards**, a course made with its first card whose session goes
  straight to the cards; from the reader it is the word’s sentence with
  the word hidden. Every change is a new course text the strict parser
  accepts; study_core is unchanged (`study/card_editing_test.dart`,
  `features/study/card_making_flow_test.dart`,
  `features/reader_ledger_test.dart`, `features/dictionary_sheet_test.dart`).
- ✅ shipped: **Pictures on cards.** Any course item can name a picture
  (`image`, a plain file name; study_core reads it and scheduling never
  does: `packages/study_core/test/curriculum_parser_test.dart`). The card
  editor offers “Add a picture”, “Change picture” and “Remove picture”
  through the system picker; a file must be a PNG, JPEG, GIF or WebP of
  at most 3 MB, and is named by its own hash, so a picture two cards use
  is kept once (`study/card_images_test.dart`,
  `study/card_editing_test.dart`, `features/study/card_picture_test.dart`).
  Pictures are kept in the app’s own database, which the web build has
  too; a picture no course names any more is let go when a course is
  saved or removed (`db/card_images_db_test.dart`). A session shows the
  picture above the question with no network, and says so plainly when a
  course from elsewhere names a picture this device does not have. A
  backup carries each picture with the course that names it
  (`features/backup_bridge_test.dart`), and the Anki export adds each as
  Anki media shown on the card’s front (`study/anki_export_test.dart`,
  `study/course_map_export_test.dart`). A course file saved from the map
  is text only: its pictures stay in the backup and the Anki deck.

- ✅ shipped: **The transcript appears as it is made.** An episode with
  no transcript gets the text of each finished window on its page as the
  window lands, so Read shows what is done so far. The text is built from
  the committed checkpoint through the same overlap merge as the finished
  transcript (`transcriptSoFar` in `packages/transcribe_core`), so a kill
  leaves the last window’s text and a resume never repeats a word
  (`packages/transcribe_core/test/transcript_so_far_test.dart`). Writing
  it again keeps the rows that did not change, and a reader’s place in
  them (`transcribe/transcript_writer_test.dart`). The job’s card says
  “You can read the first 12 minutes now”; an open reader takes in new
  text when it is still and says how far the transcript has got, or that
  it stopped part way (`features/transcribe_flow_test.dart`,
  `transcribe/transcript_so_far_test.dart`,
  `features/reader_transcript_so_far_test.dart`). A job over a transcript
  the work already has shows nothing part way; Discard takes the part
  away; making an episode in another language waits for the whole
  transcript (`features/listen_chain_test.dart`). Part of a transcript
  is never taken for a whole one: a row says “Transcribing, 12 of 40
  min” while the job runs, or “Part transcript, 12 of 40 min” once it
  stops, in place of “Transcript”. The ⋮ offers no Transcribe while the
  job runs and “Resume transcribing” once it stops; “Transcribe again”
  and translating into English wait for the whole transcript. Translate
  on the episode’s page and in the reader waits too, and says how much
  is done (`features/works/partial_transcript_test.dart`,
  `features/reader_transcript_so_far_test.dart`).
- ✅ shipped: **Stream or download, chosen per episode.** Settings still
  says what Listen and Play do with an episode that isn’t downloaded. The
  episode’s page offers the other way for this play, “Stream now” or
  “Download, then play”, and every row’s ⋮ offers both. While an episode
  downloads, its progress shows where Play is, on the page’s Listen and
  on the row (`features/works/stream_or_download_test.dart`,
  `features/player_test.dart`).
- ✅ shipped: **History as far back as AntennaPod.** Episodes are told
  apart by the feed’s own guid (RSS `<guid>`, Atom `<id>`), then the link
  as before. Keyed on the link alone, a show that links every episode to
  its home page kept one episode of its whole catalogue. Episodes stored
  the old way are matched and take their guid, so none comes back as
  new. Following a paged feed (RFC 5005 `rel="next"` or `prev-archive`,
  in RSS or Atom) now walks its archive in the background, as AntennaPod
  loads every page; Fetch older stays for shows followed before. There
  is no cap on how many episodes or how old: a 1,200-episode feed lands
  whole (`features/feed_ingest_test.dart`,
  `packages/comms_core/test/feed_archive_test.dart`,
  `packages/comms_core/test/feed_parser_test.dart`). Not compared yet:
  one real show side by side with AntennaPod on a phone.

## Fleet rollout (2026-09): shared conventions adopted

- **Deletes.** Removing a work, unfollowing a feed, removing a saved word
  and removing a reader act at once and offer an Undo bar that never times
  out; the rows go only when the offer is let go. Swiping a word away asks
  first. Removing a model or clearing a cache asks first (large files).
  Deleting a transcript or a translation acts at once and keeps a copy in
  Recently deleted for 30 days (1.5.9; see below).
  Removing a podcast episode or feed article from the Library only takes it
  out of the Library: it stays in Latest and on its show's page, transcript
  and all (ADR-0019 §1).
- **First run.** A first launch opens straight onto Latest for a reader
  called "Reader", with no name to type; later launches reopen the reader
  this device last had open, also on Latest. A fresh install's empty Latest
  points at adding a podcast and at Subscriptions. The picker appears only
  when there is a choice (Switch reader).
- **Top bars.** Icon plus a word for the main commands, the rest in a
  worded More menu; the reader names its current mode as a word.
- ✅ shipped: **Settings on the bottom bar, and one rule for ⋮**
  (board-0131/0132; owner: the three dots hid different things on
  different screens). The bottom bar is always Subs, Latest, Queue,
  Library, Courses, Settings, in the owner's order (12 Nov; "Subs" by
  board-0169, its screen still titled Subscriptions), and the app opens
  on Latest. Every label is a plain word, whole on one line, and all six
  are drawn at one size: the phone's own text size, unless the widest
  ("Settings") would not fit its sixth of the width, and then the
  largest size at which all six fit (1.21x on a 360 dp phone with text
  at 1.3x, 1.08x at 320 dp). None is drawn smaller than the others. Settings gathers every app-wide setting and door:
  Theme; Reading (Reading style, Read aloud voices for every language the
  reader meets, Use the system voice, Read citations aloud); Listening
  (Wi-Fi and data, Trim silence & even out volume by default, Headphone
  buttons); Learning (Learning language, How clearly the voice speaks,
  FSRS scheduling, Thinking);
  Storage and backup (Models & storage, Backup & migrate, Jobs); This
  reader (Switch reader, What you've built); About (version, Open-source
  licences). A top bar's ⋮ holds only that screen's own rare actions.
  Select is in none: a long press selects (owner, 12 Nov). A screen with
  none has no ⋮ (Latest, Queue, Library, Courses, Settings, a show's
  page, History, Search). The reader, which hides the bottom bar, ends its ⋮ with
  Reading settings, the same rows as Settings' Reading group. A row's ⋮
  starts with the work's shared items in one order, then the list's own
  (`features/settings/menu_rule_test.dart`,
  `features/settings/settings_tab_test.dart`,
  `features/settings/settings_screen_test.dart`).
- **Wide screens.** Every screen is a centred column of at most 640 dp
  (the reader keeps its own chosen text width).
- **Errors.** Failures are a plain sentence; raw exception text only
  behind Details or in the log. A refused web address offers "Paste the
  text instead".
- **Words.** River is Latest (Inbox until ADR-0019), Up Next is Queue, the follow list is Subscriptions, Echo is What you've built, the espalier is
  the course map, rungs are steps, sigma is Focus spread; RSVP, parafoveal
  preview, SM-2 and FSRS are explained where they are chosen.

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
