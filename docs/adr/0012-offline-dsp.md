# ADR-0012: Offline DSP — and the GPL fix it surfaced

- Status: Accepted, all five parts shipped on `campaign/dsp` (the GPL
  fix, the local-playback foundation, schema v16, the preprocess
  pipeline, settings/counter/wiring) — proven through the interface
  with faked ffmpeg/fetch/decode boundaries, not yet exercised on a
  real Android device or a real ffmpeg binary; see each part's own
  Verification subsection for exactly what ran and what remains
  unexercised.
- Date: 2026-08-15

## Context

Campaign 6's brief was Overcast-style trim-silence/loudness-normalize for
podcast episodes, done as an OFFLINE PREPROCESS on downloaded audio (never
real-time DSP on the stream) — the app already ships ffmpeg for
transcription decode, and podcast episodes are downloaded files, so the
same substrate can encode as well as decode.

Two things Phase 0 was supposed to verify turned out to both be true, but
one of them was a bigger finding than the question that was asked.

## Part 1 — the GPL fix

### What Phase 0 actually found

The pinned dependency, `ffmpeg_kit_flutter_new: ^4.1.0`
(`app/lib/features/transcribe/ffmpeg_decoder.dart`), is the **Full-GPL**
variant of the `sk3llo/ffmpeg_kit_flutter` community fork (the
PunctumTemporis precedent ADR-0001 cites). Verified empirically, not
read off the README: the actual native binary Gradle pulls
(`com.antonkarpenko:ffmpeg-kit-full-gpl:2.1.0`, from
`android/build.gradle` inside the pub package) was downloaded from Maven
Central and its `libavcodec.so` build-config string extracted with
`strings`. It carries `--enable-gpl`, `--enable-libx264`,
`--enable-libx265`, `--enable-libxvid`, and `--enable-libvidstab` —
a GPL-3.0-linked binary, full stop, regardless of the fact that this app
uses none of libx264/libx265/libxvid's video-encoding capability.

This directly contradicts ADR-0007's "the APK is MIT-clean end to end"
claim. That ADR verified the TTS engine's own licensing meticulously
(dropping sherpa-onnx specifically because it bundled GPL-3.0 espeak-ng)
and was correct about everything it checked — it simply never checked
ffmpeg_kit_flutter_new's own licensing, because ffmpeg wasn't that
campaign's surface. The inconsistency is exactly the kind the TTS
campaign existed to remove, just left standing in a different dependency.
The 1.1.0-era APK, if built with this dependency, ships a GPL-3.0 binary
inside a fleet whose convention is MIT.

### The fix: swap variants, not forks

The same publisher (`com.antonkarpenko`) ships an **audio** variant of
the identical Flutter wrapper: `ffmpeg_kit_flutter_new_audio` (pub.dev),
native artifact `com.antonkarpenko:ffmpeg-kit-audio:2.2.2`. Verified
before swapping, not assumed:

- **Same Dart API, byte for byte.** `diff <(ls .../ffmpeg_kit_flutter_new-4.1.0/lib/) <(ls .../ffmpeg_kit_flutter_new_audio-2.5.2/lib/)`
  is empty — `FFmpegKit`, `FFprobeKit`, `MediaInformation`, everything
  `ffmpeg_decoder.dart` and this campaign's DSP encoder need, present
  identically. Same Android `package`/`pluginClass`
  (`com.antonkarpenko.ffmpegkit`/`FFmpegKitFlutterPlugin`), same AGP
  (8.12.3), Kotlin (1.8.22), compileSdk (35), minSdk (24) in both
  packages' `android/build.gradle`. The swap is two lines: the pubspec
  dependency and the two `package:ffmpeg_kit_flutter_new/...` imports in
  `ffmpeg_decoder.dart` becoming `package:ffmpeg_kit_flutter_new_audio/...`.
- **Genuinely LGPL-only, verified the same way as the finding.**
  `libavcodec.so`'s build-config string for the audio variant carries
  `--enable-version3` (LGPL v3) and NO `--enable-gpl`. The full codec
  list enabled: `libilbc, libmp3lame, libopencore-amrnb, libopus,
  libshine, libsoxr, libspeex, libtwolame, libvo-amrwbenc, libvorbis` —
  every codec this app's audio-only pipeline needs (mp3 via lame, opus,
  vorbis), zero video codecs, zero GPL libraries. `silenceremove` and
  `loudnorm` are core `libavfilter` in every variant of ffmpeg, not
  gated behind any external library — this campaign's DSP filters lose
  nothing in the swap.
- **`FFprobeKit`/`MediaInformation` present**, needed for original/
  processed duration measurement (the time-saved counter) — see Part 3.
- **16KB page alignment holds, same as the variant it replaces.**
  Android 15+ requires ELF `LOAD` segments 16KB-aligned. Both AARs'
  `libavcodec.so` (arm64-v8a) were extracted and checked with
  `readelf -Wl`: every `LOAD` segment in both the outgoing full-gpl
  binary and the incoming audio binary reports alignment `0x4000`
  (16384 = 16KB). Parity confirmed, not assumed.

### What changed, honestly

- **Before:** MIT app code, but the native ffmpeg binary was GPL-3.0
  (x264/x265/xvidcore/vid.stab statically linked into `libavcodec.so`),
  contradicting ADR-0007's MIT-clean claim.
- **After:** MIT app code + LGPL-3.0 natives, shipped as the same kind
  of dynamically-loaded `.so` files LGPL's dynamic-linking exception is
  written for — no GPL library anywhere in the dependency tree. The
  fleet's MIT convention holds for the whole APK again.

### Size — a decrease, not a budget risk

The full-gpl variant's arm64-v8a native payload (`libavcodec.so` +
`libavdevice.so` + `libavfilter.so` + `libavformat.so` + `libavutil.so`
+ `libswresample.so` + `libswscale.so` + `libffmpegkit*.so`) totals
~41.8MB uncompressed; the audio variant's equivalent totals ~19.7MB —
video codecs (`libx264`/`libx265`/`libxvid`/`libvpx`/`libdav1d`/
`libaom`/`libopenh264`/`libvidstab`), font/text rendering
(`libass`/`libfreetype`/`libfribidi`/`libfontconfig`/`libharfbuzz`),
OCR (`libtesseract`), and several other libraries this audio-only app
never called account for the difference. **~22MB smaller** per-arm64-ABI
before compression, a real reduction the release's C3 storage/size
budget should record as a decrease, not a risk — this app never used the
video path the removed libraries existed for.

### Verification

`flutter pub get` (clean swap, `ffmpeg_kit_flutter_new 4.6.2` dropped,
`ffmpeg_kit_flutter_new_audio 2.5.2` added), `flutter analyze` (0 issues,
whole app), and the full test suite (635 passed, 1 pre-existing skip
unrelated to this change, 0 failed) all green after the swap — including
`test/transcribe/decoder_test.dart`, `transcript_writer_test.dart`,
`transcribe_executor_test.dart`, `file_pcm_source_test.dart` (25 tests),
none of which changed, since the swap only ever touches an import path
and a pubspec version, never `FfmpegDecoder`'s own logic. `FfmpegDecoder`
itself is never exercised by a real ffmpeg binary in this test suite on
this host (host tests run `WavPassthroughDecoder`;
`ffmpeg_decoder.dart`'s own doc comment says as much) — the swap's
correctness rests on the Dart-API-identity and native-binary verification
above, not on a test that shells out to ffmpeg.

## Part 2 — the local-playback foundation

### The blocker Phase 0 actually found

The brief assumed "podcast episodes are downloaded files" as a starting
premise. Tracing `PlayerController.playWork` -> `EpisodePlayer.setUrl`
-> `JustAudioEpisodePlayer` -> `just_audio` showed that through 8a1af19
this was false in the one sense that matters for DSP: `playWork` called
`await p.setUrl(work.sourceUrl)` unconditionally. The only place
anything was ever written to `services.audioFileFor(workId, url)` was
`TranscribeCoordinator`'s own audio-fetch step (a byproduct of
requesting a transcript); `audio_eviction.dart` only ever deleted that
same byproduct; and the river's "Re-download audio" menu item for an
archived episode is literally `_transcribe()` relabeled. Nothing in the
player stack ever read that file. A DSP pipeline that promoted a
processed file into that path would have produced a file nothing played
— a feature claim with no check behind it, and (worse) the
transcript-exclusivity eligibility law would have applied to a set of
episodes that was empty by construction, since transcription was the
only door onto disk in the first place.

Reported to the architect rather than worked around; ruled Option 1
(extend the player) — this section is that extension.

### The law

**`EpisodePlayer` gains `setFilePath(String path)`** (mirroring
`just_audio`'s own `setUrl`/`setFilePath` pair) alongside `setUrl`.
`JustAudioEpisodePlayer.setFilePath` calls `AudioPlayer.setFilePath`
directly; `FakeEpisodePlayer` records `loadedFilePath` the same way it
already recorded `loadedUrl`, so existing streamed-URL tests stay
byte-for-byte unmodified — nothing about them changed, because nothing
about their code path did.

**`PlayerController` takes an optional `File Function(int workId, String
url)? localAudioFileFor`.** Null (every construction site before this
campaign, and the default in tests that don't ask for it) means "always
stream" — exactly this app's pre-campaign behavior, preserved by
construction rather than by a flag. `HomeShell` wires the one real
caller: `widget.services.audioFileFor`, the SAME resolver
`TranscribeCoordinator` and `audio_eviction.dart` already use. The law,
stated once and applying everywhere: **the local file IS the episode,
the moment one exists at that path; the network URL is the fallback,
not the primary.**

`playWork` checks with `File.existsSync()`, never `File.exists()` — the
same synchronous-on-purpose rule `TranscribeCoordinator.dismiss` already
follows (a real-IO `await` never resolves inside a widget test's
fake-async zone). This is a check-before, not a live subscription: a
file that appears or disappears mid-playback has no effect until the
NEXT `playWork` call, which is the same granularity every other
file-presence check in this pipeline (`pcm.existsSync()`, the decode
step's own checkpoint) already uses.

### The eviction-composition law, now real

Stated at Phase-0-report time as a law that would hold "regardless of
which option the architect picks" — now actually load-bearing instead
of hypothetical. `audio_eviction.dart` deletes exactly
`services.audioFileFor(workId, url)`; `playWork` now reads exactly that
same path. So: promote a file there (transcription's download today;
the DSP pipeline's atomic promote in Part 3) and the very next play
reads it. Evict it and the very next play falls back to streaming — "Re-
download audio" keeps meaning what its label says, for the first time.
No change was needed in `audio_eviction.dart` itself; the law was
already correct, it simply had no consumer on the playback side until
now.

### Proven unaffected: speed, resume, sleep timer, queue

The architect's condition for this section: source type must not change
downstream behavior. It doesn't, by construction — `playWork` decides
*which* loader to call, then every line after that (feed speed override,
skip-intro seek, resume-from-position, sleep timer arming, Up Next
auto-advance on finish) is unchanged code operating on the SAME
`work`/`_currentFeed`/position rows regardless of which branch loaded
the audio. `test/features/player_test.dart`'s new `'local file playback
(Campaign 6)'` group proves the specific claim (speed override 1.75x
and a stored resume position of 42s both apply identically when the
source is a local file) rather than asserting "nothing changed" for
every existing feature in isolation — the existing
per-feed-settings/smart-resume/sleep-timer/Up-Next test groups
(`player_test.dart`, unedited) are the rest of that proof: they never
changed, because `playWork`'s local-file branch is a fork in HOW audio
loads, not a fork in anything after it.

### Verification

`flutter test test/features/player_test.dart`: 63 passed (4 new), 0
failed — including every pre-existing per-feed-settings, smart-resume,
sleep-timer and Up-Next test, unmodified. `flutter analyze
lib/features/player/ lib/features/profiles/home_shell.dart`: 0 issues.

### A latent web-tier crash, caught before it shipped

`HomeShell` initially wired `localAudioFileFor: widget.services.audioFileFor`
unconditionally. `dart:io`'s `File` constructs fine under dart2js (per
`bootstrap_web.dart`'s own comment: "constructing dart:io types is pure
Dart... no P3 flow ever operates on them on this tier") but throws
`UnsupportedError` the moment an actual IO method runs — exactly why
`localMlAvailable` already gates every other P3 flow in this same file.
Unconditional wiring meant EVERY web-tier `playWork` call would have hit
`local.existsSync()` and crashed the instant a user pressed play — a
regression this Dart-VM test suite could never catch (tests run on the
VM, not under dart2js), caught only by re-checking the web bootstrap's
own documented constraint. Fixed: `localAudioFileFor` is
`widget.services.localMlAvailable ? widget.services.audioFileFor : null`
— null being exactly this app's pre-campaign, always-stream behavior,
which is also exactly correct on a tier that cannot touch a real
filesystem.

### The standalone Download door

Local-file playback is only useful once there's a way onto disk that
isn't "ask for a transcript." `EpisodeDownloadCoordinator`
(`lib/features/feeds/episode_download_coordinator.dart`) is that second
door: a `ChangeNotifier` over the fleet's one download engine
(`AudioFetcher`), targeting the exact same `services.audioFileFor(workId,
url)` path `PlayerController` reads and `audio_eviction.dart` deletes.
No persisted job row — deliberately. `AudioFetcher`'s own `.part` file
beside the target already IS the resumability checkpoint (the same law
`TranscribeCoordinator`'s own audio-fetch step relies on for the same
reason); a single, non-chunked fetch has no per-unit progress to
checkpoint the way whisper's executor does, so adding a `JobsTable` row
here would be ceremony with no failure mode it actually protects
against. `start` is idempotent (a no-op if already downloading or
already on disk) and `cancel` stops an in-flight fetch without deleting
the partial.

The river's per-episode menu gains **Download** (`river_screen.dart`),
through the SAME `confirmDownload` chokepoint `_transcribe` already
uses — ADR-0003 law 6's "there is no second door" holds at the DIALOG
level even though there are now two DOORS onto disk. A quiet
`Icons.download_done` indicator marks a row already on disk (positive
framing: absence says nothing, the icon says "here"), and the menu item
itself disappears once one exists — never a dead or redundant action.
Both the coordinator and the menu item are gated on `localMlAvailable`,
same as `_localAudioFileFor`'s wiring in Part 2 and the pre-existing
transcribe items — `HomeShell` never even constructs
`EpisodeDownloadCoordinator` on the web tier, so there's no `File`
sitting around to accidentally call a real IO method on.

**Autonomous downloading is explicitly out of scope, on purpose.**
`Feeds.autoDownload` exists as a column already and stays unwired —
Campaign 5's verdict (download only ever happens on the user's own tap)
stands. This campaign adds a second EXPLICIT door, not an automatic one.

### Verification

`flutter test test/features/episode_download_coordinator_test.dart`: 7
passed, 0 failed (happy path, already-downloaded no-op, disk-truth
`isDownloaded`, in-flight progress, cancel-clears-state, error surfaces
honestly, concurrent `start()` calls only fetch once). `flutter test
test/features/river_test.dart`: 13 passed (3 new), 0 failed — the
Download item, the consent dialog round trip both ways, and the quiet
indicator's presence/absence, exercised through the real widget tree
with a `FakeAudioFetcher` (no socket, no real IO). `flutter analyze`:
0 issues, whole app.

## Part 3 — schema v16

Three additive columns, no new table — `JobsTable` (kind='dsp', Phase
1b below) already generalizes the checkpointed-job row this pipeline
needs. `Feeds.dspEnabled` (nullable bool: null defers to
[Profiles.dspGlobalDefault], same escape-hatch shape every other
per-feed override already uses). `Episodes.dspOriginalDurationMs` /
`dspProcessedDurationMs` (nullable ints, set together in one write —
[FeedsDao.setDspResult] — so a partially-set pair can never exist for
the time-saved counter to misread). `Profiles.dspGlobalDefault` (bool,
default false — processing is opt-in, matching the feature's own
"downloaded episodes, on this device" honesty).

`schemaVersion` moves 12 -> 16 directly. v13/v14/v15 are claimed by
sibling campaigns not yet merged into this branch; this branch's own
migration block is guarded `if (from < 16)` (with the usual `from >= 2`
inner guard for the feeds/episodes columns, matching the v12 block's
own reasoning) and will need interleaving with the siblings' blocks at
rebase time — not this branch's decision to make.

### The migration-fixture tax, paid in full

Every one of the 8 files under `app/test/db/` matching `user_version`
(`captures_db_test.dart`, `daily_review_db_test.dart`,
`feeds_db_test.dart`, `household_db_test.dart`, `jobs_db_test.dart`,
`ledger_db_test.dart`, `profiles_db_test.dart`, `study_db_test.dart` —
verified by `grep -rl "user_version" app/test/db/`, not assumed from an
older count) seeds its historical-version fixture via
`AppDatabase.forTesting()` at the CURRENT compile-time schema, then
strips exactly what its own hop added, then stamps the older
`user_version`. Bumping `schemaVersion` to 16 without touching these
fixtures broke every single one — watched directly, not assumed:

```
SqliteException(1): while executing, duplicate column name: dsp_enabled, SQL logic error (code 1)
  Causing statement: ALTER TABLE "feeds" ADD COLUMN "dsp_enabled" ...
```

(`feeds_db_test.dart`'s v11->v12 test; the identical error, same
column, reproduced in all 7 other files by running each in isolation
before touching any of them.) The fix is additive in every file — four
new `ALTER TABLE ... DROP COLUMN` lines appended to each fixture's
existing strip block, never replacing or reordering what was already
there, so the fixtures still compose when this branch rebases onto
whichever sibling schema hops land first.

A new `'schema migration v12 -> v16'` group (`feeds_db_test.dart`,
mirroring the existing v11->v12 test's own shape) proves the fresh hop
directly: seed a v12 snapshot, strip exactly what v16 added, migrate,
confirm old data survives and every new column works.

### DAO surface

`FeedsDao.updatePlaybackSettings` gains `bool? dspEnabled`, following
its own documented law — every argument's null means "clear this back
to deferring," the settings screen always writes its full current form
state, same as `speedOverride`/`keepLatestAudio` before it.
`FeedsDao.setDspResult(workId, {required originalDurationMs, required
processedDurationMs})` is the pipeline's one write for both durations
together. `ProfilesDao.dspGlobalDefault(profileId)` /
`setDspGlobalDefault` mirror `scheduler`/`setScheduler` exactly — an
honest `false` default for a profile no row exists for yet.

### Verification

`flutter test test/db/`: 105 passed, 0 failed (up from ~90 pre-
campaign — the exact delta is the new v12->v16 fixture, the
`dspEnabled`/`setDspResult`/`dspGlobalDefault` DAO tests, and the 8
existing migration tests un-broken by the fixture fix). `flutter
analyze`: 0 issues, whole app.

## Part 4 — the preprocess pipeline

### The chosen filter parameters (as run, quoted from `dsp_params.dart`)

```
silenceremove=start_periods=1:start_duration=1.5:start_threshold=-50dB:start_silence=0.5:stop_periods=-1:stop_duration=1.5:stop_threshold=-50dB:stop_silence=0.5,loudnorm=I=-16:TP=-1.5:LRA=11
```

`silenceremove` trims silence longer than 1.5s (`*_duration`) down to
0.5s (`*_silence`) at a conservative -50dB floor (`*_threshold` — very
quiet, so real speech is never mistaken for silence), applied both to
the leading edge (`start_*`) and throughout the rest of the file
(`stop_periods=-1`). `loudnorm` runs single-pass (no separate measure
pass — a documented v1 simplification, less precise than two-pass but
avoiding a second full decode) to -16 LUFS integrated (the Apple
Podcasts/Spotify spoken-word standard), -1.5dBTP true-peak ceiling, 11
LU loudness range (wide enough to keep a speaker's natural dynamics
rather than compressing them flat).

### Codec selection: preserve the container, never guess

The processed file is promoted onto the SAME path — same filename, same
extension — the original occupied, so it must stay a valid file of that
same format. `dspCodecFor` (`dsp_params.dart`) maps the recognized
podcast extensions to the pinned ffmpeg build's own encoders: mp3 ->
`libmp3lame`, m4a/aac/mp4 -> the native `aac` encoder, ogg/oga ->
`libvorbis`, opus -> `libopus`, wav -> `pcm_s16le`. An unrecognized
extension returns null — the coordinator treats that as an honest
failure (`DspEncodeException`), never a guess at an unfamiliar format.
Bitrate (`dspBitrateFor`) is 128k for every lossy codec but opus (96k,
reaching comparable quality at a lower bitrate — opus's own known
efficiency advantage for speech); pcm carries no bitrate concept.

### Fail-closed sanity, before the atomic promote

`dspOutputSane` (pure, unit-tested independently of any file) is the
gate a processed file must clear before it ever touches the original's
path: non-zero size, non-zero duration, never LONGER than the original
(silenceremove can only shrink), and never shrunk past 10% of the
original's duration (`kMinDspOutputFraction`) — a deliberately generous
floor that only rejects genuinely implausible output (a botched encode
producing a near-empty file), not a legitimately silence-heavy episode.
A failed sanity check deletes the temp output and leaves the original
completely untouched — the model-store law (ADR pending on the general
shape, the same "verify before you trust a downloaded artifact" law
`ModelStore`'s own sha256-verify-then-rename already follows) applied
to a locally-generated artifact instead of a downloaded one.

### The atomic promote, and what it composes with

`DspCoordinator._drive` writes the working output to
`dspPartPathFor(audio.path)` (same directory, `.dsppart` marker before
the extension — never colliding with `AudioFetcher`'s own `.part`
convention on the same file), then — only after `dspOutputSane` passes
— `File.rename`s it onto `audio.path` itself: the exact path
`services.audioFileFor(workId, url)` resolves, the exact path
`PlayerController.playWork` now prefers (Part 2), the exact path
`audio_eviction.dart` deletes. **The eviction-composition law, stated at
Phase-0-report time and made real in Part 2, is what this promote step
actually exercises**: a processed file IS the downloaded audio from the
moment it lands; eviction deletes it exactly as it would the
unprocessed original; a later re-download replaces it with a fresh,
UNPROCESSED copy (DSP does not re-run automatically — a re-download is
indistinguishable from a first download to this pipeline, and
`dspOriginalDurationMs`/`dspProcessedDurationMs` stay stored from the
prior run until a fresh DSP pass overwrites them or the episode row
itself is swept — a known, accepted staleness this pass didn't need to
solve, since the counter is a lifetime SUM of past savings, not a
per-episode "is this currently processed" flag).

### Reusing the checkpointed-job machinery — what "reuse" means here

Same `JobsTable` row (`kind='dsp'` instead of `'transcribe'`), same
`JobState` enum, same restore-from-`unfinished()`-rows pattern on
reopen, same `JobForegroundGate` (screen-off survival) — literally the
identical mechanism `TranscribeCoordinator` uses, not a parallel one.
What's DELIBERATELY not reused: transcription's chunked executor
(`jobs_core`'s `ChunkedTask`/`Runner`, built for whisper's genuinely
resumable per-segment inference). A single ffmpeg pass has no natural
sub-unit checkpoint the way per-segment transcription does — cancel and
resume in this pipeline work at the SAME granularity `TranscribeCoordinator`'s
own decode step already does: checked between named stages
(measure -> process -> promote), never preemptive of an in-flight
ffmpeg call. A killed or cancelled run leaves the original file
completely untouched (nothing is promoted until the very end) and
simply re-measures and re-encodes from scratch on its next `start`/
`resume` — safe, if not byte-efficient, and proportionate to a job
that's minutes long, not the tens of minutes transcription can run.

A synchronization law worth recording precisely because it was caught
by a test, not read off a design doc: `_flows[workId]` is claimed
SYNCHRONOUSLY as the very first action inside `start()`/`resume()`,
before any `await` — not inside `_drive` as `TranscribeCoordinator`'s
own `start()` does it. Two `start()` calls issued back-to-back without
awaiting the first would otherwise both pass the `containsKey` guard
(neither coordinator's `_flows` map is populated until the first
`await` boundary resolves) and both call the encoder — a real,
reproducible race a "starting twice only fetches once" test caught
directly. `TranscribeCoordinator` carries the identical latent race
(unexercised by this campaign, out of scope to fix here, recorded as a
found-but-not-fixed discovery for whoever next touches that file).

### Verification

`flutter test test/dsp/`: 36 passed, 0 failed — 26 pure-function tests
(`dsp_params_test.dart`: the exact filter string, every codec/bitrate
mapping, `timeSavedMs`'s never-negative law, `dspOutputSane`'s five
boundary cases, `dspEligible`'s four-cell truth table,
`dspPartPathFor`'s naming, `effectiveDspEnabled`'s override law) and 10
coordinator tests against a `FakeDspEncoder` (`dsp_coordinator_test.dart`:
happy path with atomic promote, no-audio failure, ffmpeg-throws
failure with the original verified byte-for-byte untouched, garbage-
output and zero-byte sanity rejections each verified the same way,
both eligibility-law refusals verified to never touch the encoder at
all, the reverse-direction non-block, the double-start race fix, and
job-row restore on reopen). `flutter analyze`: 0 issues, whole app. No
real ffmpeg binary runs in this suite — `FfmpegDspEncoder` is as
untested-directly as `FfmpegDecoder` already was, and for the identical
reason (see the spec's own test-plan note: mirror the decoder's harness
or say plainly that the faked boundary suffices — it does; nothing in
this checkout runs real ffmpeg under `flutter test` on this host).

## Part 5 — settings, the counter, and wiring DSP to Download

### The per-feed and household settings

`FeedSettingsScreen` gains a self-contained `_DspSettingsSection`
widget (own state read from a `value`/`onChanged` pair, own `feed-
settings-dsp-*` Keys) inserted between the existing keep-latest-audio
field and the Save button — deliberately factored apart from the
surrounding `_FeedSettingsScreenState` rather than inlined, since
campaign-5's own unmerged branch extends this exact screen with a
per-feed rules section; composing two independent widget subtrees at
rebase time is a smaller, more legible conflict than two edits
tangled inside one giant `build()` method. Same tri-state law as
`speedOverride`: null defers to the household default, true/false
overrides it either way.

The household default lives on `FeedsScreen`'s own app-bar menu (the
same `PopupMenuButton` that already holds Import/Export OPML) as a
`CheckedPopupMenuItem` — "Trim silence & even out volume by default,"
checked state read from `Profiles.dspGlobalDefault`. Both surfaces are
gated on `localMlAvailable`, the same law protecting the download door
and the local-file player resolver from the web tier's dart:io
`UnsupportedError`.

**A real ensureVisible landmine, caught by the tests themselves.**
Adding the DSP section pushed `FeedSettingsScreen`'s Save button (and,
in the newly-added tests, the DSP buttons themselves) below the fold
of the widget test's 800x600 default viewport. `tester.tap()` on an
off-screen widget dispatches a hit-test at a coordinate outside the
render tree and silently misses — not a crash, a warning plus a
false-negative assertion three lines later. All FIVE Save-button taps
in `opml_flow_test.dart` (three pre-existing, two new) needed
`ensureVisible` added before the tap; this is exactly the
`ergonomic-ux` skill's own "a finder finding a widget does not mean it
is tappable" law, hit for real rather than read about.

### The lifetime "time saved" counter

`HouseholdDao.lifetimeBuiltOf` (which needed `Episodes` added to its
own `@DriftAccessor` tables list — it never queried that table before)
joins `episodes` to `works` by `profileId`, sums
`dspOriginalDurationMs - dspProcessedDurationMs` across every episode
where both are set (an episode never processed contributes nothing,
never a null-crash), and clamps each episode's own contribution at
zero the same way the pure `timeSavedMs` law does — inlined rather
than importing `dsp_params.dart` into `lib/db/`, which would invert
the fleet's usual db-below-features layering for two lines of
arithmetic already unit-tested at its own layer. `LifetimeBuilt` gains
`timeSavedMs`; `builtLines` gains a line (`_timeSaved`, mirroring
`_listening`'s exact minute/hour/h-min forms, just "saved" instead of
"of listening") that appears only when positive — the same positive-
framing law (ADR-0003 law 5) governing every other line on the parent
dashboard: zero is expressed by saying nothing.

### Composing DSP with Download — the one trigger, no second door

The spec's own framing — "processed on download, on this device" — is
literal, not aspirational: `RiverScreen._download` calls
`_maybeProcess` immediately after a successful `EpisodeDownloadCoordinator.start()`,
which checks disk truth (`isDownloaded`), reads the episode's feed and
the household default, resolves `effectiveDspEnabled`, and only then
calls `DspCoordinator.start()`. There is **no separate manual "Process
now" action** — a deliberate v1 scope limit, not an oversight: the
setting's whole promise is that downloading already does this, and a
second manual trigger would be a second, redundant door onto the same
outcome the eligibility law and the settings toggle already govern.
`DspCoordinator`/`EpisodeDownloadCoordinator` are both constructed in
`HomeShell` under the same `localMlAvailable` null-on-web law as every
other Campaign 6 flow.

**A second real-IO-under-testWidgets landmine, caught by the widget
test that actually exercises the composed flow.** `DspCoordinator`'s
own unit tests (plain `test()`, a normal Dart VM event loop) never
surfaced it, but `river_test.dart`'s widget test hung silently at the
atomic-promote step: `File.rename()` returns a real IO `Future` that
never resolves inside a widget test's fake-async zone — the exact law
`TranscribeCoordinator.dismiss`'s own doc comment already names
("real-io futures never complete under widget fake-async zones").
Fixed: `tempFile.renameSync(audio.path)`, matching that same existing
convention. Diagnosed with two temporary `print` statements bracketing
the promote step (removed once the fix was confirmed) rather than
guessed at — the hang, not an exception, was the tell: nothing was
thrown, the awaited `Future` simply never completed.

### Verification

`flutter test test/features/opml_flow_test.dart`: 12 passed (4 new: 2
per-feed tri-state round-trips, 2 household-default checked-state
round-trips), 0 failed. `flutter test test/features/parent_dashboard_test.dart`:
17 passed (7 new: 6 pure `builtLines` unit tests for the minute/hour/
h-min forms and the zero-says-nothing law, 1 widget-level assertion
that the line actually renders), 0 failed. `flutter test
test/db/household_db_test.dart`: 6 passed (extended, not new — the
existing "counts what the reader has built" test now also seeds and
asserts `timeSavedMs`, including the cross-profile-isolation and
never-processed-contributes-zero cases). `flutter test
test/features/river_test.dart`: 25 passed (2 new: DSP-enabled-feed
composes, DSP-off-feed doesn't), 0 failed. `flutter analyze`: 0
issues, whole app.

## Consequences

- **Proven through the interface, not on real hardware or a real
  ffmpeg binary** — the same honesty ADR-0007 recorded for Supertonic,
  now for this campaign. Every ffmpeg-touching path
  (`FfmpegDspEncoder`, `FfmpegDecoder`) is exercised only through a
  faked `DspEncoder`/`Decoder` boundary; what remains genuinely
  unexecuted is the real filter graph actually running on a real file,
  and the real codec/bitrate choices actually producing a file every
  target platform's audio stack accepts. One Android build and a real
  podcast episode away, not further Dart code.
- The APK's licensing is clean end to end again (Part 1) — the moment
  a release is cut from this branch, ADR-0007's "MIT-clean" claim is
  true rather than aspirational, and ~22MB smaller per arm64 ABI as a
  side effect the release's C3 size budget should record.
- Local-file playback (Part 2) is now real infrastructure other
  features can build on, not just this campaign's own plumbing — any
  future "offline" feature has a working local-file-over-network-URL
  law to extend rather than invent.
- **No manual "process now" action exists** (Part 5) — a stated v1
  scope limit. An episode downloaded before its feed's DSP setting was
  turned on stays unprocessed until it's evicted and re-downloaded.
  Recorded as a real, low-risk future option (a manual trigger reusing
  the exact same `DspCoordinator.start()` call `_maybeProcess` already
  makes) — not built this pass, since the automatic composition covers
  the feature's stated promise on its own.
- `TranscribeCoordinator`'s own `start()`/`resume()` carry the
  identical double-fetch race `DspCoordinator`'s fixed (Part 4) —
  unexercised by any existing test, unfixed here, a real candidate for
  whoever next touches that file.
- The repo-wide `dart format` drift this campaign's own diffs
  incidentally surfaced (files it touched reformatted under the
  currently-pinned `dart_style`, confirmed pre-existing by diffing
  master's own `database.dart` against the same formatter before this
  campaign changed anything) is NOT fixed fleet-wide here — only the
  files this campaign substantively edited were reformatted; three
  files touched by accident (`library_dao_test.dart`,
  `queue_db_test.dart`, `spine_db_test.dart`) were reverted to their
  original formatting on purpose, to keep this campaign's diff to what
  it actually changed. A repo-wide `dart format .` pass is a real,
  independently reviewable future cleanup, not this campaign's job.
