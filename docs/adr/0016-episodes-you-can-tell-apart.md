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

## Notes from building step 2

- Origin is learned from each fresh parse: audio on any item makes a
  podcast, none makes a blog. An empty listing leaves it unchanged, and a
  feed with nothing stored yet (an OPML import never reached) stays on
  Podcasts until it answers.
- The Books shelf holds `kind == 'book'` works the Library shows (EPUB and
  Gutenberg). Audiobooks stay in the Library for now; whether they belong
  on this shelf is open.
- There is no Video shelf: the parser keeps only audio enclosures, and
  video support is undecided.
- Blog rows show no count. "Unplayed" means audio not yet finished, and
  articles have none; an unread count for them would be a separate ruling.

## Notes from building step 3

- History means actually listened to or read (coordinator ruling): a
  listening place past the start, a reading place past the first word,
  or a finish by ear (the work's finished day, which only playback
  reaching the end stamps). "Mark played" alone does not count, so
  step 4's bulk clean-up won't flood history, and neither does "seen"
  (`readAtMs`), which opening a row and Let it pass both set. No new
  column: those timestamps already exist.
- Search results and history are ordered by time (publish date, or the
  history timestamp), never by a relevance score. A ranked list is what
  ADR-0003 law 1 keeps out, and the item the user is after is found by
  when they heard it.
- The index is two FTS5 tables kept in step by triggers: one row per
  work with its title and its show's name side by side, so every word
  of "serial episode 5" may land in either; and transcript sentences. Only sentences with an alignment
  are indexed, so a book's or article's body is not searched; the brief
  asked for transcripts, and indexing whole books would double their
  storage. FTS5 is in the bundled native SQLite and in the shipped
  `sqlite3.wasm`; a build without it opens normally and searches with
  LIKE.
- A transcript hit with audio plays from its sentence through the
  player's existing projection (`listenFrom`). Without audio, the reader
  opens on the sentence and leaves the saved place alone until the cursor
  moves; after that the hit is spent, and a reload goes to the saved
  place. Audiobooks are never transcribed today, so they have no
  transcript hits to seek; when they are, a hit should seek through the
  file-aware `playAudiobookAt`.
- Share hands the title, show and enclosure link to the platform sheet on
  Android. On the web tier, or when the sheet fails, it copies the same
  text and says so.
- Search is a worded field at the top of the Inbox and Subscriptions
  lists, not a bar action. At 360 dp and 1.3x text a Search word on the
  Inbox bar folded the theme toggle's visible "Auto" into its tooltip,
  and the bar ruling forbids trading one visible label for another.
  History sits in the Inbox's More menu and is search's empty state.
