# Changelog

This repo had no CHANGELOG.md before this entry — the release notes surface
that existed was `fastlane/metadata/android/en-US/changelogs/`, which is
keyed by Android versionCode and isn't the right place to record a change
that ships no version bump. This file starts here as a narrative record
alongside it, in the common "Unreleased" convention, not a replacement for
it.

## 1.5.6 — 2026-10-25

### Fixed
- **Translate finds its models.** The Translate sheet said there was no
  offline translator even after you had downloaded one.
- **Translate waits for text.** An episode without a transcript no longer
  offers to translate, and nothing offers to translate English into
  English.
- **The episode page keeps up.** Read works as soon as a transcript lands,
  Transcribe shows while there is none, and Download goes away when the
  download finishes.
- **Tapping speed opens one list**, not a stack of them.

### Changed
- **Speed:** swipe on it as before; a tap now opens a plain list of
  speeds (0.75× to 4×) with the current one checked.
- **"On this device" is now "Models & storage."**

## 1.5.5 — 2026-10-25

### Added
- **Share to Trellis.** Share a link, text or a file from any app. Links
  and text land in Latest under "Shared" straight away; books go to the
  Library. A Bluesky, Mastodon or Substack link offers to subscribe.
- **A home-screen widget**: what's playing, with Play/Pause and skips, and
  the book or article you were reading.
- **Translation for real languages.** 25 language pairs with English,
  downloaded from the Translate sheet when you pick one; other pairs go
  via English. A translation picks up where it stopped.

### Changed
- **Two ways to read:** RSVP (one word at a time, eyes still) and Page,
  whose highlight follows along word by word or by line. Tap a word to
  play from there. Scroll is gone.
- **Speed goes from 0.5× to 4×.** Swipe up or down on it, or tap for
  presets.
- **The mini player stays on every screen** while something is loaded.
- **Starting a transcription says so** at once, with its progress.

## 1.5.4 — 2026-10-25

### Changed
- **The same row on every list.** Latest, the Queue, History, the
  Library, a show's page and search all show an item the same way, with
  Play (or Read) on the row and the rest in its ⋮ menu.
- **Every item has its own page.** Tapping a row opens it: Listen and Read
  side by side, the language to read or hear it in, and the episode's
  full show notes. Times in the notes are tappable and play from there;
  a link asks before it opens, and says where it goes. The page opens to
  whatever you last used for that item: listening or reading.
- **Subscriptions is faster**, even with hundreds of shows, and has a
  "Find a subscription" box and a chip for each shelf.
- **Search is rebuilt.** Results come in sections: Shows, In titles, In
  the text (show notes and article text) and Said in (transcripts). Each
  section says how many it found and shows them all on request. Word
  endings no longer matter ("machines" finds "machine"), every word can
  be typed in part, and show notes are searched. The Library's filter
  searches the same way. A thin bar shows while a search is running.
- **Importing a list of shows** can be stopped, says how many you already
  follow, and offers to show them.
- **Remove** takes a kept episode out of the Library, with an Undo that
  stays until you dismiss it.

### Fixed
- After a restart, a paused episode's slider sits where you left off, not
  at the start.
- Opening the app while a background check was running could fail with
  "database is locked"; it now waits for the check to finish.

### The first launch after updating
- Show notes fill in over the next few feed checks, a few shows at a time,
  rather than all at once.
- Search rebuilds its index in the background. Until it is done, the
  search screen says "Updating search… N%" and search still works, but
  without word endings, article text or episode descriptions.

## 1.5.3 — 2026-10-24

### Changed
- **Latest is a permanent archive.** Nothing decays any more: every item
  from every show and site you follow stays in Latest, newest first, until
  you unfollow it. Items an older version had hidden come back. Latest
  loads a page at a time as you scroll, so a big archive opens fast, and a
  quiet "New since you last looked" line marks what arrived since your last
  visit. It keeps its place when you switch tabs. Removing a podcast
  episode from the Library now only takes it out of the Library; it stays
  in Latest with its transcript.
- **The Queue is a tab**: Latest · Queue · Library · Courses. Latest is
  where the app opens. History has its own button on the Queue tab.
- **Plain names.** Up Next is the Queue, Up Last is History, the follow
  list is Subscriptions, and the Inbox is Latest.
- **Theme** (light, dark or follow the phone) moved into each tab's ⋮
  menu.
- **Read a podcast without playing it.** A transcribed episode has a Read
  button beside Play; it opens the transcript, and tapping a line plays
  from there.
- **The reader has a Play button** (Listen) whenever the text has audio.
- **Faster transcription.** Trellis detects a show's language once and
  locks it for the episode, keeps the model loaded for the whole episode,
  starts each 30-second window with a fresh state, and phones whose CPU
  supports it get a faster whisper build.
- **A one-time full refresh.** After updating, the next refresh reads
  every feed in full once, to learn each show's declared language.

## Before 1.5.3 — fleet rollout (2026-09)

Some lines below were overtaken by 1.5.3: the Inbox is Latest, nothing
decays, Up Next is the Queue, and the theme is in each tab's ⋮ menu.


### Changed
- **Plain words.** The River is the Inbox; Echo is What you've built; the
  espalier is the course map; rungs are steps; the reader's Parafoveal
  toggle is a Nearby words chip and sigma is Focus spread. RSVP, SM-2 and
  FSRS are explained where they are chosen.
- **First run opens into the task.** No name to type: a first launch
  opens a Library for "Reader"; later launches reopen the last reader.
- **The reader remembers** its mode, speed and nearby-words setting per
  reader.
- **Deletes.** Remove, Unfollow, a word's Remove and Remove profile act at
  once with an Undo that never times out; swiping a word away asks first.
- **Inbox decay** is stated on every row in days; what leaves is kept 30
  more days, then deleted, and items in Up Next or with captures do not
  decay.
- **Theme**: light, dark or follow the phone, on every tab bar.
- **Top bars** name their commands; **every screen** is capped at 640 dp
  wide; **errors** are plain sentences with details behind a button; the
  course map's ripeness darkens steadily; copy uses proper punctuation.
- **Backup**: a new phrase is checked word by word; the PWA keeps its
  words under Trellis's own name; backups are saved as
  `trellis-backup-<date>.ohbk`.
- Lora and Nunito now come from openhearth_design; the app ships no font
  files of its own.

## 1.4.1 — 2026-08-17

A hotfix for a 1.4.0 that did not start. Reported from a real phone:
the app showed its launch logo and never got past it.

### Fixed

- **The app never painted a frame.** Campaign 9 Phase 2e added the
  lock-screen media session and landed only half of what
  `just_audio_background` requires: the manifest's `<service>` and
  `<receiver>` elements, but not the launcher activity's obligation to
  hand audio_service its shared `FlutterEngine`. `AudioServicePlugin`
  detects exactly that mismatch (`wrongEngineDetected`) and throws
  `IllegalStateException` on the first method call it gets — which is the
  `configure` that `JustAudioBackground.init()` sends, and which `main()`
  awaits *before* `runApp()`. The throw escaped `main`, so there was no
  first frame, no error UI and no crash dialog: Android simply kept
  showing `@style/LaunchTheme`. `MainActivity` now extends
  `AudioServiceActivity`. The PWA was never affected — the web tier's
  `initAudioBackground()` is a no-op stub.
- **A boot step can no longer take the boot with it.** Everything `main()`
  awaits is on the critical path to the first frame, not just to its own
  feature, and a pre-`runApp` throw is invisible by construction. Each
  step now runs through `bestEffort` (`lib/bootstrap/boot_guard.dart`):
  it falls back, reports to `FlutterError` so logcat keeps the stack, and
  records a line shown in a dismissible banner over the app. Degraded and
  honest beats a logo that explains nothing.

### Added

- `test/android_host_engine_test.dart` — the guard that would have caught
  this. 1145 Dart tests could not see it, because nothing in the suite
  had ever read the Android host configuration. It asserts the invariant
  (the activity the manifest declares must provide audio_service's shared
  engine) rather than one file path, and fails when its own inputs go
  missing instead of passing on nothing-found.

## 1.4.0 — 2026-08-16

Campaign 8 "Babel widens" (`docs/adr/0014-babel-widens.md`): the
translation organ ADR-0008 shipped for Spanish only generalizes to any
language pair — the hub-and-spoke law is 2N models for N target
languages, never N², and every registry entry, test, and picker now
reflects it rather than hardcoding Spanish.

### Added

- Four new Marian pairs, verified with real inference before
  registration: German, Russian, and Chinese, each shipped both
  directions except English->Chinese (see Fixed, below, for why).
  Portuguese and Japanese were evaluated and NOT shipped — Portuguese
  has no clean-licensed ONNX conversion on the trust ladder; Japanese's
  base model collapses to a pure `<pad>` token at decode step one and
  stays incoherent even past that, needing a Brain rather than the
  offline floor. Full accounting in `docs/reference/mt-models.md`.
- The reader's "Translate…" action is a real picker over whichever
  target languages are actually downloaded for a work's own declared
  source language, replacing the fixed "Translate to Spanish" menu
  item. A new per-work language selector lets a reader correct a work's
  declared source language (no auto-detection — declared, not guessed).
- A CJK segmentation baseline in `loom_core` (the UAX #29 default
  absent a dictionary: one Han ideograph per unit, Katakana runs kept
  together, Hiragana one character at a time) replaces the old
  behavior, where a long space-less CJK run collapsed to a single `…`
  placeholder and a whole CJK paragraph spoke as one long utterance.
- `BrainTranslator`: a second Translator rung sitting on domovoi's
  Brain interface instead of an on-device ONNX session, chunking 10-20
  sentences per request with strict JSON-array parsing and per-sentence
  fail-closed behavior. Built and fully tested, including the specific
  degraded state a stove tier with nothing real behind it produces —
  but not yet wired into the live app (no tier ladder, no consent
  routing, no UI picker rung reach it). `docs/adr/0014-babel-widens.md`'s
  Phase 5 section has the full accounting of what's left.

### Fixed

- The shipped app offered to translate an English work into English —
  the generalized picker now excludes a work's own declared source
  language from its target list, with a second, defensive refusal at
  the point a translation would actually start.
- Two real regressions an adversarial review caught before release:
  picking a translation target could offer a "Show ⟨language⟩" toggle
  with zero stored sentences behind it (setActiveTranslationLang runs
  before a batch produces its first row, so a fresh pick mid-run or a
  cancel-at-zero left a dead control); and a pre-campaign work with
  stored Spanish, but its display toggled off, lost the "Show Spanish"
  toggle entirely on reopen — indistinguishable from never having
  translated anything.
- Speaking a German, Russian, or Chinese translation with a neural
  voice primed and preferred would have thrown an uncaught
  `SupertonicUnsupportedLangException` mid-utterance — Supertonic's own
  language gate covers only English and Spanish. Engine selection now
  checks the active translation's language before choosing a voice,
  never reaching Supertonic's gate for a script it can't encode.
- "Household stove" — internal jargon that read as insane to a real
  device tester — is "Home desktop" everywhere it was user-visible
  (the brain settings tile, its own error message, and the provenance
  line a generated course/critique/recap carries). The internal
  `BrainTier.stove` identifier is unchanged; this is copy only.

### Not shipped, on the record

- `opus-mt-en-zh` (English -> Chinese): translation quality is real and
  usable, but a golden-test render of the scroll-mode display showed
  Chinese glyphs as tofu boxes, and bundling a CJK font to fix it
  (measured: 8.3MB for a single region/weight) doesn't fit the app's
  remaining APK size budget. `opus-mt-zh-en` (the reverse direction,
  English output, no glyph risk) ships unaffected.
- Background/lock-screen playback for the speak-in-X loop, a real
  TinySegmenter-quality Japanese word segmenter, and a bundled CJK font
  are all named as follow-ups, not built this pass.

---

**Campaign 9 ("the shakedown")**: the first real device test of 1.3.0
came back and this campaign fixes what it surfaced. Every item below
traces to a specific device-test observation, not a feature checklist.
No version bump here (the release finale happens once every in-flight
campaign merges).

### Added

- **A visible play/pause glyph, everywhere it was missing.** Device
  report: "the play/pause circles don't have symbols in them." Root
  cause: `OhTheme`'s app-wide `iconTheme` color collided with
  `IconButton.filled`'s own fill token. Fixed at the theme, not
  per-callsite.
- **Discoverable controls.** Two bookmark icons now read differently
  (capture vs. the captures list, with a "View" snackbar action to the
  list); tooltip gaps closed (library/feeds/river popup menus, the
  speed button); the Echo door gained a word, the daily-review chip its
  own icon; sleep-timer duration buttons size to their own text instead
  of clipping "Custom…"; the library filter is a live modal sheet, not
  a separate pushed screen.
- **The mini player survives a restart.** It used to render nothing at
  all once the app restarted (`current == null` → blank); it now
  rehydrates PAUSED at the last-played work's saved position, no
  autoplay ever. The river's "Up Next" queue gained its own AppBar
  door, reachable with nothing currently playing.
- **The daily-review screen shows what a grade actually did.** A
  progress counter, distinct capture-card fronts (title + timestamp,
  transcript resolved at render time rather than backfilled), grade
  labels that state their consequence instead of bare "Soon"/
  "Eventually".
- **Full-content feeds, and an honest library** (ADR-0015). A
  Substack-shaped feed's full post is recovered from `content:encoded`
  through the same HTML→segments path URL intake already uses, instead
  of a 300-char stub. The library now shows only promoted works — river
  ephemera stay in the river — and every row gained a date subtitle.
- **River artwork.** Channel-level images, fetched once, shown as a
  ~40dp rounded thumbnail leading each row (schema v20).
- **Lines: a third way to read.** A scroll-family mode highlighting one
  visual line at a time, paced on the same word-level clock RSVP
  already uses. The mode switcher is now a labeled three-way picker
  (Scroll / Words / Lines).
- **The reader follows the player.** When audio for the open work is
  playing, the reading cursor now moves with it — a "Following audio" /
  "Resume following" chip shows and controls the state; any manual
  interaction detaches.
- **The lattice logo replaces Flutter's stock template.** Every Android
  mipmap and PWA icon now derives from `assets/brand/trellis-logo.svg`
  via `tool/generate_brand_icons.py` — legacy + adaptive launcher icons,
  a notification small icon (generated ahead of the work that will use
  it), and the PWA's maskable variants + favicon.
- **Lock-screen/pull-down-tray playback controls** (ADR-0015 Decision
  3). Deferred mid-campaign, then built at review — this is the user's
  #1 device finding, the one the campaign is named after.
  `JustAudioBackground.init()` runs once at startup, Android/iOS only;
  every episode, audiobook and rehydrated play now tags its audio with
  the work's id/title, the feed's title as album, and its downloaded
  artwork when one exists. The Android manifest gained the package's
  own required service + media-button receiver, using Phase 8's
  notification icon (an orphan until now). Lock-screen RENDERING itself
  stays device-only and unclaimed — everything above is proven up to
  the tag that reaches the player, not past it.

## 1.3.0 (2026-08-15) — build 2007

The gap-map release: eight campaigns landed here, one per gap the honest
feature audit found. The study crown (ADR-0009); RFC 5005 paged-feed
archive following; Campaign 1 ("the player earns love") — five small
mercies for the podcast player; Babel (ADR-0008), the on-device
translation organ; reader depth (ADR-0010) — typography, Parafoveal,
dictionary, recaps, Echo; "Triage & rules" (ADR-0011) — river gestures,
saved views, per-feed rules, dedup; offline DSP (ADR-0012) — trim
silence and even out volume on downloaded episodes; and audiobooks
(ADR-0013) — a folder IS the book.

### Added

- Reader depth (ADR-0010): five additive passes over the reading surface
  itself. **Typography settings** — a real settings screen with live
  preview (typeface, line height, font scale, justification) for the
  scroll/print reader; typeface choice is Lora or Nunito, the two faces
  actually bundled (an old feature-matrix claim that a third,
  OpenDyslexic, was already bundled was never true — fixed alongside
  this). **Parafoveal mode** — the donor's lost third RSVP display
  (Gaussian neighbor fade/scale/blur, a sigma slider, guide+tick marks),
  plus a jitter fix for the classic-mode ORP pivot (a reservation, not a
  perfect anchor — the free-width after-span can still shift a row's
  center for very different word lengths). **Follow-along** — scroll
  mode auto-scrolls the segment currently being read into view, reusing
  the RSVP cursor/timer wholesale. **On-device dictionary lookup** — a
  new pure-Dart StarDict parser (`packages/stardict_core`, real dictzip
  random access) backs a tap-hold definition sheet that absorbs the
  reader's existing "add to word ledger" gesture rather than stacking a
  second one on the same word. **"Catch me up?" recaps** — a dismissible
  chip on a work reopened after 3+ days untouched with real progress,
  offering a Brain-generated spoiler-safe summary (assembled only from
  text before the reader's own cursor) in a sheet that is never saved.
  **Trellis Echo** — a new, reader-facing (never PIN-gated) private
  year-in-review off the Courses tab: works finished, active reading
  days, words collected, cards mastered/reviewed, captures, and audio
  position reached — deliberately never "minutes listened" or "words
  read," since neither is actually tracked anywhere in this schema (the
  spec's own three headline totals reduced to one computable one, on
  verification). A shareable card (native only) and a word-ledger+
  captures export (Markdown/JSON, reusing the existing backup file-save
  door) round it out; the spec's "Export highlights" doesn't ship as
  named — there is no highlight/passage table in this schema, so the
  export is named for what it actually produces.
- The study crown (ADR-0009): four local-first features cloud apps charge
  for. **Daily review** — a gentle two-button (Soon/Eventually) resurfacing
  surface for the word ledger and captures, mapped onto the existing SM-2
  scheduler's again/good, with a quiet due chip on the Courses tab that
  only appears when something is actually due. **Capture-while-listening**
  — one tap on the player bar or the synced-text view saves a moment,
  sentence-snapped to the transcript when one exists (never a raw ±15s
  guess) and backfilled automatically once transcription completes for
  captures taken before one did. **Explicit read<->listen handoff** —
  "Listen from here" in the reader and "Read from here" in the synced-text
  view, both over the same position row and alignment projection the app
  already used implicitly. **FSRS-5 as an opt-in scheduler** — a second,
  fully tested pure-Dart scheduler beside the sealed SM-2 core, additive
  and switchable per profile from a settings menu on the Courses tab
  (one honest sentence of copy on the way in, an instant no-dialog resume
  on the way back out). The live study session now actually reads the
  choice and grades through it — Classic byte-for-byte as it always did,
  FSRS seeded lazily from a card's classic history on its first FSRS
  grade — closing a gap an earlier pass in this same campaign left open
  (a scheduler nothing could invoke). Curriculum progression
  (unlock/mastery) stays Classic-based under either scheduler, a stated
  scope limit (see ADR-0009 for exactly what shipped, including two
  deliberately-not-built pieces: the playback-notification capture
  action, and "make this an extract," which has nowhere to feed in this
  checkout).
- Paged-feed archive following (RFC 5005): `comms_core` now parses a
  channel/feed-level `rel="next"`/`rel="prev-archive"` link and, on
  request only, walks that chain to recover episodes a host has truncated
  off its current feed document — most podcast hosts cap their RSS at the
  newest N episodes, and a subscriber who joins late previously had no
  way back past that cap. The walk is capped at 25 pages, dedupes items
  across pages, and reports honestly however it ends (end of archive, the
  cap, a failed hop, an unsafe next link).
- A feed detail screen (tap a feed in "Feeds" to open it): the feed's own
  episodes, and a "Fetch older episodes" action when the last refresh
  found an archive link. For the overwhelmingly common case where it
  didn't, one calm line says so instead of leaving the missing episodes
  looking like a bug.
- A sleep timer on the episode player surface: 15/30/45/60 minutes or "end
  of episode", with a volume fade over the final 20 seconds, a light
  haptic shortly before stop, and shake-to-extend (+10 minutes, duration
  mode). Lives on `PlayerController`, not a widget, so it survives
  navigation; a duration-mode timer keeps running into whatever plays
  next, an end-of-episode timer is consumed by that episode's own natural
  completion.
- Per-podcast playback settings: a speed override, skip-intro seconds, and
  skip-outro seconds, each feed's own ("Podcast settings" on its menu).
  The player applies the override on start, auto-seeks past the intro
  only on a fresh start (never on resume), and treats crossing
  duration-minus-outro as the same "finish" as playing to the true end.
- An Up Next queue: Play next / Play last on any episode tile, a queue
  view with drag-to-reorder and remove, reachable from the mini player
  bar. Finishing an episode removes it from the queue by default; a
  household setting can keep it there instead. An empty queue after
  finishing just stops — no invented state.
- Smart resume: resuming a paused episode rewinds by a small amount
  scaled to how long it was paused (2s under a minute, 5s under an hour,
  10s beyond).
- Archive, never forget: episode rows are never deleted by storage
  reclaim — only the downloaded audio FILE, per a feed's own "keep latest
  N" setting, excluding anything queued or mid-listen. The river dims
  (never hides) an archived episode and offers "Re-download audio" in
  its place. This is a NEW, narrower law than the existing ADR-0003
  ephemera sweep, which still removes whole rows after 30 days unless
  promoted — that law is unchanged.
- Triage & rules (ADR-0011). **Keep and Let it pass**: swipe (or the
  overflow menu — every river row now has one, including text/article
  rows that had none before) a river item into the library or explicitly
  past it, both with an undo snackbar that restores the exact prior
  state. Nothing is ever removed from the river by a swipe — the tile
  shows its new state in place, the house idiom already used for
  archived rows. **Saved filtered views**: a small query over the
  library — text search, type, feed, read state, pinned, any
  combination — saveable as a named view, shown as tappable chips,
  reorderable and deletable from a new filter screen. **Per-feed rules**:
  skip / mark-read-on-arrival / auto-keep, matched on title or
  description, evaluated before an item ever enters the river — editable
  from each feed's own settings screen. **Cross-feed dedup**: a
  canonical-URL match (after tracker-parameter stripping) or an
  exact-normalized title within 48h hides the younger copy of a story
  syndicated across feeds — never within the same feed, where a repost
  is the author's own choice. **Tracker-parameter stripping**: a curated
  list of tracking-only query parameters (utm_*, ad-platform click ids,
  newsletter send tracking) is stripped from stored article links and
  dedup comparisons — never from feed fetch URLs or episode audio URLs,
  whose query params can be load-bearing.

### Changed

- Schema v12: `Feeds.speedOverride`/`skipIntroSeconds`/`skipOutroSeconds`/
  `keepLatestAudio`, `Episodes.archivedAtMs`, `Profiles.keepFinishedInQueue`,
  and the new `queue` table, landed in one migration hop rather than one
  per feature — v8 (`Feeds.nextPageUrl`, the archive-following campaign),
  v9 (`Profiles.scheduler`), v10 (`captures`), and v11
  (`daily_review_cards`, all three the study crown) came first.
- A river episode's overflow menu now always offers Play next/Play last
  (a database write, not an ML feature) — previously the whole menu was
  gated behind local-ML availability because transcribe was the only
  thing in it.
- Schema v15: `SavedViews` (new table), `Feeds.rulesJson`,
  `Episodes.dedupReason`/`duplicateOfWorkId`. v13/v14 are reserved for
  sibling campaigns landing separately; this branch jumps 12 -> 15
  directly rather than collide on those numbers.
- **Corrected**: the feature-matrix's "Auto-download queue with metered +
  disk-space guards" row was an overclaim — `Feeds.autoDownload` has
  always been a column with zero callers, no filter UI exists, and no
  episode-audio-download path exists outside the (consent-gated)
  transcription pipeline. Left unwired this pass, deliberately: wiring a
  bare downloader would bypass ADR-0003 law 6's one egress consent gate,
  not merely skip the metered/disk guards the matrix claimed (see
  ADR-0011 §5). Marked Degraded/not-wired.
- **Corrected**: the feature-matrix's "Library: debounced search, sorts,
  filters…" row also described a screen that didn't exist — `LibraryScreen`
  had none of the three before this campaign built them (see ADR-0011 §2).

### Added

- `MarianTranslator` (ADR-0008 "Babel") — a real on-device English->Spanish
  machine-translation engine over `opus-mt-en-es` (int8-quantized ONNX,
  `flutter_onnxruntime`), the organ this app's founding dream was
  actually missing: "a podcast player that automatically translates
  episodes... so I could practice Spanish while listening." Mirrors
  `SupertonicSpeechEngine`'s residency/serialized-call/dispose-waits laws
  and conditional-export trio. Proven two ways: the generation loop's own
  mechanics (past-KV threading, a length cap, EOS stop, and — the load-
  bearing discovery — a fix for the merged decoder graph's cached branch
  silently returning degenerate cross-attention output, verified directly
  against the real graphs before any Dart was written) against a
  deterministic faked session, never touching a platform channel; and,
  separately, the whole pipeline against the real downloaded model in
  Python, producing genuinely fluent Spanish. See
  `docs/adr/0008-babel-the-translation-organ.md` for the trap this
  engine routes around and `docs/reference/feature-matrix.md`'s
  Translation entry for how it's actually used, below.
- A pure-Dart SentencePiece unigram tokenizer (`packages/ml_runtime`) —
  a hand-rolled protobuf reader for a `.spm` model's piece table plus a
  from-scratch Viterbi encoder, verified against 25 golden vectors
  generated with the real `sentencepiece` library against the actual
  downloaded model (24 match exactly; one documents a deliberate,
  permanent scope limit — no NFKC precompiled-charsmap port).
- `opus-mt-en-es` registered in `ModelRegistry.starter()` (T2, ~246MB,
  CC-BY-4.0) with a `MarianModelLayout` naming which downloaded file
  plays which role, and a models-door label ("Spanish translation —
  English to Spanish, offline").
- Babel wired end to end (ADR-0008 Phases 3-4): a per-work
  sentence-indexed translation store (schema v13) that survives restarts
  and resumes where it left off; a "Translate to Spanish" action on a
  work, offered only once `opus-mt-en-es` is actually downloaded, that
  runs as a cancellable batch over the work's sentences with a calm
  progress card — already-translated sentences are skipped on a re-run,
  a failure on one sentence never blocks the rest; a scroll-mode "Show
  Spanish" toggle that pairs each original sentence with its translation,
  visually subordinate, once any exist; and a session-only "Speak in
  Spanish" toggle that has the speak loop (system voice OR the
  downloaded Supertonic voice) speak each STORED translation while the
  karaoke cursor keeps advancing through the original sentences — a
  sentence with no translation yet falls back to English, no gap.
  `supertonicSupportedLangs` widened from English-only to `{'en', 'es'}`:
  there is no separate Spanish voice upstream to download (Supertonic's
  ten voice styles are speaker timbres, language-independent; `lang` is
  already a per-call parameter the engine validates against all five of
  the v2 model's languages) — but this is an architectural finding, NOT
  a verified-quality claim. The M1 voice has been reviewed for English
  only; Spanish output through it has not been heard on real hardware.
  Said plainly here, in the ADR amendment, and in the feature-matrix,
  rather than left unbuilt a second time.

### Fixed

- `docs/reference/feature-matrix.md`'s Translation entries claimed a
  Brain-routed LLM-translation mechanism for v1 that was never actually
  built — the shipped mechanism has always been whisper's own built-in
  translate task (X->EN, timestamp-projected onto transcript segments),
  with no Brain/LLM call anywhere in that path. Caught while auditing the
  code this ADR builds alongside; corrected in place.

### Fixed

- The pinned ffmpeg dependency moves from `ffmpeg_kit_flutter_new`
  (the Full-GPL variant — verified to statically link GPL-3.0 x264/x265/
  xvidcore/vid.stab, contradicting ADR-0007's "MIT-clean APK" claim) to
  `ffmpeg_kit_flutter_new_audio` (the same publisher's audio variant —
  LGPL-3.0 only, verified against the actual native binary's build
  config). Same Dart API (`FFmpegKit`, `FFprobeKit`, `MediaInformation`),
  same codecs this app actually uses (mp3/opus/vorbis), same 16KB page
  alignment. ~22MB smaller per arm64 ABI as a side effect, not the
  reason. See `docs/adr/0012-offline-dsp.md`.
- Playback now actually reads the episode audio cache Campaign 1 built.
  `playWork` streamed `work.sourceUrl` unconditionally through 8a1af19 —
  the downloaded/archived file existed to feed transcription and was
  never consulted for playback itself. `PlayerController` now prefers a
  local file (when one exists) over the network URL; per-feed speed,
  skip-intro/outro, smart resume, the sleep timer, and Up Next all read
  the same position/settings rows regardless of source, proven by test.
  Eviction now means something for playback too: delete the file, the
  next play streams; download it again, the next play reads it back.
- A standalone "Download" action on each audio episode's menu — the
  second door onto disk that doesn't require requesting a transcript,
  through the same one consent dialog transcribe already uses. A quiet
  indicator marks a row already downloaded; the action itself
  disappears once one exists. Auto-download stays unwired on purpose
  (Campaign 5's verdict) — this is an explicit tap, always.
- Offline DSP: trim silence & even out volume, on downloaded episodes,
  on this device. A conservative silenceremove (only silences over
  1.5s, shrunk to 0.5s — a natural pause is never touched) chained with
  single-pass loudnorm to the podcast-standard -16 LUFS. Streaming
  playback is never touched — this only ever applies to an episode
  that has actually landed on disk, and only right after it downloads:
  a per-feed toggle (default: the household setting) turns it on,
  "processed on download" is the whole promise, and there is no
  separate manual "process now" action. A failed encode or a sanity
  check that doesn't like the result leaves the original completely
  untouched — nothing is ever promoted until it's verified. The parent
  dashboard's lifetime stats gain a "time saved" line, the same
  positive-framing law as every other line there: silent when zero.
  See `docs/adr/0012-offline-dsp.md`.
- Audiobooks: a folder IS the book. Pick a folder's worth of audio files
  (MP3/M4A/M4B/OGG/OPUS/FLAC), natural-sorted (the classic "1, 2, 10"
  problem) into playback order, an editable guessed title, copied into
  app storage — every picked file is copied, never referenced in place;
  `docs/adr/0013-audiobooks-are-a-door.md` records exactly why (Android's
  `file_picker` gives no durable, permissioned path to reference, and
  this app ships no desktop build to reference from either). M4B/M4A
  chapter marks are read straight from the file's own chpl atom (a
  minimal pure-Dart box parser, verified against ffmpeg's own reader,
  never a general MP4 parser) and shown in a Chapters drawer; a file
  with no chapter atom of its own — every plain MP3 included — is simply
  one chapter. Playback runs through the exact same player every podcast
  episode already uses: gapless auto-advance across a book's files (the
  underlying audio engine's own playlist support, not new app code),
  the shared sleep timer, smart resume, and Up Next queue, a per-book
  speed override, and a one-touch bookmark through the same Captures
  store the study crown already ships. The library tile shows New/
  Started/Finished and a coarse (file-count, not time-precise) progress
  bar. A transcribed audiobook's read↔listen handoff — this campaign's
  own stretch goal — was investigated and NOT built; the ADR names three
  structural reasons rather than forcing a shortcut.

## 1.2.0 (2026-08-14) — build 2006

The first APK to carry the neural voice — and it carries it MIT-clean.
1.1.0's sentence-paced speak mode and the Skein lane ship to Android for
the first time here too (1.1.0 released as a PWA only, its APK held back
precisely because of the licensing question this release resolves).

### Changed

- Speak mode's neural voice rung moves from sherpa-onnx (Piper voices) to
  Supertonic, over `flutter_onnxruntime`. Supertonic needs no phonemizer —
  the model consumes raw character indices — so the shipped APK is MIT-clean
  end to end; sherpa-onnx's TTS path statically bundled espeak-ng
  (GPL-3.0), which meant the previous rung would have made any APK built
  with it a GPL-3.0 binary the moment it shipped. See
  `docs/adr/0007-the-voice-goes-mit.md` for the full accounting.
- The starter voice registry entry moves from `piper-en-libritts-r-medium`
  (23.4 MB, CC-BY-4.0 + GPL-3.0) to `supertonic-en-m1` (~263.5 MB,
  OpenRAIL-M) — a real, honest size increase the models screen states
  plainly before any download starts. The voice's minimum device tier
  moves from T1 to T2, matching VISION's own freedom-of-compute ladder.
- `sherpa_onnx` and its per-platform native packages are removed from
  `app/pubspec.yaml`.

### Added

- `SupertonicVoiceLayout` (`packages/ml_runtime`) — names which downloaded
  filename plays which role for a voice whose files ship loose (no archive
  to extract), the same "data, not code" contract `VoiceArchiveLayout`
  gives an archived voice.
