# ADR-0011: Triage & rules

- Status: Accepted
- Date: 2026-08-15

## Context

Readwise Reader's crown is architectural: pushed content (the river) and
curated content (the library) never pollute each other, and moving between
them is one gesture. Inoreader/Miniflux prove rules and hygiene are pure
local logic. This app had both surfaces already; this campaign gave them
the verbs the spec named — triage, saved views, per-feed rules, cross-feed
dedup, tracker stripping — and, along the way, corrected three premises
the spec's own visual precedents turned out not to hold.

**Three fictions found before writing code against them, not after:**

1. The spec's Phase 3 cited "the existing include/exclude auto-download
   filter" as the rules editor's visual precedent. No such filter exists
   anywhere in `lib/` — `Feeds.autoDownload` is a bare boolean column with
   a DAO setter (`FeedsDao.setAutoDownload`) and **zero callers**. No
   episode-audio-download path exists at all outside the transcription
   pipeline (`audio_fetcher.dart`, which only runs from the
   consent-gated `_transcribe` flow).
2. `LibraryScreen` had no search, sort, or filter of any kind before this
   campaign — the feature-matrix's "Library: debounced search, sorts,
   filters…" row was itself an overclaim, sitting in the exact feature
   Phase 2 was meant to extend.
3. Phase 4's pixel-stripping bullet assumed "the extractor already
   sanitizes." `intake_core`'s `extractArticle` has never extracted
   `<img>` elements into blocks at all — its part tags are text-only
   (p/h1-h6/li/blockquote/pre) and `FigureBlock` is EPUB-only. No
   tracking pixel has ever been able to leave an extracted web article,
   by construction.

Each is addressed in its own section below rather than patched around.

## Decision

### 1. Triage verbs: Keep and Let it pass

Keep reuses the existing library-add path (`SpineDao.promoteWork`) and
marks the item read — it has left the unread flow. Let it pass is the
explicit dismissal form of what ephemera decay already does implicitly:
marks read, promotes nothing.

**No river filter chip for "Kept" exists, and none should.** Kept things
live in the library — that is the whole law, stated once here so no
future pass reintroduces it as a convenience feature.

Both gestures are undoable to the **exact prior state**
(`RiverTriage.undo`, Peckish's verbatim-restore idiom) — an item already
read before a swipe undoes back to read, not to unread; a work already
promoted before a Keep undoes back to promoted, not demoted.

**Swipe never removes a row from the river.** `Dismissible.confirmDismiss`
performs the gesture, then always returns `false`, so the tile springs
back showing its new state. This is the house idiom already established
for archived rows (dimmed, not hidden — `river_screen.dart`'s own
comment: "dimmed rather than hidden makes that visible truth instead of
an assertion nobody can check") applied to triage. No new filter chip, no
item that vanishes on swipe then reappears on the next pull-to-refresh.

**Overflow parity, a real gap this touched, not scope creep:** non-audio
(text/article) river rows had **no popup menu at all** before this
campaign — `trailing: isAudio ? Row(...) : null`. Keep/Let-it-pass living
only in a swipe gesture would have made text rows swipe-only, failing the
spec's own "swipe actions + overflow parity" requirement. Every row now
gets the menu.

### 2. Saved filtered views

A pure `LibraryQuery` (`app/lib/features/library/library_query.dart`):
text search, type, feed/source, read state, pinned — every field
optional, AND-combined, an unset field ignored. Evaluated over a new
left-joined query (`LibraryDao.libraryQueryEntriesOf`) since only
`kind == 'episode'` works have an episode/feed row to join.

**"course" is deliberately absent from the type filter.** Courses
(`Courses` table) are never spine works — `worksOf`/the library join
cannot return one — so a "course" option would be a dead control that
structurally matches zero rows. The four real kinds this app produces
(`book`, `article`, `episode` labeled "Podcast", `note`) are the whole
set.

Saved views persist as `SavedViews.queryJson` — this repo's house
pattern (`Cards.stateJson`, `Feeds.breakerJson`), not
`SharedPreferences`, which nothing in `lib/` uses (the spec's "existing
imported-courses prefs pattern" reference was itself imprecise — Courses
persist as a Drift table, not prefs).

**A design gap a widget test surfaced, not inspection:** Apply or Save
without touching any control still returns a non-null `LibraryQuery`
that matches everything. Treating "non-null" as "a filter is active"
made the AppBar's filter icon offer a no-op "clear" and made the
filter-builder screen unreachable a second time. `LibraryQuery.isEmpty`
and normalizing to `null` at every point a query is set fixed it —
"active" now means "actually restricts something."

### 3. Per-feed rules and cross-feed dedup

**Rules** (`feed_rules.dart`): conditions on title/description
(contains/not-contains, case-insensitive), actions skip /
mark-read-on-arrival / auto-keep. Evaluated in order per item at ingest,
first match wins, **before** a row ever exists — skip means no `Work`/
`Episode` row is created at all, not merely hidden, and the skipped
item's guid is never recorded as seen (an honest reading of "never
enters": a still-skipped item is simply re-evaluated, and re-skipped, on
the next refresh, rather than tracked in a tombstone table the spec
never asked for).

The editor lives on `feed_settings_screen.dart` — since the cited
"existing include/exclude filter" precedent turned out fictional (see
Context), this shares layout idioms with the closest real thing instead:
that same screen's own Wrap-of-chips + TextField shape.

**Dedup** (`feed_dedup.dart`): two river items are duplicates when their
canonical URLs match after tracker-parameter stripping, OR their titles
are exact-normalized (trim, lowercase, collapse whitespace) equal AND
published within 48h inclusive. The **younger** duplicate (later
`publishedAtMs`, ties broken by the higher `workId`) is suppressed —
kept in the database, hidden from `riverItems()`, its reason recorded
(`'url'` or `'title'`).

**Law: dedup never suppresses two items from the same feed.** A host
reposting its own item is editorial choice, not noise — checked before
any URL/title comparison runs.

**Suppression is river-only.** `riverItems()` excludes a suppressed row;
`LibraryDao.libraryQueryEntriesOf` carries no dedup filter at all — like
`SpineDao.worksOf` before it, it has never filtered by persistence or
dedup state, so a promoted work stays exactly as visible in the library
whether or not a later dedup pass suppresses it from the river. A rule's
`autoKeep` promoting an item that a subsequent pass then finds is the
younger side of a duplicate pair is the sharpest case: it disappears from
the river (correct — it is a duplicate) and stays in the library
(correct — it was kept) with nothing on either screen explaining the
gap. Acceptable as shipped behavior; recorded here so it reads as a
known interaction, not a bug report waiting to happen.

**A suppression records which work it duplicates, not just why**
(`Episodes.duplicateOfWorkId`, alongside `dedupReason`). Reachable
paths that delete a work — unfollowing a feed, the ephemera sweep,
`deleteWork` directly — could otherwise take the canonical (older) side
of a pair with them, leaving the suppressed (younger) row hidden
forever with nothing left pointing at why. `SpineDao.deleteWork` now
clears any dangling suppression pointing at the work it is about to
remove, so "hidden" can never quietly become "lost." Pinned with a test
that deletes a canonical work and asserts the formerly-hidden duplicate
reappears in the river.

The dedup pass is pure and pairwise, not a transitive-closure clustering
algorithm — a chain of three-or-more near-duplicates resolves against
whichever pair is found first. That is the honest scope for a personal
river's size; nothing in the spec asked for cluster resolution.

### 4. Fetcher hygiene

`comms_core`'s `stripTrackingParams`/`canonicalizeForDedup`
(`tracker_strip.dart`) strip a curated, documented, conservatively-scoped
`const` set — the UTM family, ad-platform click ids, ESP send tracking,
social-share referral ids. A plain `ref` parameter is deliberately
excluded: some sites use it as a real routing parameter the page itself
reads, so it stays rather than risk breaking a legitimate link.

Applied to exactly two things: an ingested article item's stored
`sourceUrl` (never the guid, which still hashes the raw link — stripping
storage can never make an already-seen item look new), and dedup's
URL-match comparison. **Never applied to feed fetch URLs** (a feed URL's
query params can be load-bearing: API keys, pagination cursors, auth) or
to **enclosure (audio) URLs** — a signed CDN URL's query params can be
equally load-bearing, the same reasoning extended to a case the spec
didn't name explicitly.

**Pixel stripping is a pin, not new code.** Since `extractArticle` has
never extracted images into blocks (see Context §3), the invariant "no
tracking pixel reaches an extracted article" already held by
construction. Building image extraction just to have something to
sanitize would have invented the vulnerability in order to fix it.
`article_extractor_test.dart` pins the invariant instead — confirmed
genuinely RED first (a temporary `img`-src-emitting branch made the
tracker's URL leak into extracted text; reverting restored green), so
the regression pin is proven, not decorative.

### 5. Auto-download: corrected, not built

`Feeds.autoDownload` stays exactly as it was — a column and a setter
with zero callers. It is **not** wired to a download-on-refresh queue
this pass, for a reason stronger than scope: **ADR-0003 law 6** ("One
egress chokepoint... model downloads all pass one consent gate"). The
one place episode audio is already downloaded — the transcription
path — goes through `confirmDownload`'s "what leaves your device"
screen precisely because ADR-0003 requires it. An automatic
refresh-time download would bypass that gate silently, on a household
local-first product where the failure mode is a phone's data plan
disappearing without a tap. That is a sovereignty-law violation, not
merely a missing guard, and it holds regardless of whether metered/
disk-space checks are also added — the matrix's specific claim
("with metered + disk-space guards, re-checked between downloads") would
stay false either way. The feature-matrix correction (§ Consequences)
marks this row Degraded/not-wired, honestly.

### 6. The Substack email-intake gap stays open

Recorded, not built — Skein v2 territory, as the spec named it.

## Consequences

- **Schema v15.** v13 (Babel) and v14 (reader-depth) are reserved for
  sibling campaigns in flight elsewhere; this branch jumps 12 -> 15
  directly rather than collide on those numbers, and its own `from < 15`
  migration block is internally complete and correct in isolation — the
  eventual merge is whoever lands last's job to reconcile into one linear
  chain. `SavedViews` is a `createTable` (idempotent, needs no seed-and-
  strip fixture change — confirmed empirically against this codebase's
  own migration style, correcting an initial assumption that it would);
  `Feeds.rulesJson`/`Episodes.dedupReason`/`Episodes.duplicateOfWorkId`
  are `addColumn` (not idempotent), so nine seed-and-strip fixtures
  needed the three new columns added to their strip lists — the seven
  named in the campaign brief plus `feeds_db_test.dart`'s own v11→v12
  block (not on that list, but the same pattern) and this campaign's own
  new v12→v15 test. Every one confirmed a genuine
  `SqliteException: duplicate column name` RED before being fixed.
- `feature-matrix.md`: the auto-download row moves to Degraded/not-wired
  with the reason above; the Library row is corrected to name what
  actually shipped this campaign rather than describe a screen that
  never existed; new rows record triage, saved views, rules, dedup, and
  tracker stripping.
- Two incidental fixes surfaced by the work itself, not separate asks:
  `feed_settings_screen.dart`'s new Rules section pushed its Save button
  below the default test viewport, turning three previously-passing
  `opml_flow_test.dart` taps into silent hit-test misses (a warning, not
  a failure, since nothing had asserted the tap actually landed) — fixed
  with the `ensureVisible` calls those taps always needed but never
  required until the screen grew. And a stray `→` in the new rule-
  summary text tripped the fleet's C7 bundled-font check
  (`fleet_conformance_test.dart`); replaced with `—`.
- `SavedViews`, `LibraryDao`, `RiverTriage`, `feed_rules.dart`, and
  `feed_dedup.dart` are all new, additive surfaces — no existing DAO
  method's signature changed except `ingestFeedItems`, which gained one
  optional `rules` parameter (`= const []`) that reproduces prior
  behavior exactly when omitted, proven by a dedicated "no rules (the
  default) behaves exactly as before this feature" test.
