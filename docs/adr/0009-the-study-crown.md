# ADR-0009: The study crown — three verbs, a sentence-snap law, and FSRS opt-in

- Status: Accepted (shipped this pass, FSRS's live-session wiring
  included after a review caught it shipping unreachable — see §4's
  "Wired, with one stated scope limit" and the "Not built" notes
  elsewhere in this document; `docs/reference/feature-matrix.md`'s
  "Beyond both donors" entries track exactly what did and did not land)
- Date: 2026-08-15

## Context

The three features users cite when calling a reading/listening app "the
best I've ever used" are zero-effort highlight resurfacing (Readwise),
capture-while-listening (Snipd), and read<->listen handoff (Whispersync).
All three are cloud-bound everywhere they currently exist. This app has
every substrate already — the content spine (ADR-0002), the sealed SM-2
scheduler, sentence-level alignments — so the question was never "can
this be built locally," it was "what does each verb actually need, and
what is genuinely missing."

Two things turned out to be missing, discovered by reading the code before
writing any: there is no extract/passage-authoring entity anywhere in this
checkout (the word ledger is word-only — no `segmentIdx`, no SM-2 fields
of its own; `docs/reference/feature-matrix.md`'s "Extract-to-card flow"
row is aspirational, copied from the donor inventory, not built code),
and background playback (`audio_service`, lock-screen controls) is marked
P3-deferred directly in the code (`just_audio_player.dart`: "Background
playback ... is P3 by design — do not add it here"), which conflicts with
the original ask for a playback-notification capture action. Both are
recorded as deliberate scope cuts below, not silent gaps.

## Decision

### 1. Read<->listen handoff: two explicit verbs over existing internals

Both directions' math already existed as an implicit side effect of
pausing: `Spine.positionAtAudioTime` (audio ms -> Position) and
`Spine.projectAudioTime` (Position -> audio ms), both already used by
`PlayerController.saveProgress`/`_resumeMs`. This ADR's contribution is
making them **discoverable, named buttons**, not new state:

- **"Listen from here"** (reader app bar, shown only when the work has
  both an audio source and alignments): `PlayerController.listenFrom`
  projects the reader's current cursor through the alignments and seeks
  there — deliberately NOT built on `playWork`, whose re-tap-toggles
  behavior would make the verb a no-op (or a pause) on the one case it
  matters most: the work already playing.
- **"Read from here"** (karaoke/synced-text view app bar, always shown —
  alignments are guaranteed there): calls the existing
  `PlayerController.saveProgress()` (writing the SAME `Positions` row the
  reader already reads) and opens the reader, which loads that row the
  normal way. No second position store, no `openAt` override parameter
  invented for this — the existing write-then-read path already does the
  job.

**The sentence-snap law, stated once for both this and Phase 2 below:**
`Alignment` is `(segmentIdx, tStartMs, tEndMs)` — sentence-level, no
word-level timing. `positionAtAudioTime` always returns `wordIdx: 0`;
`projectAudioTime` never reads `wordIdx` at all. This is not a limitation
introduced by this campaign; it is ADR-0002's own stated guarantee
("Word-level alignment is best-effort by contract... sentence-level is
the guarantee"). Consequently the read<->listen round trip is proven at
segment granularity in `packages/loom_core/test/cursor_law_test.dart`,
not word granularity — the original ask ("round-trips within one word")
does not hold for this data model, and the tests assert exactly the
claim that does hold, not a stronger one.

### 2. Capture-while-listening: sentence-snapped, in-app only

A Capture is `(episode, position, created-at)`, one tap on the player
surface (`MiniPlayerBar`) or the karaoke view. The quality bar is Snipd's
own known complaint — wrong clip boundaries from a raw ±15s guess around
the tap — so every capture with a transcript already available snaps to
the sentence containing the position via the SAME alignment projection
verb 1 uses (`CapturesDao.capture`), never a fabricated window. A capture
taken before a transcript exists still saves (position honest, unbound);
`CapturesDao.backfillForWork` binds it once transcription completes,
wired into the app's existing `onTranscribed` hook.

**Not built: the playback-notification capture action.** The original
ask named an `audio_service` custom action on the lock-screen
notification. `just_audio_player.dart` already states, in its own doc
comment, that background playback is deferred by design ("P3... do not
add it here"), and ADR-0003 law 5 promises zero notifications except live
job progress. Neither is machine-enforced against this specific change —
`fleet_conformance_test.dart`'s `c4Permissions` check only pins the
Android manifest's permission SET (which already licenses
`FOREGROUND_SERVICE_MEDIA_PLAYBACK` and `POST_NOTIFICATIONS`, so nothing
would immediately go red) — but adding a new plugin dependency and a
background-playback lifecycle to satisfy one sub-bullet of one phase is
not an additive change in the spirit this campaign was scoped under. It
is recorded here as a decision to make, not a gap to discover later.

**Not built: "make this an extract."** There is nowhere for this to feed.
See Context above — no extract entity exists in this checkout. The
captures list ships the other three of the four specified behaviors
(repository, sentence binding incl. boundary positions, backfill) fully
tested, rather than wiring a button to a flow that doesn't exist.

### 3. Daily review: the gentle two-button on-ramp

A `DailyReviewCards` table, keyed by `(profileId, sourceType, sourceId)`
rather than two foreign keys, since a review item comes from either the
word ledger (`'ledger'`) or captures (`'capture'`) — deliberately the only
place that has to know both exist. **Soon maps to the sealed scheduler's
`again`; Eventually maps to `good`** — literally `scheduleSm2`, called
with those two grades, nothing reimplemented. Course items (`Cards`,
`StudyDao`) are never queried by this queue at all; it is proven directly
in `daily_review_db_test.dart` by grading a course card in the same test
that asserts the queue holds exactly the two non-course entries.

**Degraded, honestly:** the original ask was "front = passage context
with the focus span blanked." With no extract entity to source a blanked
passage from, the front shipped is plainer: a bare word for a ledger
entry, the bound sentence for a capture that has one. Note the fit that
emerged rather than being engineered: a bound capture already carries
real passage context, so captures are a genuine (if partial) realization
of "extract" for this queue.

The home surface gets one quiet due chip (Courses tab), rendered only
when something is actually due — a permanent zero would be exactly the
kind of low-grade nag ADR-0003 law 5 rules out.

### 4. FSRS-5, opt-in, additive beside the sealed SM-2 core

**Source**: the algorithm is FSRS-5, published by the open-spaced-
repetition project —
https://github.com/open-spaced-repetition/awesome-fsrs/wiki/The-Algorithm.
The default 19-value weight vector and the -0.5/19-81 forgetting-curve
constants were fetched from that page and cross-checked against a second
independent source describing the same version,
https://borretti.me/article/implementing-fsrs-in-100-lines (identical
weights, identical curve). The two constants are also internally
self-consistent — stability is defined as the elapsed time at which
retrievability has dropped to exactly 90%, so
`fsrsRetrievability(s, s) == 0.9` must hold for any `s`, which only holds
for `DECAY == -0.5, FACTOR == 19/81` (the FSRS-5 curve, not FSRS v4's
original `-1, 1/9`) — verified as a property test, not just asserted.
FSRS-5's two newest weights (w17, w18, the same-day/short-term stability
formula) are carried in the default vector for fidelity but not
referenced by any formula here: this scheduler, like the sealed SM-2 one
beside it, operates at whole-day granularity, and same-day re-grading
degrades gracefully (retrievability saturates at 1.0) rather than using a
formula this campaign has no granularity to host correctly.

**Shape**: `FsrsCardState` is a standalone type in a new file
(`study_core/lib/src/fsrs_scheduler.dart`) — `models.dart` and
`sm2_scheduler.dart` have zero diff from this campaign. `scheduleFsrs` has
the identical `(state, grade, today) -> new state` boundary as
`scheduleSm2`. The sealed suite (104 tests as landed in this checkout —
see the feature-matrix correction below) runs unmodified; FSRS adds 21 of
its own, all pure-Dart property/example tests (monotonicity under
repeated Good, a lapse shrinking stability, bounded interval growth,
serialization round-trip, determinism).

**Seeding, and why no citation exists for it:** switching a profile from
Classic to FSRS seeds `FsrsCardState` from the existing `CardState` via
`seedFsrsFromClassic`. There is no SM-2 -> FSRS conversion formula
published by open-spaced-repetition — verified by direct search, not
assumed. Anki's own migration path does not convert the two SM-2 summary
numbers at all; it replays each card's full review log through the FSRS
update formulas, "assuming that when you did those old reviews, you
remembered 90% of the material" wherever elapsed-time data is missing
(`fsrs4anki/docs/tutorial.md`). Replaying a review log needs a fold over
`Revlog`, which this campaign does not touch, so the seed instead uses
two declared heuristics: **stability := the classic interval** (this
needs no citation — SM-2's interval already IS its own estimate of "how
long until this is likely forgotten," which is definitionally what FSRS
stability measures), and **difficulty := a linear map from ease
[1.3..2.5] onto FSRS difficulty [10..~5.28]**, anchored so SM-2's default
ease lands near FSRS-5's own default first-good-review difficulty. This
second half is declared in the seeding function's own doc comment, in
those words, as **our heuristic, not a published one**.

**The lossy-switch-back law:** grading a card writes only the half of its
`Cards.stateJson` blob belonging to the active scheduler
(`mergeCardStateJson`, read-merge-write); the other half is left exactly
as it was. Switching Classic -> FSRS -> Classic therefore resumes SM-2
from wherever its fields were frozen, discarding whatever FSRS learned in
between — a real, stated loss, not a silent one. This is deliberately the
simpler law over "maintain both in parallel forever," which would have
meant either double-grading every review or inventing a reconciliation
rule nobody asked for.

**Wired, with one stated scope limit.** A first cut of this ADR shipped
FSRS as a real, tested scheduler with no way for a user to ever reach
it — grading always ran through `scheduleSm2`, and no toggle existed. A
review caught it: a scheduler with 21 tests nothing can invoke is not a
shipped feature. This is now closed:

- `study_session_screen.dart`'s `_grade` reads the owning profile's
  scheduler once per session load (off the course row's own `profileId`
  — no new constructor parameter, so every existing call site keeps
  compiling and behaving identically) and dispatches: Classic grades
  through the exact code this campaign found here (moved under an
  `else`, not rewritten — proven by asserting the stored blob carries
  zero `fsrs`-prefixed keys after a Classic grade, not merely that the
  numbers match); FSRS grades through `scheduleFsrs` and
  `StudyDao.recordGradeFsrs`.
- Seeding is **lazy**, at a card's first FSRS grade
  (`StudyDao.fsrsStateToGradeFrom`), not bulk at switch time. This
  mirrors the lazy-creation law `Cards` rows already follow — created on
  first grade, never on import — and avoids writing FSRS state for every
  item in every course a profile owns, most of which may never actually
  be graded under FSRS. It composes for free with the earlier seeding
  law: `scheduleFsrs`'s first-review branch (`reps == 0`) ignores a
  seed's stability/difficulty entirely, so seeding a genuinely fresh item
  degrades safely to a fresh FSRS card.
- The due-queue's due-check now follows the active scheduler too — a
  necessary companion to dispatch, not a separate ask. Grading under FSRS
  freezes the classic half of a card's state (by the lossy-switch-back
  law above); a due-check that kept reading frozen classic dates would
  make the same card appear due forever once FSRS took over. Unlock and
  mastery gating (`study_core`'s `nodeUnlocked`/`nodeProgress`) stay
  Classic-`CardState`-based regardless of scheduler — that DAG is
  untouched study_core surface, and curriculum progression is treated as
  a separate concern from "which scheduler computes review timing." A
  course studied entirely under FSRS still unlocks and masters exactly
  as a Classic profile's would; this is a real, stated scope limit, not
  a hidden one.
- The toggle lives on the Courses tab's settings menu (a
  `PopupMenuButton` + `CheckedPopupMenuItem`, the exact idiom the reader
  already uses for its own settings escape — ADR-0006 — not a new
  convention). Switching TO FSRS asks first, with one sentence naming the
  actual consequence ("FSRS's own progress won't carry over"), because
  that direction has a real, easy-to-miss cost; switching BACK to Classic
  is instant, no dialog, because Classic's state was never touched while
  FSRS was active — there is nothing new to warn about.
- One discovered, intentional scheduler difference surfaced by wiring
  this for real: a lapse ("Again") under FSRS is not re-queued
  in-session the way SM-2's always is, because FSRS schedules at least
  one day out even for a lapse (the day-granularity decision above), so
  same-day relearning steps do not exist for it. Tested as a positive
  assertion so it reads as intentional, not as a silent gap.

## Consequences

- Nothing in `study_core/lib/src/models.dart` or `sm2_scheduler.dart`
  changed; the sealed suite's 104 tests are the same 104 tests, run
  unmodified, confirmed green both before and after this campaign.
- Schema grew three versions (v8 -> v11): `Profiles.scheduler`
  (addColumn), `Captures` (createTable, rides the backup payload as a
  rider on its work row rather than touching `backup_core`'s shared
  `espalierBackupTables` constant — three donor-import paths also iterate
  that list), `DailyReviewCards` (createTable). All five pre-existing
  Drift migration tests that seed a pre-v9 database needed one new
  `DROP COLUMN scheduler` line in their teardown SQL (the non-idempotent-
  `addColumn` landmine); no existing migration test needed changes for
  either new table (`createTable` migrations are idempotent).
- `SpineDao.deleteWork` now also deletes a work's captures — FK
  enforcement is on, so an orphaned capture row would otherwise block its
  own work's deletion. Found by reading `deleteWork`'s existing manual
  per-table delete list before adding the new table, not by a failing
  test surfacing it later.
- The FSRS scheduler is real, tested, reachable through the actual study
  session, and switchable per profile through a real settings surface —
  not just correct at the pure-function level. The one remaining, stated
  scope limit is curriculum progression (unlock/mastery): it stays
  Classic-`CardState`-based under either scheduler, since study_core's
  prereq DAG functions are untouched surface this campaign did not
  extend. Making mastery itself scheduler-aware would mean either
  changing `study_core`'s progress functions or building a
  classic-shaped adapter view over FSRS state purely to feed them —
  real, larger follow-up work, named here rather than attempted under
  this campaign's time budget.
- A Flutter test-harness landmine surfaced while proving the reopen-
  after-switch case: `pumpWidget` reuses an existing element in place
  when the widget type and tree position match, skipping
  `initState`/`_load` entirely — a "reopened" `StudySessionScreen`
  without a distinct `Key` silently showed the FIRST session's stale,
  already-completed state. Confirmed via a standalone DAO-level check
  that the actual queue/dispatch logic was correct before concluding it
  was a test bug, not a session bug (`systematic-debugging`'s law: don't
  fix what you haven't reproduced).
