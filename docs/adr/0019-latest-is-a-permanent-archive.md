# ADR-0019: Nothing decays; Latest is a permanent archive

- Status: Accepted
- Date: 2026-10-23
- Supersedes: [ADR-0003](0003-attention-sovereignty-laws.md) law 2 ("Ephemera
  decay by default; works persist")

## Context

ADR-0003 law 2 made feed items ephemera: a boot sweep hid any unkept item
30 days after the app first saw it, and the Inbox showed a fading leaf and
"Leaves the Inbox in N days" on every row. A hidden item could be restored
from a notice for another 30 days. After that, or at once if the listener
tapped "Let go", it was deleted for good. Items in Up Next or with captures
were spared while they stayed there.

The owner ruled that this is wrong for what the screen actually is. The
cross-feed timeline is an archive: one list, newest first, across every
show and publication followed. Dropping items from it is unacceptable, and
a countdown on every row is a small nag in an app whose laws forbid nags.
What the owner wants from the screen is that one timeline, and a way to
see what is new since the last look.

Two facts made this more than deleting a sweep:

- **Decay was the only bound on the list.** The river query had no LIMIT.
  It loaded every row to paint the first screen, and again after every tap
  on a row. An OPML import of about 300 shows stored about 20k episodes,
  all stamped with the same first-seen day.
- **That first-seen stamp is meaningless as an order**, and law 1 has to
  stay true without it.

## Decision

### 1. Nothing decays

The boot sweep, its pure verdict (`loom_core.sweepEphemera`), the
`decayed` state, the leaf, the countdown lines and the Restore / Let go
notice are gone. Nothing outside the feed used the sweep, so it was deleted
outright rather than kept for some other caller. Keep (into the Library)
and Let it pass (mark read) change an item's state; they never remove it
from Latest.

An item's row is deleted by exactly these acts, each the listener's own:

- **Unfollowing its feed** deletes the feed's unkept items. A kept one stays
  in the Library and loses only its feed row (`deleteFeedCascade`).
- **Removing the reader** deletes everything that reader had
  (`deleteProfileCascade`), and **restoring a backup** replaces the whole
  database with the backup's.
- **A feed rule `skip`** never stores what it matches (see §6).

Removing a feed item from the Library is not one of them. It demotes the
item: it is unkept, leaves the Library, and stays in Latest and on its show's
page with its transcript, captures and position (`removeFromLibrary`). Only a
work with no feed row (a book, an article, a note, an audiobook) is deleted
by Remove. The schema v26 fold of twin (feed, guid) rows, which only a race
could have made, removes the younger copy of a duplicate, not an item.

Schema v27 turns every `decayed` row back into an ordinary unkept item, and
restoring a backup made before this change does the same. Rows the old sweep
had already deleted (its second window, or Let go) cannot be brought back
from the database. A feed that still lists them adds them again on its next
refresh, because their guids left the seen-set with them.

The promotion bit itself stays. `ephemeron` now means only "not in the
Library", and nothing ever ages out.

The law is a test, as ADR-0003 asks: an item first seen 1,000 days ago is
still listed in Latest after a full boot (`test/features/archive_law_test.dart`).

### 2. Order stays law 1: publish time, newest first

Law 1 keys on `episodes.published_at_ms` descending, with the work id
settling a tie. That is the feed's own date. Ingest stamps first-seen only
when an item carries no date at all, so the OPML import's single first-seen
day never decides the order. Nothing about ordering changed. A test now pins
it against first-seen order (`test/db/latest_paging_test.dart`).

### 3. Latest is paged by keyset

The list reads 60 rows at a time below the last loaded row's
`(published_at_ms, work_id)` key, and asks for the next page when the list's
last slot comes within its cache extent. A keyset is used rather than an
offset, so items arriving at the top never shift a page.

- A new index on `episodes(published_at_ms)` lets SQLite walk the archive
  newest first and stop at the LIMIT. `work_id` is the rowid, so the index
  already ends in the tie-breaker. Without statistics the planner preferred
  to drive from the works index and sort every row of the profile, so the
  query writes `+works.profile_id` to keep it off that index. A test asserts
  the plan never builds a temp B-tree for the order, on 20k rows and on a
  later page.
- An action on one row re-reads that row in place. A bulk change, or a
  return from another screen, re-reads the rows down to the last loaded one
  and no further. Pull-to-refresh starts again from the first page.
- The text/audio chips filter inside the query, so a filtered page is still
  full. They filter; they never sort.
- "Mark everything older as played" asks the database for every older
  unplayed episode, because the loaded page no longer holds all of them.

### 4. "New since you last looked"

Each profile records when its last visit began (`profiles.latest_seen_at_ms`).
At the start of a visit the screen swaps in the current time and keeps the
previous value for the whole visit. One quiet line, "New since you last
looked", sits between rows published after that moment and rows published
before it.

- **A visit is an app session, not a trip to the tab.** The shell keeps
  Latest mounted under the other tabs, so Latest → Queue → Latest comes
  back to the same loaded pages, scroll position and line; coming back
  re-reads the loaded rows in place. The swap happens on a cold start (the
  screen's mount) and when the app returns from the background (it was
  hidden or paused), never on a tab switch or a passing interruption such
  as the notification shade or a system dialog. A first version swapped on every mount, and the shell rebuilt
  the screen on every tab visit, so a glance at the Queue reset Latest to
  its first page and wiped the line.
- **At the start, not on leave.** The line holds still while the listener
  reads, and an app kill mid-visit loses nothing (`dispose` is not
  guaranteed to run, and neither is a pause callback).
- **Keyed on publish time**, which falls back to first-seen when a feed
  gives no date, so the new rows form one block at the top and law 1 stays
  trivial. An item a refresh finds today with a publish date before the last
  visit lands below the line, in its date order. That is the cost of
  never reordering.
- **No count, no badge, no colour that asks for action**, in the spirit of
  law 5. A first visit, or a visit with nothing new, draws no line.
- **Its own column.** It is not a field in `readerPrefsJson`, because the
  reader rewrites that blob while Latest is a tab away.

### 5. The word is Latest

Per the owner's naming law (industry words, not coinages), the tab and
screen are **Latest**. "Inbox" promised a place that things leave once they
are dealt with, which this no longer is.

### 6. Nothing is lost, which is not the same as every copy shown twice

The archive law means no item is ever dropped. It does not require every
copy of a story to show in Latest. Two existing behaviours stay:

- **Cross-feed dedup collapses a duplicate into its twin.** When two
  followed shows carry the same story (`feed_dedup.dart`), `setDedup`
  stamps the later row with a `dedupReason` and its twin's id. The story
  shows once in Latest. The duplicate row is kept, never deleted, and its
  own show's page still lists it (`episodesOfFeed` does not filter on
  `dedupReason`; pinned in `test/db/feeds_db_test.dart`).
- **A feed rule `skip` does not ingest.** The rule is the listener's own
  explicit instruction for that feed (`feed_ingest.dart`), like unfollowing,
  so not storing what it matches is the listener's act, not the app's.

## Consequences

- The database grows with every followed feed and never shrinks on its own.
  At podcast-metadata sizes that is megabytes, not gigabytes. Downloaded
  audio is still evicted by each feed's own keep-latest policy, which only
  ever touches files.
- Paging is not an endless feed in VISION's sense. It ends at the oldest
  item the listener's own subscriptions produced, nothing is injected, and
  nothing is ranked.
- With two profiles of very different sizes, a page for the small one walks
  past the big one's rows in the index. That is still bounded by the
  archive, and it never sorts.
- ADR-0003's other six laws stand. Its law 2 now carries a pointer here.
