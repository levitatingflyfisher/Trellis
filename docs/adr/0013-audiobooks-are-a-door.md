# ADR-0013: Audiobooks are a door

- Status: Accepted — Phases 1, 2 and 4 shipped this pass; Phase 3 (the
  transcribed-audiobook read↔listen handoff) investigated and NOT built —
  see its own section for exactly where it resists and why forcing it was
  declined rather than attempted.
- Date: 2026-08-15

## Context

The commission: prove an audiobook player by subtraction — a folder IS
the book. This app already had the player (background-capable audio,
speeds, a sleep timer, smart resume, an Up Next queue — Campaign 1, "the
player earns love"), local-file-over-URL playback and a real download
door onto disk (Campaign 6, ADR-0012), and the position law (ADR-0002).
The brief was never "build an audio engine" — it was "give a folder of
files a door onto the engine that already exists."

Two premises the spec handed this campaign turned out to be false, and
both mattered to the design:

1. **"Follow whatever the existing bulk text-import door does on
   Android."** No such door exists. Grepping the whole app for
   `getDirectoryPath`/multi-file `pickFiles` turned up nothing outside
   `course_import.dart`/`feeds_screen.dart`/`epub_intake.dart`/
   `backup_gateway.dart` — all single-file pickers. `docs/reference/
   feature-matrix.md`'s "Bulk multi-file + true folder import on native
   (file_picker directory mode)" row, listed under Covered, was never
   backed by code — corrected in this pass (Phase 4 below), the same
   "claim outlived the code" failure mode this fleet's own build loop
   warns about, except here the claim never had code behind it at all.
2. **"Podcast audio bar: chapters (podcast:chapters JSON + PSC)."** Also
   listed Covered, also not real: `comms_core`'s feed parser DOES parse
   `<podcast:chapters>`/`<psc:chapters>` into `FeedItem.chapters`/
   `chaptersUrl` — but `feed_ingest.dart`'s `ingestFeedItems` never reads
   either field. The parse exists; nothing downstream consumes it. Also
   corrected in Phase 4. Wiring feed chapters is explicitly OUT of this
   campaign's scope — the correction is to the claim, not a fix to the
   gap.

Since there was no existing folder/bulk-import door to imitate, the
referenced-vs-copied law below was derived from first principles (how
`file_picker` actually behaves on this app's one shipped native tier)
rather than inherited from precedent that turned out not to exist. The
closest real analog in this codebase is EPUB import (`epub_intake.dart`):
it never keeps the picker's own path either — it reads bytes immediately
and never touches that path again. Audio files are too large to hold as
in-memory bytes the way a parsed EPUB's segments are, but the underlying
law — never trust the picker's path to still be good later — carries
over exactly.

## Decision 1 — referenced-vs-copied: copied, always

Investigated directly against the pinned `file_picker: ^10.3.8` (resolved
10.3.10) Android implementation (`FileUtils.kt`), not assumed from the
package's README:

- **`getDirectoryPath()`** resolves a SAF tree URI to a best-effort real
  filesystem path via string manipulation of the document ID
  (`getFullPathFromTreeUri`) — e.g. `primary:Music/Book` becomes
  `/storage/emulated/0/Music/Book`. It never calls
  `takePersistableUriPermission`. There is no durable grant behind the
  returned string at all; it's a guess, valid at best for the instant it
  was resolved, on a device whose volume layout matches the heuristic.
- **`pickFiles()`** (the non-directory picker this campaign actually
  uses — see Decision 2) resolves each `content://` document through
  `ContentResolver.openInputStream` and writes it into
  `context.cacheDir + "/file_picker/" + timestamp + "/" + filename`
  (`FileUtils.kt`, the `fileFromUri` path) — a real, immediately-readable
  file, but an OS-owned CACHE directory the app doesn't control the
  lifetime of, not a stable reference.
- `android/app/src/main/AndroidManifest.xml` declares no
  `READ_EXTERNAL_STORAGE`/`READ_MEDIA_AUDIO` permission, and the fleet's
  own minimal-permission convention (Furrow ships with NO `INTERNET`
  permission at all; this app already asks for as little as it can) is a
  real cost against adding one just to make a raw-path read reliable.

None of that is a foundation to promise "your files stay where they
are." **The law: every picked file's bytes are copied into app storage at
import time** (`supportDir/audiobooks/<workId>/<fileIdx><ext>`, mirroring
`DeviceServices.audioFileFor`'s existing `supportDir/audio/<workId><ext>`
shape one level deeper for a multi-file work). This is also the ONLY law
this pass ships, not a platform-conditional one: the workshop's own map
lists this app as **Flutter · Android + PWA** with no shipped desktop
artifact, so a second, referenced-in-place code path for a `linux/`
dev-convenience build that never ships would be speculative complexity
bought for nothing — that path stays honestly unbuilt, not half-built.

The real cost, stated plainly: importing a 10-hour audiobook doubles its
disk footprint for the length of the import (source + copy) and leaves a
permanent copy on top of whatever the user's file manager still holds.
Given the alternative (a raw path read that Android's own scoped-storage
enforcement may or may not actually honor, with zero durability across
app restarts even when it works once), this is the honest trade, not a
free one.

## Decision 2 — "folder" collapses to "multi-select audio files"

Since `getDirectoryPath()`'s returned path can't be trusted for a
directory WALK any more than for a single read, offering it on Android
would be offering something this campaign can't back with the same
verification standard as everything else in it. The system's own
document picker already lets a user navigate into an album folder and
select every track in one gesture — mechanically that IS this app's
folder import, and every file it returns goes through `pickFiles()`'s
reliable content-resolver path (Decision 1) rather than the unreliable
tree-URI heuristic. `FilePickerAudiobookGateway.pickFiles()`
(`lib/features/intake/audiobook_picker_gateway.dart`) is the one door;
`getDirectoryPath` is never called anywhere in this campaign's code.

## Decision 3 — the chapter parser: chpl atom only, verified against ffmpeg

`packages/intake_core/lib/src/m4b_chapters.dart`'s `parseM4bChapters`
walks ISO-BMFF boxes looking for `moov/udta/chpl` — the "Nero chapters"
atom most audiobook tooling (`m4b-tool` included) writes — and nothing
else. The byte layout (`version(1)` + `flags(3)` [+ a 4-byte reserved
field iff `version != 0`] + `chapter_count(1)`, then per chapter
`start(8, big-endian, 1/10,000,000s ticks)` + `title_len(1)` +
`title(UTF-8)`) was fetched and read directly from FFmpeg's own
`mov_read_chpl` (`libavformat/mov.c`, `github.com/FFmpeg/FFmpeg`) rather
than reconstructed from memory or a secondary source — a wrong tick
divisor would produce chapters that silently seek to the wrong place,
exactly the kind of bug no test against a made-up format could catch.

Deliberately NOT built: the QuickTime chapter-TEXT-TRACK mechanism (a
`trak`/`tref`/sample-table cross-reference — genuinely "a general MP4
parser" territory) and ffprobe-based chapter extraction (would have
meant spawning a process per file just to read a handful of bytes this
app already has the format knowledge to parse itself). The walker only
ever descends into `moov` and `udta`; every other box — `mdat` especially,
the multi-hundred-megabyte audio payload — is skipped by its declared
size, never opened.

**The chapter list is computed live, never persisted.** No
`AudiobookChapters` table exists. `lib/features/player/
audiobook_chapters.dart`'s `chaptersFor` re-parses each file's first
`audiobookChapterPrefixCap` (32MB) on demand, when the Chapters drawer
opens — a well-formed file's `moov` box lives near the front, long before
the audio payload, so this never means reading a multi-hundred-MB file.
A file whose `chpl` never turns up (an MP3, or an M4B with no chapter
atom, or one whose `moov` genuinely lands past the cap) contributes
exactly one chapter of its own, starting at offset 0 — "each file is a
chapter," applied uniformly rather than as a special case bolted onto the
M4B path. This trades a few milliseconds of re-parsing per drawer-open
for zero migration-fixture tax and zero staleness risk (a chapter table
could drift from the file it describes; a live re-parse cannot).

## Decision 4 — schema v17: two new tables, two extended columns

- **`Audiobooks`** (`workId` PK, `speedOverride`) — the per-book settings
  row, created once at import.
- **`AudiobookFiles`** (`id`, `workId`, `fileIdx`, `path`, `durationMs`) —
  the ordered file list. `durationMs` starts null and is filled in
  lazily, the first time each file actually plays
  (`PlayerController._onDuration`) — nothing at import probes it (see
  Decision 7 for why the library tile doesn't need it sooner).
- **`PlayerPositions.fileIdx`** (new column, `NOT NULL DEFAULT 0`) — the
  position law's file axis. Extending this table rather than inventing a
  parallel one was deliberate: `PlayerPositions` is already work-scoped,
  not feed-scoped (unlike the columns Decision 5 explicitly avoided
  generalizing) — it's the existing "no-alignments raw position"
  fallback for ANY audio work, episode or book, and every pre-campaign
  row's `fileIdx` defaults to 0 and is simply never read differently.
- **`Captures.fileIdx`** (new column, nullable) — a capture's own file
  axis. Required, not optional: a book-global millisecond would only be
  sound if every preceding file's duration were already known at capture
  time, and `AudiobookFiles.durationMs` is filled in lazily (Decision 7)
  — a capture taken in file 3 of a book whose files 0–2 have never
  finished playing has no way to compute a cross-file offset. Null means
  "not applicable" (every episode/text-work capture, where `positionMs`
  alone is already unambiguous), never "unknown".

`schemaVersion` moves 16 → 17, guarded `if (from < 17)` for the two new
tables (never created anywhere else, so unconditional — the same shape
`courses`/`cards`/`wordLedger` used before it) and `if (from >= 2)` /
`if (from >= 10)` inner guards for the two column additions, matching
each column's host table's own creation version exactly (`playerPositions`
from v2, `captures` from v10) rather than copying the `from >= 2` guard
other campaigns used for feeds/episodes columns — a `captures.fileIdx`
addColumn guarded on `from >= 2` would have tried to alter a table that
doesn't exist yet for a migration starting between v2 and v9.

### The migration-fixture tax, paid in full — and only one error shape, not two

The same 8 files under `app/test/db/` the DSP campaign found
(`captures_db_test.dart`, `daily_review_db_test.dart`,
`feeds_db_test.dart`, `household_db_test.dart`, `jobs_db_test.dart`,
`ledger_db_test.dart`, `profiles_db_test.dart`, `study_db_test.dart`),
across 9 seed-and-strip blocks (`feeds_db_test.dart` alone carries the
v11→v12 and v12→v16 blocks; the other 7 files carry one each; the file's
own v1→v2 block is hand-written raw SQL for a true v1 schema and needed
no change — it never contained the new columns/tables to strip in the
first place). Bumping `schemaVersion` to 17 without touching the
fixtures broke every block that seeds via `AppDatabase.forTesting()`
(which always builds the CURRENT compile-time schema, new tables and
columns included) then strips down to an older `user_version`. Run
directly (`flutter test test/db/study_db_test.dart`) before any fixture
edit, the v2→v3 block failed exactly once, with exactly one error shape:

```
SqliteException(1): while executing, duplicate column name: file_idx, SQL logic error (code 1)
  Causing statement: ALTER TABLE "player_positions" ADD COLUMN "file_idx" INTEGER NOT NULL DEFAULT 0;
```

Honestly: only that one block (`study_db_test.dart`'s v2→v3) was run
pre-fix and watched RED directly, with exactly the one shape above and no
`table audiobooks already exists` error alongside it. The other 8 blocks
were NOT individually run pre-fix — an earlier draft of this ADR claimed
that second error shape and a `DROP TABLE` fix for it, for all 9 blocks,
without having run the suite to check any of them; that was wrong and is
corrected here. What justifies extending the same columns-only fix to the
other 8 without watching each one RED first is `Migrator.createTable`'s
own idempotency: drift's schema-creation DDL is safe to re-issue, only
`addColumn` is not, and three of this codebase's own migration fixtures
already said so before this campaign touched them (`household_db_test.dart`:
"`createTable` is idempotent, so leaving them out here is safe, unlike an
omitted column"; `study_db_test.dart`, this campaign's own comment above:
"migrations are idempotent (CREATE TABLE IF NOT EXISTS) so later tables …
surviving from the live schema don't matter here") — plus the v2 block's
own empirical proof, once fixed, that re-running `CREATE TABLE audiobooks`
against a snapshot that already has it is a harmless no-op. `Audiobooks`
and `AudiobookFiles` therefore need no `DROP TABLE` anywhere. The fix in
every block is only the
two new **columns**: `ALTER TABLE player_positions DROP COLUMN
file_idx;` in every block whose seeded version is ≥2 (i.e. all 9 — the
table exists from v2), and `ALTER TABLE captures DROP COLUMN file_idx;`
additionally in every block whose seeded version is ≥10 (`daily_review_db_test.dart`
at v10, and `feeds_db_test.dart`'s v11 and v12 blocks — three of the
nine; `captures_db_test.dart` seeds at v9, one version before the table
exists, and already drops the whole table for that reason, so it takes
only the `player_positions` line). Each line was appended after the
block's existing strip statements, never reordering what was already
there. `flutter test test/db/` — all 105 tests, 8 files plus the
untouched `spine_db_test.dart`/`queue_db_test.dart`/`library_dao_test.dart`
— passed clean after the fix.

## Decision 5 — per-book speed: a parallel column, not a generalized one

`Feeds.speedOverride`/`skipIntroSeconds`/`skipOutroSeconds`/
`keepLatestAudio` are feed-scoped by construction — every read site
(`PlayerController.playWork`'s `_currentFeed?.speedOverride`,
`FeedSettingsScreen`) assumes a `Feed` row exists. An audiobook has no
feed. Generalizing those columns to "any audio source" was considered
and declined: it would mean either fabricating a feed-shaped row for
every book (a real row in a table whose every other column — `url`,
`etag`, `breakerJson`, the refresh breaker — means nothing for a local
file) or touching every one of those read sites to thread a new
optional-feed-or-book union through, for a feature (per-book speed) the
spec asked for narrowly. `Audiobooks.speedOverride` — one column, the
audiobook parallel to `Feeds.speedOverride`, read once per load into
`PlayerController._currentAudiobookSettings` exactly the way
`_currentFeed` is — costs one small table and touches nothing that
already existed. Skip-intro/skip-outro/keep-latest-audio have no
audiobook analog at all (there is no "latest N" to keep for a single
static book, and skipping an intro on every one of a book's files would
be wrong far more often than right) and were never ported.

## Decision 6 — the shared-player principle, made real

`EpisodePlayer` (the interface `just_audio` lives behind) gains
`setFilePaths(List<String>, {initialIndex, initialPosition})` and
`currentIndexStream`/`currentIndex`, mirroring the exact shape ADR-0012
used to add `setFilePath` alongside `setUrl` — and mirroring, more
directly, the reader's own speech queue
(`lib/features/reader/speech/just_audio_speech_queue.dart`), which
already proved gapless multi-clip playback through `just_audio`'s own
`AudioPlayer.addAudioSource`/`currentIndexStream` for TTS sentences.
`JustAudioEpisodePlayer.setFilePaths` calls `AudioPlayer.setAudioSources`
directly — this app never re-loads between an audiobook's files or drives
the transition itself; the engine advances `currentIndex` and the
playhead on its own, and `completedStream` fires exactly ONCE, after the
LAST file, not once per file. That single fact is what "auto-advance with
zero-gap intent" actually rests on: there is no auto-advance CODE in this
campaign, because nothing needs to be written to make it happen.

`PlayerController.playAudiobook`/`playAudiobookAt` load the whole file
list as one playlist and otherwise run through the SAME machinery every
episode already uses: `_ensurePlayer()`'s one set of stream subscriptions
(sleep timer tick, outro-cutoff tick — a no-op for a book, since
`_currentFeed` is null — duration handler, completion handler, now also
the current-index handler), the same sleep timer, the same smart-resume
rewind on `toggle()`, the same Up Next queue (`_advanceQueue` now
branches on `next.kind == 'audiobook'` to call `playAudiobook` instead of
`playWork`, since a book carries no `sourceUrl` for the single-file law
to stream). What DOES fork on `isAudiobook`: `saveProgress` (writes
`PlayerPositions` with the current file index rather than projecting
through alignments — Decision 4), `capture` (tags the capture with the
current file index), and `_onDuration` (writes `AudiobookFiles.durationMs`
for the current file rather than `Episodes.durationMs`, since an
audiobook work has no `Episodes` row for that write to land in at all).

**A trust boundary worth stating precisely, because nothing in this
codebase can test it against a real player.** `FakeEpisodePlayer`
(`test/support/fake_player.dart`) models the gapless-playlist contract by
NEVER auto-advancing `currentIndex` or firing `completedStream` on its
own — a test must call `emitCurrentIndex` for each file boundary and
`emitCompleted` exactly once, at the true end. If the fake instead fired
completion once per file, every test would pass against a "finish" law
that doesn't match what `just_audio`'s real engine actually does for a
gapless playlist load, and the bug (an audiobook "finishing" — promoted,
marked done, advancing the Up Next queue — after its FIRST file rather
than its last) would ship invisibly. This is recorded here because it is
exactly the kind of gap the fleet's own "tests that pass while testing
nothing" law exists to name, and the mitigation is a doc comment plus a
deliberately-shaped fake, not a test against real `just_audio` (which —
like `JustAudioEpisodePlayer` and `FfmpegDecoder` before it — is
unexercised by this suite on this host, an honest gap this pass didn't
close, not a new one it opened).

## Decision 7 — the library tile: file-count-coarse, never time-precise

New/Started/Finished read exactly the signals that already exist:
Finished is `Works.finishedEpochDay != null`; Started is a
`PlayerPositions` row existing; New is neither. The progress FRACTION for
an audiobook is `fileIdx / fileCount` — how far through the file list the
stored position has reached, ignoring the offset within the current file
— never a precise time-based fraction. This is not a shortcut taken for
lack of time; it's the honest fraction available given Decision 4's own
constraint: a file's duration is learned only once it has actually
played, so a book whose later files have never played has no total
duration to divide by. `fileIdx / fileCount` needs nothing an import
never had to compute — no duration probe runs at import time at all,
which also means this door works identically fast whether the picked
book is three files or thirty. The Voice/SABP shape the spec names is
exactly this: a coarse, always-available signal over a precise one that
would sometimes be unavailable.

## Phase 3 — investigated, not built, and precisely why

The transcribed-audiobook read↔listen handoff needs `TranscribeCoordinator`
to accept a local audiobook's audio instead of fetching an episode's
enclosure URL. Tracing `TranscribeCoordinator._drive`
(`lib/features/transcribe/transcribe_coordinator.dart`) found the audio-
fetch step IS already conditional on presence (`if (!audio.existsSync())`,
skipping the network fetch entirely when a file is already on disk) — the
promising half. The blocking half is structural, in three independent
places, not one:

1. **The storage path itself.** `services.audioFileFor(workId, url)`
   resolves ONE path per work (`supportDir/audio/<workId><ext>`); an
   audiobook's files live at `supportDir/audiobooks/<workId>/<fileIdx><ext>`
   — a different location, and there are N of them, not one.
2. **One PCM file, one whisper run, per work.**
   `services.pcmFileFor(workId)` and `TranscribeSpec.pcmPath` both assume
   a SINGLE continuous decoded audio stream. Transcribing a multi-file
   book would mean decoding and concatenating every file into one PCM
   before a single whisper run could begin (or running whisper once per
   file and stitching results — a different, also-unbuilt design), not a
   parameter this pipeline already has a slot for.
3. **`Alignments` is a single time axis, with no file dimension at all**
   (`workId, segmentIdx → tStartMs, tEndMs` — no `fileIdx` column, unlike
   `PlayerPositions`/`Captures`). Even with problem 2 solved by
   concatenation, every alignment's `tStartMs`/`tEndMs` would need to be
   BOOK-global milliseconds, while `PlayerController`'s own `position`
   for an audiobook is CURRENT-FILE-relative (Decision 6, `just_audio`'s
   playlist semantics) — the exact mismatch Phase 1/2 avoids entirely by
   never populating `_alignments` for an audiobook work in the first
   place (`_loadAudiobook` sets `_alignments = const []` unconditionally).
   Wiring Phase 3 would mean either projecting current-file-relative
   positions through book-global alignments on every tick (a real,
   nontrivial piece of arithmetic this schema has no home for yet) or
   extending `Alignments` with the same `fileIdx` axis
   `PlayerPositions`/`Captures` already carry — itself a schema hop, with
   its own migration-fixture tax, on top of everything else this pass
   already touched.

None of these is a quick fix sitting one call away — each is its own
design decision (concatenate-then-transcribe vs. per-file-then-stitch; a
book-global vs. per-file alignment axis) that this pass's own time budget
does not cover honestly. Per the spec's own stated escape hatch ("if the
alignment path is episode-shaped in ways that resist, record precisely
where and stop rather than forcing"), Phase 3 stops here, recorded as
three named blockers rather than attempted as a shortcut that would have
produced a Whispersync that silently mis-seeks on every file boundary but
the first.

## Consequences

- Every audiobook file this app ever imports is a permanent COPY, never a
  reference — a real, stated disk-space cost (Decision 1), not a free
  win. A future pass revisiting Android's `MANAGE_EXTERNAL_STORAGE` or a
  durable SAF permission grant could relax this; not attempted here
  because the permission cost was judged not worth it for this pass.
- Disc/track-metadata-aware ordering (`orderAudiobookFiles`'s tagged
  branch, `intake_core`) is real and tested at its own layer but UNWIRED —
  nothing in this campaign's import flow ever populates a tag, so every
  real import falls through to natural sort. `ffmpeg_kit_flutter_new_audio`
  (already pinned, already used for DSP's duration probing) exposes
  `MediaInformation.getTags()`, which is the real, low-risk future door —
  Android-only, though, since nothing wires ffprobe on the desktop dev
  build, which is itself a reason this wasn't done automatically as part
  of this pass (a probe that only works on one platform is a worse
  default than none at all).
- The mini player bar's action row gains a Chapters icon, shown only when
  `controller.isAudiobook`. Read as "a seventh icon on top of six" it would
  be a real 320dp/2× regression risk — but an audiobook never has
  alignments (`_loadAudiobook` sets them to `const []`), and the karaoke
  icon's own gate is `hasAlignments`, so karaoke and Chapters can never
  both show: Chapters stands IN PLACE of karaoke, not alongside it. The
  worst-case simultaneous count for an audiobook (capture, captures,
  queue, chapters, sleep timer, close = 6) is exactly what
  `narrow_screen_test.dart`'s existing sweep already pins for an episode
  with alignments. Verified directly rather than left as an inferred
  gap: `test/features/mini_player_audiobook_320_test.dart` pumps
  `MiniPlayerBar` at 320×640/2× with every optional callback wired and an
  audiobook loaded — no overflow.
- `docs/reference/feature-matrix.md`'s "true folder import" and
  "podcast:chapters" rows are corrected (Phase 4) to say what the code
  actually does today, rather than repeat a claim two campaigns now have
  found unbacked.
