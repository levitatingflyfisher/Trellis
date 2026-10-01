# ADR-0018: Feeds are checked in the background, and opted-in shows download

- Status: Accepted
- Date: 2026-10-22

## Context

AntennaPod, the app Trellis replaces, refreshes feeds overnight, so what's
new is waiting when the listener opens it, often already downloaded.
Trellis refreshed only on pull-to-refresh. With about 300 feeds that took
minutes every time the app opened. `Feeds.autoDownload` had been stored
since schema v1, but nothing read it.

## Decision

### 1. A periodic check through WorkManager, with our own Worker

WorkManager runs one periodic task, "about every 4 hours". Its constraints
are battery not low and either an unmetered network ("Only on Wi-Fi", the
default) or any network. Charging isn't required: a phone that charges
only overnight would check once a day.

The app talks to `androidx.work` directly. There is no plugin.
`FeedCheckScheduler.kt` is a small MethodChannel (schedule, cancel, request
a pass, cancel a pass). `FeedCheckWorker.kt` starts a Flutter engine with
`FlutterEngine(context, null, false)`. That engine registers no plugins by
itself. It adds only the three the check reaches: `jni` and `jni_flutter`
(path_provider's Android side) and `sqlite3_flutter_libs`. Then it runs the
Dart entrypoint `feedCheckMain`. A first version used the `workmanager`
plugin, whose engine registers every plugin in the app. That would bring
audio_service into a headless engine, and audio_service's engine check is
what hung 1.4.0 at its launch logo. It also meant one more dependency
carrying its own manifest (FOREGROUND_SERVICE_SHORT_SERVICE). Dart decides
every constraint and policy (`periodicRequest`, `autoDownloadRequest`,
tested); Kotlin only hands them on. A host test reads the Worker's source
and fails if it registers plugins by itself or names an audio or
foreground-service plugin.

The check calls the same `refreshAll` a pull-to-refresh does, one reader at
a time. It never forces, so a feed in backoff (`nextAttemptMs`) waits its
turn, and the per-host caps and the dedup pass work as before. Each
finished `refreshAll` records `feeds_last_checked:<profile>`, and the
Subscriptions header shows it ("Last checked 2 h ago").

At launch the app registers the work with `keep`, so opening the app never
restarts the period. Changing "Only on Wi-Fi" re-registers it with
`update`. Turning "Check feeds in the background" off cancels the periodic
work and any auto-download pass still waiting for Wi-Fi. With it off, no
pass is ever requested. Both switches live on "On this device" (the
closest thing to a settings home today), stored in `DeviceSettings`,
because it is the device that checks.

### 2. One owner for every download, across two engines

The Worker's engine runs inside the app's process. The app's `JobCenter`
lives in memory in the app's engine, so a download the worker ran would be
invisible on the Jobs screen. A row the worker left at `running` would also
look killed, and the app would resume the same `.part` while the worker was
still writing it. The two engines coordinate through `IsolateNameServer`,
which is process-wide (`feed_check_handoff.dart`):

- **App open:** the worker finds the app's port, pings it and hands over
  the task, tagged with its own run id. The app runs it with its own
  connection and coordinator, so the downloads show on Jobs as they run.
  Both engines build their runner through one factory,
  `FeedCheckRunner.withCoordinator`, so a pass queues, marks its fetches
  auto and requeues on a stop the same way wherever it runs.
- **No app:** the worker runs the task on its own connection, with
  `DeviceServices.background`: the app's files, but no foreground service
  (Android 12+ refuses one started from the background, and it would post
  a notification).
- **App opens mid-check:** the app renders at once. Only what writes waits:
  the boot sweep, the resuming of jobs, and the player's rehydrate (it
  clears a stale last-played id). Before those, the app asks the
  worker to wind down. The worker pauses its downloads, gives its run 3 s
  to finish, closes its connection, and only then answers. Refreshes still
  in flight fail against the closed connection, and the next check picks
  them up.

Each side registers its own name before it looks for the other's. Whatever
order they start in, at least one sees the other.

When the system stops a worker (the time limit, or Wi-Fi gone during a
pass), it destroys the engine once Dart answers the Worker's `stop`. So
Dart answers only after the run has wound down, and the Worker gives it at
most 9 s. A worker that handed its task to the app forwards the stop with
its run id. The app stops that task alone: another worker's task carries
on, and so does a download the listener tapped. A name can still outlive
its engine if the process dies. Each side pings before it trusts a name it
finds, so a dead name costs a 2–3 s wait, not a stuck worker.

### 3. Two connections never write at once

ADR-0017's 5 s busy timeout doesn't cover two connections in one process.
Reproduced with two drift background connections on one file: one held a
write transaction for 1.5 s, and the other's single `INSERT` failed with
`SQLITE_BUSY` after about 70 ms. That happened on the host's SQLite
(3.50.2) and also on SQLite 3.52.0 built with `sqlite3_flutter_libs`' own
compile flags, which is what the APK bundles. The 5 s timeout made no
difference.

We considered sharing one drift connection between the engines
(`DriftNativeOptions.shareAcrossIsolates`). We rejected it: the server
isolate belongs to whichever engine opened first. When that is the
worker's engine, its destruction would take the app's database connection
with it.

So the overlap is made impossible instead. The worker opens a connection
only when no app answered. When an app appears, the worker closes its
connection before the app writes anything (section 2). Ingest still
retries its own transaction while busy (`lib/db/busy_retry.dart`), and
takes the lock with a no-op write first. That retry dates from the first
version. It stays as a guard for an unexpected overlap, and nothing else
retries. Two dedup passes interleaving would also be safe, because a pass
only ever hides the younger item of a pair
(`test/db/two_connections_test.dart`).

### 4. Auto-download

The podcast's settings page has a switch, "Download new episodes".
`Feeds.autoDownload` is the consent, and the only one. Turning it on goes
through the same `confirmDownload` dialog a tapped Download does, so
consent is given once, for "up to 3 each time feeds are checked, only on
Wi-Fi" (ADR-0003 law 6). A restore from backup turns it off on every show
and forgets the marks, because consent is per device, like the `consents`
table that never travels.

A check never downloads. If an opted-in show has something new, the check
asks WorkManager for a one-off pass with an **unmetered** constraint,
whatever the check itself was allowed to use. A pull-to-refresh asks the
same way.

A pass does three things, in this order:

1. **Queues each new pick.** The pick becomes a paused `download-<workId>`
   job row whose payload carries `auto` and `queued`. It shows on Jobs at
   once.
2. **Moves each show's mark.** Work ids only grow, so the mark is the
   show's newest row. Turning the switch on sets the mark to now, so the
   back catalogue is never fetched.
3. **Fetches every queued row**, one at a time, through
   `EpisodeDownloadCoordinator`. Each one resumes from its partial and
   falls under the show's `keepLatestAudio` eviction.

Because the rows exist before the marks move, a pass killed partway loses
no pick and picks none twice. When the pass is stopped, the download it
interrupted goes back in the queue. The pass then returns false, and
WorkManager runs it again later, still only on Wi-Fi.

A pick is the newest `min(3, keepLatestAudio)` rows above the mark. It
skips text items, played rows, rows already on disk, rows hidden as
duplicates, and rows that keep-latest evicted (fetching those again would
fight the eviction).

Auto rows never resume over a network nobody checked:

- A lost connection during an auto download sends the row back to the
  queue (paused) instead of leaving it `running`.
- A row that a process death left `running` is paused and queued at the
  next restore. The app then asks for a pass, which waits for Wi-Fi.
- A pause by the listener's own hand clears `queued`, so that download
  stays paused until they resume it.

### 5. The laws

- No notification for new episodes (ADR-0003 law 5). The check and the
  pass run without a foreground service, and no notifying plugin attaches
  to the worker's engine.
- Nothing fills Up Next, and the Inbox stays reverse-chronological. The
  check only ingests, the same as a pull-to-refresh.
- **RECEIVE_BOOT_COMPLETED stays stripped.** WorkManager declares it so it
  can reschedule after a reboot. With it removed, the work comes back the
  next time the app opens (`applyAtLaunch`). After a reboot, no checks run
  until the listener opens Trellis once. We accept that rather than widen
  the permission list.
- The rest of WorkManager's manifest (WAKE_LOCK, ACCESS_NETWORK_STATE,
  FOREGROUND_SERVICE) was already on the merged list. ACCESS_NETWORK_STATE
  is now actually used, for the network constraints.

### 6. Web

A browser runs nothing after its tab closes. On the web build the
scheduler is never available (the bootstrap trio pattern), so no channel is
called. The switches are hidden, and so is the per-show auto-download
switch. "Last checked" still shows there, from pull-to-refresh.

## Consequences

- Auto-downloaded episodes skip the offline DSP pass, which is still
  chained to the Download tap (see jobs-audit's "Still open").
- A cold start that interrupts a background check runs the boot sweep a
  few seconds after the first frame, not before it. The Library tab opens
  first, and the River reads its own state when it is opened.
- With background checks off, auto-download does nothing. A pass needs
  WorkManager to wait for Wi-Fi, and the app has no other way to know the
  network is unmetered.
- Device proof is still open: the worker firing on a phone, and the two
  engines finding each other there. The host suite covers scheduling,
  hand-over, selection, the job rows and two connections.
