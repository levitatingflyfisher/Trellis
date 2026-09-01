# Personas

Agents drive the real Trellis build as these people, per the fleet testing
rule. Each scenario gives a start state, plain steps, what success looks like,
and what to check. "Standard checks" means: text scale 1.3 at 360 dp width,
dark mode, airplane mode, and every error in plain words with a way forward.
Scenarios aim at the weak spots found by the September 2026 lens audit.

## Primary: Aiyana, learning Spanish between shifts

Aiyana is 35, a nurse married to a Spanish speaker, and wants to follow the
in-laws' conversations. They read articles and listen to podcasts on the bus,
then study for ten minutes before bed. No Brain key is configured.

- **Goal:** read and listen daily, pick up where they left off, and turn
  what they read into study.
- **Context:** one-handed on a moving bus; patchy data; text scale 1.3 at
  night.
- **Would quit if:** the reader forgets their settings, or saved items vanish
  without warning.

**A1. Reader remembers.** Start: one article in the Library, reader in Words
mode. Steps: switch to Scroll at 450 wpm; read a little; leave; reopen the
same work. Success: it opens in Scroll at 450 at the same place. Check: the
current mode is shown as a word, not only an icon.

**A2. Library progress.** Start: a work half read. Steps: look at its Library
row. Success: the row states progress in words or numbers ("12 of 31
passages"); the date says whether it was published or added. Check: a screen
reader announces the progress; standard checks.

**A3. A refused web address.** Start: Library, Add sheet. Steps: choose From
the web; enter an address the site refuses. Success: one plain sentence and a
"Paste the text instead" way forward; the long briefing is not read before
any failure. Check: offline behaves the same.

**A4. Passage to card without a key.** Start: no Brain configured, reading an
article. Steps: try to turn a sentence into something to study. Success: a
no-key path exists, or record its absence as a finding. Check: Daily Review
lists what came in.

**A5. The course map.** Start: a Spanish course with some mastery. Steps:
open the course map; tap a locked bud; compare sibling nodes. Success:
mastery shows as a number, not colour alone; the lock names its key; sibling
titles are distinguishable. Check: view in grayscale; the Inbox shows days
left on every item.

## Secondary: Dmitri, a parent setting up profiles and backup

Dmitri is 49, the household's tech person, sets Trellis up for themselves
and two children on a shared tablet.

- **Goal:** create reader profiles and a backup that will actually restore.
- **Context:** shared tablet, patient, reads everything.
- **Would quit if:** the backup could silently be unopenable.

**D1. First launch.** Start: fresh install. Steps: tap "Start reading" with
an empty name; then enter a name; close and reopen the app. Success: the empty
tap is disabled or explained; a one-reader household is not made to pick a
profile every launch. Check: dark mode.

**D2. Backup phrase.** Start: some works and a course. Steps: open Backup &
migrate; create a backup. Success: the app issues the twelve words rather
than assuming them, checks them word by word, and verifies the file after
writing. Check: the restore dialog emphasises "Keep what I have", not the
destructive button.

**D3. Remove and restore.** Start: three works. Steps: remove one from the
Library. Success: Undo is offered, as the Inbox's Keep already does. Check:
undo after delete.
