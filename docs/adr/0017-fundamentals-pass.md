# ADR-0017: The fundamentals pass

- Status: Accepted
- Date: 2026-10-22

## Context

An audit read the app against the scale it has to survive: 300 feeds,
50k episodes, 2M transcript segments, on a mid-range phone (Pixel 6a).
Much of it held up. The gaps were plain ones: no secondary indexes,
per-row delete loops, feed XML and EPUBs parsed on the UI isolate,
impolite fetching, and an SSRF guard that only read the URL's text. Each
section below says what changed and why. Where the audit's claim turned
out false, the section says that too.

## Decision

### 1. Database basics (schema v26)

Before v26 the schema had no secondary indexes. Every refresh, river load
and work delete scanned whole tables. v26 adds the indexes the hot
queries need (`lib/db/indexes.dart`): episodes by (feed, published) and
by duplicate-of, a unique (feed, guid), works by (profile, persistence),
plus one index on every child foreign-key column that no key already
leads with. With `foreign_keys = ON`, each parent delete checks every
child, so a missing index there means a full scan per deleted row. Revlog
has no work or course column, so its card column is the one indexed. The
indexes are raw `IF NOT EXISTS` DDL run from both `onCreate` and the v26
hop, because the upgrade path's `createTable` calls build tables without
drift-declared indexes. Before the unique index lands, the migration
keeps the oldest row of any twin (feed, guid) pair. An unkept twin is
deleted; a kept one stays in the library without its river row.
`EXPLAIN QUERY PLAN` tests over the DAOs' own SQL prove `guidsOf`,
`episodesOfFeed` and `riverItems` scan nothing.

Native connections now run WAL, `synchronous = NORMAL` and a 5 s busy
timeout, so a refresh's writes no longer block the UI's reads. Web
storage has no shared memory for WAL, so the web build skips that part.

`deleteWork` is now `deleteWorks`: one statement per table per chunk of
500 ids, under SQLite's old 999-variable cap, all in one transaction. The
sweep, purge, unfollow and profile delete use it. The audit said
`fillMissingMetadata` wrote updates that changed nothing. That was false:
it already returned early. The real cost was one SELECT per seen item, on
every refresh. Ingest now loads which seen rows have a gap once, and asks
only about those.

### 2. Off the UI isolate

A feed body of 256 KB or more is now hashed and parsed with Flutter's
`compute`. That runs on a fresh isolate natively and inline on the web,
which has no isolates. Smaller bodies parse inline, since a new isolate
costs more than parsing them. comms_core's archive walk takes the parser
as a parameter, so the package stays pure while the app hands it the
off-isolate one. The new `feeds.body_hash` (v26) is the SHA-256 of the
last body that parsed and ingested. It is written only after ingest
succeeds, so a failed ingest gets retried. When a fresh 200 brings
identical bytes, which hosts with no ETag or Last-Modified do all the
time, the parse is skipped. The refresh still counts as contact: failures
reset and validators are adopted. Changing a feed's rules clears the
hash, because the same body can ingest differently under new rules. The
skip also requires the feed to still have episode rows: once the sweep
or a purge has taken them all, the same body ingests again.

EPUB intake also parses and flattens through `compute`. On native, only
the picked file's path crosses into the isolate; the picker no longer
loads the bytes through the platform channel. intake_core refuses an EPUB
whose zip directory declares more than 200 MB unpacked
(`EpubTooLargeException`). The check runs before anything inflates, and
the message is fit to show: "This book is too large to open".

### 3. Feed-fetching manners

**Moves.** `FetchResponse.permanentUrl` reports the last URL reached
through an unbroken run of 301/308 hops; any 302 or 307 ends the run.
`IoHttpFetcher` fills it in. A browser can't see redirects, so the web
fetcher leaves it null. `FeedFetchResult.movedTo` carries it on fresh and
304 results. The feed row adopts the new address only once the answer
proves to be the feed: a body that parsed (against the new URL) and
ingested, or a 304. A host that 301s every URL to a parked page never
rewrites the address. If the profile already follows that address, the
row keeps its own: the two rows are one show, and merging their settings
and kept episodes is the listener's call. The usual post-ingest dedup
pass hides the episodes they share; nothing extra runs per refresh.
Subscribing through a moved URL stores the new address, or reports
"already following".

**Validators land last.** The validators (etag, last-modified), the body
hash and an adopted move are written only after ingest succeeds.
Written first, a failed ingest left validators that turned every later
fetch into a 304 for items that never arrived. Ingest reads its seen
guids inside its transaction, which drift runs one at a time, and
inserts episodes with `INSERT OR IGNORE`. A "Try again" overlapping a
refresh of the same feed therefore stores each item once, discards the
surplus work, and never throws on the unique (feed, guid) index.

**Backoff.** Each failure, whether fetch or parse, schedules
`nextAttemptMs`: 30 min × 2^(n−1), ±20 % jitter, never past 24 h. The
jitter keeps feeds that failed together from all retrying in the same
second. Automatic refreshes honour the schedule, including the Inbox's
pull-to-refresh, which never forced. A feed's own Try again forces, as it
always did. A broken feed now gets one automatic retry a week instead of
none. One that broke before v26 has no retry scheduled, so it is treated
as due, and its next failure schedules the following week. The copy says "checks this feed only once a week". A 304
un-breaks a feed, because the server answered.

**User-Agent.** `Trellis/<version> (+https://github.com/levitatingflyfisher)`
goes out on every native fetch, through `IoHttpFetcher` and Dio
downloads alike. The browser forbids setting it, so the web build
doesn't. The version is a const kept equal to pubspec's by a test; the
User-Agent can't wait on package_info's platform channel.

**Downloads.** The length check belongs to domovoi's `resumableDownload`.
It now throws `TruncatedTransfer` when the file that landed is shorter
than the host announced, so the check isn't duplicated here. Trellis
shows that as "The download stopped early. Try again.", and deletes the
engine's `.validator` sidecar wherever it deletes a `.part` itself
(dismiss, restore's discard, a model that fails its hash check).
Enclosure lengths from feeds are not used: they aren't stored, and feeds
misstate them often enough that trusting them would fail good downloads.
dart:io has no cheap free-space call, so the pre-download space check is
skipped. A full disk still fails with "This phone is out of space".

### 4. Security

**SSRF at the socket.** `assertSafeFetchUrl` reads only a URL's text, so
a public hostname that resolved to the LAN got through it.
`guardedHttpClient` (`lib/net/guarded_http_client.dart`) puts the check
in `HttpClient.connectionFactory`, which every connection passes through:
the first request, every redirect hop (including the hops Dio follows
inside the client), feed fetches, and episode and artwork downloads
(`DioAudioFetcher.guarded`). Each connection resolves the host once. If
any answer is on comms_core's blocklist, now exposed as
`isBlockedIpAddress` over raw address bytes, the connection is refused.
Otherwise it connects to the addresses it checked, so a DNS-rebinding
answer can't swap in another. A refusal shows as "Local and
private-network addresses can't be loaded". TLS is layered on afterwards
with `SecureSocket.secure(host:)`, so SNI and certificate checks still
name the host. A manual run outside the suite confirmed a real feed
loads and a wrong-host certificate is refused. Because the factory
replaces the platform's own connect logic, it also does what that logic
did for a hostname. It alternates address families and staggers attempts
250 ms apart, first answer winning. Without that, a host that lists IPv6
first on a network with no IPv6 route hung until timeout. The manual run
caught this before any test did.

**Auto Backup off.** `android:allowBackup="false"`. Left on, Android
copies the database to the user's cloud account, outside the household's
own encrypted `.ohbk` backup. A test reads the manifest. Fleet
conformance still passes.

### 5. FSRS by default: not flipped

`study_core`'s FSRS scheduler is complete and tested, but it can't be
the default yet. Unlocking and mastery (`nodeUnlocked`, `nodeProgress`,
the dashboard's mastered count) read only the classic half of a card's
state, and an FSRS grade writes only the FSRS half (`recordGradeFsrs`
merges `fsrs`-prefixed keys alone). It is worse for a card FSRS
created: that row has no classic keys at all, `decodeCardState` throws
on it, and `loadCardStates` skips it. To the unlock check, the card
looks unstarted forever. ADR-0009 states this as a scope
limit, and says in the same breath that an FSRS-studied course still
unlocks the same way. That can't hold, since FSRS grading never advances
the state unlock reads. As the default, a new profile would grade its
first node and never see the next one unlock. FSRS also has no
same-session relearning after "Again", and Daily review always uses
SM-2. The default stays `'classic'`, and FSRS stays labelled beta. What
would let it flip: unlock and mastery read the active scheduler's half,
or FSRS grades also advance the classic half.

### 6. Small UI fixes

The Inbox computes its filtered list once per build. The builder used to
rebuild it for every row it laid out, which made each frame O(n²) at 50k
items. Artwork thumbnails decode at their shown size times the device
pixel ratio (`cacheWidth`). A 3000 px show image decoded whole for a
48 dp row holds about 36 MB of image cache instead of about 100 kB. The
disk checks behind thumbnails moved out of `build`. The Subscriptions
and podcast pages check once per load, and `EpisodeActions` remembers
each row's artwork until its screen reloads, so scrolling and download
progress don't stat the disk. Both of those pages now build rows as they
scroll in, instead of building every tile, and running its disk check,
before the first frame.

## Consequences

- Schema v26: every migration fixture now strips what v26 added
  (`test/support/schema_strip.dart`) before stamping its old version.
- `IoHttpFetcher` refuses loopback by default. Tests that talk to their
  own loopback server pass an address policy that allows it.
- Dio downloads now go through the guarded client too, so a feed whose
  enclosure host resolves to the LAN fails to download, with the guard's
  own words as the job's reason.
