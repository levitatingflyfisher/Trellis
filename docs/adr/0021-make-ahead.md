# ADR-0021: Make ahead, for shows the person picks

- Status: Accepted
- Date: 2026-11-10

## Context

The one tap (1.6.0) makes an episode in the learning language, which is
many minutes of the phone's whole effort. The owner, 10 November 2026:
"Yes, for shows I pick". New episodes of chosen shows are translated and
voiced ahead, so the row's second button plays at once. Every other show
still works on tap.

## Decision

### The rulings

- A show's page has one plain switch, "Make new episodes in <learning
  language> ahead". Off by default. With no learning language chosen, the
  first switch-on asks which. The switch is absent where the show cannot
  be made in that language.
- Only new episodes: those that arrive after the switch is on, newest
  first, at most 3 per show waiting or made and not yet played. A slot
  that opens takes the newest not yet picked; older ones are passed over,
  so it never drifts into the back catalogue.
- Storage limit: 2 GB by default, one setting (1, 2, 5 or 10 GB). When
  over it, the oldest made-ahead audio goes first, a played one before an
  unplayed one. Never audio made by a tap, anything marked Keep, what is
  in the Queue, playing or half heard. Removing audio leaves the
  translation, so a tap makes it again quickly.
- Wi-Fi and charging, both, checked before each episode starts and every
  30 seconds while one runs. Wi-Fi means an unmetered network, as
  everywhere else in the app. A person's own tap is never held back.
- It fetches a model only if it is already here or the person agreed on
  the switch-on consent sheet, for that language. A no leaves the switch
  off.
- It never plays anything by itself and never notifies, beyond the live
  job progress every job has (ADR-0003 law 5).
- A tap goes first: the made-ahead job stops at its next safe point and
  picks up after.
- Stop on a row is final for that episode.

### What runs, and what Android will not let it promise

Making an episode takes longer than a background worker may run, and
needs the voice and audio plugins the worker's engine deliberately does
not load (ADR-0018). A long job needs the foreground service, and since
Android 12 an app cannot start one from the background without a listed
exemption. WorkManager's own foreground route obeys the same rule. Nothing
here is faked around that.

So the work runs in the app, under the existing foreground service, only
when Android allows that service to start:

- The app is on screen. At launch and each time it comes back to the
  front, a pass looks for work.
- The service is already up, for any job. The next made-ahead episode
  joins it, and each is started before the last lets go, so a dark screen
  does not end a run in progress.
- The person has turned off battery optimisation for Trellis, which is
  Android's own exemption. Trellis does not ask for this.

The background route is the existing one: the feed check (ADR-0018)
brings new rows in, and those rows above a show's mark are what is due.
No separate marking is needed. It then asks WorkManager for one pass on
Wi-Fi while charging. If the app is alive, the worker hands the pass over.
If there is no app process, the pass does nothing: the episodes wait for
the next time the app is open.

**What this does not guarantee.** A phone left charging all night with
Trellis closed makes nothing. Open the app on Wi-Fi while it charges and
the run starts and keeps going behind a dark screen. Android 15 and later
also allow data-sync foreground services 6 hours in 24; past that a new
start is refused until the person opens the app, and a job under way
loses its protection and may be stopped. Any of these stops only delays:
the record keeps what is waiting.

### Resume

Each stage keeps its result, so the chain restarts at the first missing
one. Stopping in the speaking stage loses the audio rendered so far and
keeps the translation.

Made-ahead work is deliberately not on `listen_line`, the record a launch
restarts: that line runs at launch whatever the network and battery are
doing, as a tap's job must. Its record is its own (`make_ahead`), read at
each pass, so a kill costs nothing and the conditions still hold.

### Storage of the record

One device setting, `make_ahead`, holds the shows and the picks as one
JSON value, so a pick and its show's mark change together. Like the
auto-download marks, it belongs to the device and a restore forgets it.

## Consequences

- No new permission: charging is read from the sticky battery state, and
  WorkManager's network constraint was already declared (ADR-0003 law 7).
- A person may wait until the next time the app is open for an episode
  that has arrived. That is the honest price of not running hidden work
  the system forbids.
- Device proof is still open: the consent sheet, the service holding
  through a run, and the two conditions on a phone.

Sources:
[Restrictions on starting a foreground service from the background](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start),
[Foreground service timeouts](https://developer.android.com/develop/background-work/services/fgs/timeout),
[Foreground service types](https://developer.android.com/develop/background-work/services/fgs/service-types).
