# ADR-0016: Episodes you can tell apart, and a home for each subscription

- Status: Accepted
- Date: 2026-10-21

## Context

Measured against AntennaPod, the app the user is replacing, the Inbox reads as
"an endless stream of blah". Every row carries the same four things (title,
show, date, play), so nothing separates the episode you finished from the one
you are halfway through or the one you have never touched. The feed page is
worse: titles and dates only, no way to play, on purpose (ADR-0003 law 1 kept
"the one ordering" in the river).

The user's real sessions, in their words:

1. Check what is new across everything and add things to the queue.
2. Go back into one podcast and binge it.
3. Clean up what they didn't listen to.
4. Find the episode they heard a month ago, to share it.

They rarely touch granular per-feed controls. They don't use tags, but would
group by **where the content came from** once books, blogs and podcasts mix,
even though every item can be read or heard either way.

## Decision

### 1. A row that says what state the episode is in

Every episode row (Inbox, podcast page, history, search) shows:

- **Played** rows fade (reduced opacity, still legible at large text) so the
  unplayed ones stand out without a badge.
- **In progress**: a thin progress bar and time left ("23 min left").
- **Length** on every row that knows it (`Episodes.durationMs`, or the
  player's measured duration once played).
- Small, labelled markers, never colour alone: new, downloaded, in Up Next,
  transcribed, video.
- Per-episode artwork when the feed provides it, falling back to the show's.

"Played" needs a real fact, not a guess from position: add
`Episodes.finishedAtMs`, set when playback reaches the end (or the last
~30 s) or when the user marks it played, cleared by "mark unplayed".

### 2. The podcast page is a place you can listen from

The feed detail screen becomes the podcast page:

- Plays, downloads and queues from its rows.
- Sort newest-first (default) or oldest-first, remembered per feed.
- "Play from here" and "Add unplayed to Up Next".
- Downloads, auto-download and the existing archive action live here; the
  granular settings (speed, keep N, rules) sit behind one "Podcast settings"
  button.

This does not break ADR-0003 law 1. The law forbids *ranking*; the Inbox
stays reverse-chronological, and a podcast page sorted by date (either way,
by the user's choice) is still chronological. Up Next only ever holds what the
user put there. Playback may continue to the next item *in Up Next*; it never
fills Up Next itself, so this is not autoplay (VISION's scope test).

### 3. Subscriptions, shelved by origin

A Subscriptions page lists every followed source, grouped automatically into
shelves by origin (Podcasts, Blogs and newsletters, Books, Video), no manual
tags. Each row shows artwork, the unplayed count and the failure reason
(red) when one exists. Origin is a property of the source, recorded at intake;
it never limits how an item is consumed.

### 4. History and search

A listening/reading history (most recent first) and one search box over
episode titles, show names and, where they exist, transcripts. Transcript
search is the thing AntennaPod cannot do.

### 5. Clean-up

Multi-select on any episode list (mark played, let pass, remove download),
plus "Mark everything older than this as played". Nothing nags about what was
left unplayed.

## Order of work

1. The row (section 1) and the podcast page (section 2).
2. Subscriptions with shelves.
3. History and search.
4. Clean-up.

Each step ships on its own and is tested; the hidden-screen fixes (a full Now
Playing screen, one settings home, an always-visible Follow) are a separate
piece of work.

## Consequences

- One schema change (`finishedAtMs`), plus a per-feed sort preference.
- The feed detail screen's "not a second river" note is retired; its
  RFC 5005 "Fetch older episodes" action stays.
- AntennaPod (GPL) was studied for what its rows show, never for code.
