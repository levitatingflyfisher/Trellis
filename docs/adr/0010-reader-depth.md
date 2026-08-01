# ADR-0010: Reader depth — typography, the restored priming visuals, StarDict, recaps, lifetime totals

- Status: Accepted (all six phases landed)
- Date: 2026-08-15

## Context

KOReader's typography depth is why people void warranties; Kindle's
recaps and Apple's streaks are why people stay; the donor priming
reader's (`OpenHearth/ohPrimer`) guided visuals are why this line
existed at all. Campaign 4 builds toward that superset in five
independently-shippable feature phases plus a sixth docs pass. This ADR
records the honest ceilings and deliberate deviations as each phase
lands, rather than reconstructing them from memory at the end.

## Decision

### Phase 1 — typography

Per-profile typography prefs (`ReaderPrefs`/`ReaderTypography`,
`Profiles.readerPrefsJson`, schema v18) apply to the scroll/print
reader only — RSVP and the ticker keep their own tuned displays.
Typeface choice is restricted to the two faces actually bundled (Lora,
Nunito); `docs/reference/feature-matrix.md` previously claimed a
bundled OpenDyslexic face that was never true, fixed in Phase 6.

**Honest ceiling: no hyphenation.** Justified text is
`WrapAlignment.spaceBetween` on the reader's own per-word `Wrap` (not
Flutter's `TextAlign.justify`, which special-cases the last line) —
both distribute space without hyphenation, so wide gaps can appear on
narrow screens or short lines. The settings screen's copy says so
plainly rather than hiding it. A hyphenation engine is out of scope
this pass.

### Phase 2 — the lost priming visuals

Restored as first-class RSVP options, all read directly against the
donor (`OpenHearth/ohPrimer/index.html`) rather than trusting a
secondhand summary verbatim:

- **The ORP anchor fix is a jitter fix, not a perfect 50% anchor.**
  The donor's own CSS (`index.html:181-184`, `.classic-w{display:flex}`
  inside `.display-inner{justify-content:center}`) centers the WHOLE
  before/pivot/after row as a block; the before-pivot span's `min-
  width: cw*orp` only pins that span's width to a constant for words
  sharing an ORP bucket (see `orpIndex`). The algebra: with the row
  centered, the pivot's absolute offset from center works out to
  `(beforeWidth − afterWidth) / 2` — reserving `beforeWidth` removes
  the jitter THAT span used to contribute (different glyphs, same
  bucket, same reserved width now), but the free-width AFTER span
  still shifts the row's center for words of different total length.
  `orpBeforeReserve` (`reader_logic.dart`) and its doc comment say
  this plainly; the fix restores what the donor actually built, not a
  stronger claim than the donor's own CSS achieves.
- **Guide + tick marks** (`index.html:177-179`) are a quiet, theme-aware
  affordance at the display's horizontal center — independent of the
  pivot's own (reserved, not perfectly pinned) position, exactly as in
  the donor. Classic mode only, hidden the instant Parafoveal is on.
- **Parafoveal is an RSVP sub-toggle, not a third `ReaderMode`.** The
  app's mode-toggle button cycles a strictly binary rsvp/scroll state
  today, and the cursor-law tests (`reader_test.dart`,
  `reader_ticker_test.dart`) only ever exercise those two states. A
  sub-toggle restores the donor's third display (its own mode name is
  "ticker" — renamed to Parafoveal here because this app's own test
  vocabulary already uses "ticker" for the existing classic RSVP mode)
  without touching that cycle or those tests. It reuses `_wordIdx`/
  `_step()` wholesale, so punctuation-pause lengthening (already
  verbatim in `packages/loom_core/lib/src/tokenizer.dart`) comes free
  with no second dwell path.
- **Session-scoped, not persisted.** Parafoveal on/off, its sigma, and
  Phase 2's follow-along toggle all follow the reader's existing `_wpm`
  precedent ("holds for the session") rather than
  `Profiles.readerPrefsJson` — playback controls in this reader have
  never been cross-session state, and typography's JSON blob stays
  reserved for genuinely persisted prefs.
- **Neighbor sizing adapts, not ports, `effectiveFontSize`.** The donor
  measures actual DOM width to shrink long tokens; this reader already
  handles that with `FittedBox(fit: BoxFit.scaleDown)` on the RSVP
  stage, so neighbor font size is simply `0.82 × the focus word's
  style size`, and the existing `FittedBox` absorbs overflow the same
  way it already does for classic mode's long words.
- **C7 (bundled-glyph coverage) caught σ before it shipped.** The
  donor's literal sigma-slider copy uses "σ" (U+03C3); neither bundled
  face (Lora, Nunito) covers it, so the settings copy spells "sigma"
  out. `fleet_conformance_test.dart`'s C7 check caught this
  automatically rather than needing to be remembered — the exact
  failure mode this campaign's own house lesson (Peckish's tofu bug)
  warns about.

### Phase 3 — StarDict lookup

A pure-Dart StarDict parser (`packages/stardict_core`, the `*_core`
convention — no Flutter, no `dart:io`) reading `.ifo`/`.idx`/`.dict.dz`
directly, including real dictzip random access (hand-parsed gzip FEXTRA
`RA` subfield → per-chunk `Inflate`, not a whole-file decompress),
cross-validated against a real 21.8MB download
(`docs/reference/dictionaries.md` carries the license verdict —
`wiktionary-en-en-stardict`, dual CC-BY-SA-3.0/GFDL-1.3, sha256-pinned).

- **A parallel `ModelTask.dictionary` door, not a repurposed ASR/TTS
  one.** The registry's existing tasks all denote a *model* the runtime
  loads and runs; a dictionary is inert data looked up by string key.
  Giving it its own task keeps `ModelSpec.dictionaryArchiveLayout` and
  `DeviceServices._openDictionary`'s cache honest about what they are,
  rather than overloading a task enum value that already means
  something else.
- **`_extractDictionary` is a sibling of `_extract`, not a
  generalization.** The pinned dictionary file is a `.tar.gz`
  (`GZipDecoder`); a voice's is `.tar.bz2` (`BZip2Decoder`). Two small
  near-identical methods stayed clearer than one parameterized on
  compressor, matching this file's own doc comment.
- **Definition text is stripped with a regex, not rendered.** StarDict
  entries are small HTML fragments (`<b>`, `<i>`, block tags, entities).
  A full HTML renderer for a few tags of formatting was more machinery
  than the sheet's plain-text `Text` widget needed; `_stripHtml` turns
  block tags into newlines, drops the rest, decodes entities. Rich
  formatting (bold headwords, italic examples) is lost — an honest,
  minor ceiling, not hidden.
- **The definition sheet ABSORBS the long-press-to-keep gesture rather
  than stacking a second one on it.** The reader already spent
  long-press on "add to word ledger" before this phase existed; adding
  a second gesture (e.g. double-tap) for "look up" would mean two
  distinct hand actions on the same word, one invisible until
  discovered. The sheet opens on long-press, shows the definition, and
  its own "Add to word ledger" button is the same `_keepWord` the
  gesture used to call directly — one hand action, doing something
  legible immediately (show me this word) with the old action available
  a tap away rather than gone.
- **Honest ceiling: "no definition" is one message for two different
  cases.** The sheet's empty state ("No definition available on this
  device...") fires identically whether no dictionary is downloaded at
  all or a dictionary is present but the word genuinely isn't in it.
  `DeviceServices.lookupDefinition` had the information to distinguish
  these (`isDownloaded()` vs. a null `lookup()` result) but the sheet
  doesn't thread it through. Not fixed this phase — recorded here so a
  future pass has to make the call on purpose rather than rediscover it.
- **Follow-along's Phase 2 auto-scroll made an existing pause
  inconsistency load-bearing.** `_openDefinitionSheet` now calls
  `_pause()` first, matching `_openTypographySettings`/`_toggleMode` —
  added after Phase 2 (not in Phase 3's first pass) once follow-along
  made scroll mode playable, which exposed a real race: an un-paused
  cursor kept calling `Scrollable.ensureVisible` on a scrollable sitting
  under the sheet's modal route.

### Phase 4 — session recaps ("Catch me up?")

A dismissible AppBar-bottom chip on a work reopened after more than 3
UTC epoch days untouched with real (>10%, <100%) progress
(`shouldOfferRecap`, `reader_logic.dart`), resolved by `LibraryScreen.
_open` before the push — the same "resolved before the push" shape
`offerNeuralVoice` already established, so `ReaderScreen`'s own tests
never compute this, only receive a bool. Tapping it walks the SAME
consent order `openDistillFlow` already established (gesture → cloud-
tier egress consent naming the host → Brain call), then shows the
result in a bottom sheet rather than a full-page push.

- **Spoiler-safety is two layers on purpose.** `preCursorText`
  (`reader_logic.dart`) filters to segments strictly before the
  reader's own cursor BEFORE any prompt is built — tested in isolation,
  the load-bearing guarantee. `RecapGenerator`'s prompt (`brain_wiring`)
  also tells the model not to invent or reference anything beyond the
  text it was given. Belt and suspenders: the filter is what actually
  keeps unread text off the wire; the prompt instruction guards against
  a model filling a gap from its own training data even when the text
  handed to it is already spoiler-free.
- **Never stored, matching the dictionary sheet's own law.** The recap
  lives in `_RecapSheetState`'s memory only; closing the sheet forgets
  it. No new database column, no journal.
- **Regenerate skips a second consent dialog.** The egress consent
  dialog names exactly what text goes to which host; regenerating sends
  the SAME text to the SAME host, so nothing new is being disclosed
  that the first accept did not already cover. A second identical
  dialog would be friction without a corresponding new fact.
- **Session-scoped dismissal, not persisted.** Dismissing the chip
  (tap it or the close X) hides it for the rest of this screen session
  only, the same shape Phase 2's Parafoveal/follow-along toggles
  already use — this reader has never carried playback-adjacent UI
  state across sessions, and the offer itself is naturally re-derived
  next time the gap/progress conditions are met again.

### Phase 5 — lifetime totals and Trellis Echo

The spec's own instruction was to verify the "existing session recording"
premise before building on it. Doing that changed the plan in two ways
worth recording plainly.

- **A lifetime-totals dashboard already existed.** `HouseholdDao.
  lifetimeBuiltOf` / `ParentDashboardScreen` (pre-dates Campaign 4 —
  confirmed an ancestor of base commit 911ddde, not something a sibling
  campaign landed ahead of this one) already shipped an ADR-0003-law-5
  dashboard: additive-only, positive framing (a stat shows only once it
  exists), PIN-gated, no streaks. Extending it rather than building a
  parallel query was the smaller, more honest move: one field
  (`activeReadingDays`) on the `LifetimeBuilt` typedef, one `COUNT` query,
  and the existing parent dashboard gained a tile for free.
- **`listeningMs` is not minutes listened.** Its real computation is the
  furthest audio POSITION reached per work (max of raw player position
  and aligned segment end), summed across works — not measured wall-clock
  time. The two nearly coincide for a straight-through listen with no
  seeking, and diverge under re-listening or skipping around. This
  predates Campaign 4; the existing parent dashboard's copy ("5 minutes
  of listening") already overclaims slightly and was left alone — not
  this pass's file to rewrite — but Echo's OWN new copy says "minutes of
  audio reached" instead of inheriting that phrasing, since new copy gets
  to be precise from the start. `database.dart`'s `LifetimeBuilt` doc
  comment now states the real meaning explicitly.
- **"Words read" has no source anywhere in this schema.** `Positions` is
  one overwritten row per (profile, work) holding the CURRENT wordIdx —
  no cumulative counter exists, and a derived one would fall as often as
  it rose (a reopened book, a seek backward). Not built, per the spec's
  own pre-authorized cut ("scope Echo's claims to what is actually
  recorded — never invent numbers").
- **"Export highlights" doesn't exist as specced.** There is no
  highlight/passage/marginalia table in this schema — `Captures` is an
  audio bookmark (sentence-snapped once a transcript exists), and
  `WordLedger` is individual collected words, not passages. Renamed the
  feature for what it exports: the word ledger plus captures, in plain
  front-matter-free Markdown and a structured JSON alongside
  (`echo_export.dart`).
- **Trellis Echo is reached from Courses, not a new nav destination.**
  This app has neither a drawer nor a settings screen; `CoursesScreen`
  already carries `onOpenBackup` threaded from `HomeShell` as the
  established "a tab offers the door, the shell owns the navigation"
  pattern for a secondary destination. `onOpenEcho` mirrors it exactly.
  Never PIN-gated — that gate belongs to `ParentDashboardScreen`, whose
  audience is a parent reviewing a household; Echo's audience is a reader
  reviewing themselves.
- **The share card is native-only, honestly.** `share_plus` (new
  dependency) drives `RepaintBoundary → PNG → share sheet`; the web tier
  gets the screen with no share button rather than one that cannot work,
  the same law `DeviceServices.localMlAvailable`'s other callers already
  follow. Export (Markdown/JSON) reuses `BackupGateway`/
  `FilePickerBackupGateway` instead — it already works cross-platform,
  including a plain browser download on web, which `share_plus` cannot
  offer.
- **A Flutter testing landmine, for the next person who hits it:**
  `RenderRepaintBoundary.toImage()` resolves fine under a plain
  `pumpAndSettle`, but the subsequent `ui.Image.toByteData()` PNG encode
  is background work `pumpAndSettle` has no reason to keep waiting for
  once the widget tree itself stops scheduling frames (it isn't tied to a
  frame). The fix used here: tap outside `runAsync`, then poll inside
  `tester.runAsync` with real `Future.delayed` steps until the awaited
  result lands, bounded so a genuine regression still fails instead of
  hanging.
- **`ReadingDays` needed a cascade-delete fix, not a schema change.**
  Adding it to `HouseholdDao`'s accessor list surfaced that
  `deleteProfileCascade` never deleted from it — `ReadingDays` carries
  its own `Profiles` foreign key, so a profile with any reading-day rows
  failed deletion outright with a `FOREIGN KEY constraint` error (watched
  RED via the real `SqliteException` before fixing), rather than quietly
  orphaning rows.

**Cut from this phase, on purpose:** "top works" / "top feeds" (the spec
mentioned these under Echo). No cheap, already-reviewed aggregation
exists for either — building one would mean new grouping logic this pass
never verified the cost or correctness of, which is exactly the kind of
addition the phase's own "verify before building" instruction warns
against. Left for a future pass that wants to review that query on its
own terms.

### Phase 6 — docs

- **`docs/reference/feature-matrix.md` honesty fix.** The "Covered"
  section's settings line falsely claimed OpenDyslexic was bundled
  (never true — Lora and Nunito are the only two faces, both C7
  cmap-checked) and implied no settings screen existed (Phase 1 built a
  real one). Corrected in place, with a pointer to this ADR.
- **A "Beyond both donors — reader depth" section**, matching the study
  crown's own precedent exactly: one entry per phase, `✅ shipped` marks,
  honest ceilings and cuts stated inline rather than only living in this
  ADR.
- **CHANGELOG.md** gained one `### Added` entry under `## Unreleased`
  covering all five phases, matching the study crown's existing density
  and bold-lead-in-per-feature shape.
- **`AGENTS.md`** now lists `packages/stardict_core` alongside the other
  pure packages, and `echo` in `app/`'s feature-directory prose list.
- Grepped `docs/` for other stale claims this campaign might have
  invalidated (OpenDyslexic, long-press-adds-directly, streak claims).
  Nothing else needed a fix: `docs/research/*` are explicitly provenance,
  not law (AGENTS.md's own instruction), and their donor-inventory
  mentions of OpenDyslexic/streaks are accurate historical records of
  what the DONOR had, not claims about this app.

## Status

Accepted. All six phases landed. Every honest ceiling, cut, and
deliberate deviation named above was verified against the running code
and its test suite, not asserted from memory — see the campaign's final
report for the full commit list, test counts, and every place a phase
diverged from its original spec with the reason why.
