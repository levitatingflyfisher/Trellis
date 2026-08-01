# ADR-0015: Honest feeds, and the media-session gap

- Status: Accepted — all three decisions shipped. Decision 3 (the
  media-session package) was first deferred mid-campaign, then
  implemented as Phase 2e once orchestrator review overruled the
  deferral: it is the user's #1 device complaint, and the campaign is
  named after their feedback — see that section for the honest history
  of both calls.
- Date: 2026-08-16

## Context

Campaign 9 ("the shakedown") is not a feature campaign — it is the first
real device test of 1.3.0 coming back with a list of things that felt
wrong in the hand: a river that "just grabs the title" from Substack-
shaped feeds, a library full of dateless stubs indistinguishable from
kept articles, a mini player that vanishes without a trace after a
restart, and a highlighted reading cursor that "just sat there" while
audio kept moving underneath it. Most of the phases below are additive
UI/UX passes that don't warrant their own ADR (they're recorded in the
CHANGELOG and the campaign's own commit history instead). Three
decisions in this pass are load-bearing enough to record here — all
three shipped, though Decision 3 took a detour through being deferred
first (see that section for the honest history).

## Decision 1 — a feed item's body comes from `content:encoded`, never a 300-char guess

The parser (`comms_core/lib/src/feed_parser.dart`) read `description`
first and fell back to `content:encoded`/`content` only when description
was empty, then capped whatever it found at 300 characters
(`_cleanDesc`). Ingestion (`feed_ingest.dart`) turned that one capped
string into the work's ENTIRE body. A Substack-shaped feed — description
holds a teaser, `content:encoded` holds the full post — was read as a
300-character stub no matter how long the actual post was.

The fix reads `content:encoded`/`content` into a NEW field
(`FeedItem.contentHtml`, raw and uncapped) unconditionally, independent
of whether `desc` resolved to something. `desc` itself is untouched —
it's still what list rows show, and it's still what a podcast episode's
body becomes (show-notes are what show-notes are; see Decision 2 for
why that's a persistence problem, not a content one). Ingestion
(`_segmentsFor` in `feed_ingest.dart`) builds a text item's segments
from `contentHtml` through intake_core's OWN `extractArticle` — the
exact function URL intake already runs HTML through
(`article_fetch.dart`) — whenever `contentHtml` parses to something
MEANINGFULLY LONGER than `desc` (a simple length comparison; a host
whose `content:encoded` merely repeats the excerpt falls back to the
plain `desc` segment, unchanged from before this pass). Writing a
second HTML-to-segments converter would have been exactly what the
fleet's "no second copy" law forbids.

**Honesty note, stated once here rather than implied by the feature
matrix's silence:** this only recovers full posts from feeds that
actually SHIP full posts in RSS. A paywalled or deliberately-truncated
feed still yields an excerpt — there is no post to recover, and nothing
in this decision claims otherwise.

## Decision 2 — the library shows works, the river shows ephemera; that split is now enforced, not assumed

ADR-0002's own model already drew this line: every feed item arrives as
`persistence: 'ephemeron'`, and promotion (`SpineDao.promoteWork`, wired
to the river's "Keep" gesture) flips it to `'work'`. The library's own
query (`LibraryDao.libraryQueryEntriesOf`) never enforced it — every
ephemeron sat in the library list beside real works, with no date to
even suggest which was which (`library_screen.dart`'s row had a
progress bar and nothing else).

The fix is a one-line where clause
(`works.persistence.isNotValue('ephemeron')`) plus a date subtitle
(published date for a kept episode, added date for anything else — the
river already showed dates; the library now matches). The exclusion is
written as "not ephemeron" rather than "equals work" deliberately: only
two `Persistence` values exist today, but an allow-list of one silently
drops a work the moment a third value ever exists, where an exclusion
list fails VISIBLY (a work simply shows up) instead.

## Decision 3 — the media-session package: `just_audio_background`, deferred then wired

The device report — "when something is playing I have no ability to
control it on the lock screen or the pull-down tray" — names the user's
#1 finding from the whole campaign. The honest history of this decision
has two halves, both kept below rather than quietly replaced: first
deferred mid-campaign, then implemented as Phase 2e once orchestrator
review overruled that deferral — this is the finding the campaign is
named after; shipping the release without it would have meant the
user's top complaint survived the entire pass built to answer it.

**First call, mid-campaign**: the package was added
(`flutter pub add just_audio_background`), its API and manifest
requirements researched, then REMOVED again (`flutter pub remove`) —
wiring it correctly looked like its own multi-commit unit of work, not
a slice that fit alongside the eight other phases this campaign was
already carrying. That research was recorded in this ADR rather than
lost, precisely so a later pass wouldn't have to re-derive it.

**Second call, at review**: the research turned out to be the hard
part, and it was already paid for. Phase 2e spent it:

- **The package**: `just_audio_background`, the official companion to
  `just_audio` (already this app's playback engine —
  `PlayerController`/`EpisodePlayer` in `app/lib/features/player/`,
  ADR-0001's hybrid-adoption line). `audio_session` — the focus/ducking
  dependency this ADR flagged as "very likely also needed" — turned out
  unnecessary as a DIRECT dependency: it rides in as
  `just_audio_background`'s own transitive requirement, and Phase 2e
  writes no focus/ducking code of its own, so pinning it directly would
  have been dead weight.
- **`JustAudioBackground.init()`** runs once at startup, behind the io
  bootstrap ONLY (`bootstrap_io.dart`'s new `initAudioBackground()`,
  joining `createDb`/`createServices`/`createFetcher`/`databaseFile` as
  the conditional-export trio's fifth name) — a no-op stub on
  `bootstrap_web.dart` so `main()` calls it unconditionally on every
  platform. `flutter build web` was run as a smoke check after wiring
  and succeeded unchanged; the package's own Dart API compiles under
  web (it lists Web as a supported platform), so tagging an
  `AudioSource` costs nothing on a tier where `init()` was never called
  — nothing there ever consumes the unused tag.
- **A `MediaItem` tag on every `AudioSource`** the player loads —
  episode, audiobook, and the rehydration path (Phase 2c), which
  reaches the SAME two loaders on its first `toggle()` rather than a
  third path of its own. `PlayerController` builds the tag via a new
  pure function, `lockScreenTagFor` (`media_item_mapping.dart`) —
  deliberately named `LockScreenTag`, not `MediaItem`: the package
  itself already exports a class called `TrackInfo`, which collided
  with this ADR's own working name the moment `just_audio_player.dart`
  imported both packages together (`flutter analyze lib/` caught it
  immediately). `id` = work id, `title` = work title, `album` = the
  feed's title for an episode (null for an audiobook, which has no feed
  to name one from), `artUri` = `DeviceServices.artworkFileFor`'s
  result — but ONLY once `existsSync()` confirms it, the SAME gate
  Phase 5c's river thumbnail already established: a deterministic path
  is not proof a file was ever downloaded. `lockScreenTagFor` is pure
  and unit-tested directly (`media_item_mapping_test.dart`, watched RED
  before the implementation existed); `PlayerController`'s own tests
  prove the tag actually reaches `EpisodePlayer` on both load paths.
- **The Android manifest** gained the package's own required `<service>`
  (the background session, `foregroundServiceType="mediaPlayback"`) and
  `<receiver>` (`MEDIA_BUTTON`) elements, verbatim from its README.
  `FOREGROUND_SERVICE_MEDIA_PLAYBACK` was already declared and unused —
  this is the work that makes it true. Neither element declares a new
  permission, so `fleet_conformance`'s C4 (the exact source-manifest
  permission surface, both directions) stayed green untouched.
- **The single-player law**: the package "supports the simple use case
  where an app has a single `AudioPlayer` instance" (its own README).
  Verified, not assumed: `PlayerController._ensurePlayer()` constructs
  exactly one `EpisodePlayer` per controller, lazily, and caches it;
  `HomeShell` constructs exactly one `PlayerController` for the whole
  app; `KaraokeScreen` takes that same controller rather than building
  its own. One player, for the app's entire lifetime — the law holds
  without any code needing to change to satisfy it.

**What stays honestly unverified**: lock-screen RENDERING is
device-only. Every test above proves what reaches the tag; none of them
prove how Android or iOS draws it. `docs/reference/feature-matrix.md`'s
"Background podcast playback" row moves from Degraded into Covered,
worded "shipped, pending device confirmation" so the next device test
is what closes this, not another read of the code.

Phase 8 of this same campaign generated the notification small icon
(`android/app/src/main/res/drawable-*dpi/ic_notification.png`,
white-on-transparent) ahead of this work landing; it is no longer an
orphan — `initAudioBackground()`'s `androidNotificationIcon` parameter
references it by name.

## Consequences

- Decision 3's own history is the record of a deferral being overruled,
  not erased: the research that justified deferring it is still true
  and still above, now followed by what was built from it.
- `docs/reference/feature-matrix.md`'s "Background podcast playback" row
  moved from Degraded to Covered, worded "shipped, pending device
  confirmation" — corrected in place (not silently rewritten) so the
  honesty this ADR already committed to survives the status change.
- All three decisions are testable in isolation from anything
  device-only (parser fixtures, DAO query tests, a pure mapping
  function, a scripted player) and are covered that way —
  `packages/comms_core/test/feed_parser_test.dart`,
  `app/test/db/library_dao_test.dart`, `app/test/features/
  library_flow_test.dart`, `app/test/features/
  media_item_mapping_test.dart`, `app/test/features/player_test.dart`,
  `app/test/features/audiobook_player_test.dart`.
