# Long-running jobs: an audit

Why this exists: people reported that "interrupted jobs restart from
scratch", that loading states were unclear, and that "things don't load".
This note lists every long job in the app, where its state is stored, what
happens if the app is killed partway, and what the user sees. Section one
describes the app as found. Section two covers what changed and what is
still open.

## As found

| Job | Engine | State lives in | Killed mid-job | User sees while running | User sees after failure |
|---|---|---|---|---|---|
| **Episode download** (`EpisodeDownloadCoordinator`) | domovoi `resumableDownload` via `AudioFetcher` | Memory only. The `.part` file beside `audio/<workId>.<ext>` is the only trace on disk. | The bytes survive: tapping Download again sends an HTTP Range request and continues. But nothing records that a download was ever under way, so after a relaunch the row just offers "Download" again. Nothing resumes by itself, and nothing says a partial exists. | **Nothing.** `stateOf()` is tracked but never shown. The menu closes and the row looks unchanged until the file lands. | **Nothing.** The error goes into `stateOf().error` and is never shown. |
| **Transcription** (`TranscribeCoordinator`) | Model, then audio (same engine), then decode (atomic `.part` rename), then a jobs_core `JobRunner` over whisper windows | `jobs` table: `transcribe-<id>` and `translate-<id>` rows, each with a checkpoint written after every window. | Resumes from the last committed window, as the jobs_core law promises. But the orphaned `running` row comes back as a **Paused** card, and nothing moves until the user taps Resume. | A card above the Latest list. The model stage shows bytes and an ETA, the window stage shows parts done and an ETA. The *episode audio* stage is an indeterminate bar ("Getting the episode audio…"). | "Didn't finish. Your progress is saved." The actual reason (`card.error`) is never shown, so someone who is offline and someone whose disk is full both get the same line. |
| **Model download** (Models screen) | domovoi `resumableDownload`, sha-pinned | The `.part` files. The screen measures them on open. | Resumes by Range when the user taps Resume. The screen honestly says "Paused: X of Y". | Bytes and an ETA on the Models screen. | An error line on the Models screen. |
| **DSP preprocess** (`DspCoordinator`) | One ffmpeg pass, promoted by atomic rename | `jobs` table, kind `dsp` | **Restarts from scratch** (a single pass has no sub-unit checkpoint). That's safe, because nothing is promoted early. | **Nothing.** Its cards are restored but never rendered anywhere. It runs silently after a Download. | **Nothing**, for the same reason. |
| **Sentence translation** (`TranslationJobController`) | Marian or Brain, one sentence (or one batch) at a time | `translation_sentences`. Every stored sentence is the checkpoint. | Re-running continues where it stopped. Nothing re-runs by itself. | Progress inside the reader that started it. | Failed sentences are skipped, and only those sentences fall back. |
| **Speech synthesis** (Supertonic pipeline) | Sentence-ahead synthesis | Memory only, by design | Lost, harmlessly. It's a playback buffer, not a job. | The speak loop | Falls back to the system voice |

Two more problems sit underneath the table:

- **Two owners for one `.part`.** The standalone Download and the
  transcription's audio stage both write `audio/<workId>.<ext>.part`, and
  neither knows about the other.
- **The foreground gate is not counted.** `AndroidJobForegroundGate` keeps a
  single `_running` flag, so the first job to finish stops the
  screen-off service while another job is still running. Episode downloads
  never asked for the gate at all.
- **Coordinators belong to a profile.** They live in `HomeShell`, so a
  profile switch builds new ones while the old flow is still running.
  This becomes dangerous as soon as anything resumes on its own.

The file names are stable. `audioFileFor` keys the file on `workId` plus
the extension, not on the URL, so a feed refresh that rotates tracking
tokens does not move the `.part`.

## What changed

- **One record per job.** Downloads now get a row in the `jobs` table
  (kind `download`), next to `transcribe` and `dsp`. The table gained a
  `failure_reason` column (schema v22) that holds one plain sentence,
  for example "Couldn’t reach the server…" or "This phone is out of
  space…". Any save that is not a failure clears it.
- **Resume on launch.** `JobCenter` is created once per app run, above
  the reader's shell. It rebuilds every job from its row, then continues
  the jobs a kill interrupted (rows left at `running`). Downloads pick up
  by HTTP Range from their `.part`. Transcriptions continue from their
  last committed window, one at a time, and the others say "Picking up
  where it stopped". Paused jobs stay paused. Failed jobs keep their
  reason and wait for Try again. A lost connection doesn't count as a
  failure for this purpose. The card says "Couldn’t reach the server",
  but the row stays resumable, so a phone that was offline when the app
  opened carries on at the next launch without a tap.
- **No new egress at launch (ADR-0003 law 6).** Resume only continues a
  transfer that the person already approved through the consent dialog.
  Nothing starts a download on its own, except auto-download (ADR-0018).
  Those downloads are approved once, through the same dialog, when the
  listener turns on a show's "Download new episodes". They run only in a
  pass the system starts on an unmetered network, through the same
  coordinator, so they get job rows and show here. Each pick is a paused
  row before anything is fetched. An auto download that loses its
  connection, or that a kill left `running`, is paused and handed back to
  the next pass. A launch never resumes it, because the launch may be on
  mobile data.
- **One owner per `.part`.** The transcription's audio stage asks the
  download coordinator instead of fetching on its own, so the bytes it
  shows are the real bytes, and a download and a transcription of the
  same episode share one fetch.
- **Visible.** The Jobs screen lists every transcription, download and
  DSP job. Each one shows its progress or its reason, with Pause, Resume
  or Try again, and Discard. A strip above the player bar ("1 job
  working · See jobs") appears on every tab whenever a job exists, and
  the Latest menu has a Jobs item. Each episode row shows its own download
  line while one exists.
- **Progress is throttled.** Download progress rebuilds once per whole
  percent, not once per network chunk.
- **The screen-off service is counted.** `SharedJobForegroundGate` keeps
  the service up until the last job ends, and downloads now ask for it
  too.

## Still open

- **DSP** still restarts from scratch after a kill (one ffmpeg pass has
  no checkpoint). A download that resumes by itself after a relaunch
  skips the DSP step, because that step is chained to Latest's
  Download tap. DSP jobs are not auto-resumed. A paused one waits in the
  Jobs screen.
- **Model downloads** started from the Models screen keep that screen's
  own state. They resume by Range on Resume, and the screen honestly
  shows "Paused: X of Y", but they are not listed in the Jobs screen.
  A model download inside a transcription is listed, on that job's card.
- **Translation and synthesis** are unchanged. Translation is
  checkpointed by its stored sentences. Synthesis is a playback buffer,
  not a job.
- **Device proof.** The resume path is tested on the host with fakes.
  Whether Android lets the foreground service restart at launch is still
  unverified on a phone.
