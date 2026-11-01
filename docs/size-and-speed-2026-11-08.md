# Size and speed, 2026-11-08

Measured before any size or speed change, so each later step has a number to
beat. Source commit: 2dac9fd.

## How it was measured

- APK: arm64 release, split per ABI, from a clean `git archive` export by the
  release recipe. Sizes are bytes.
- Timing and memory: Android 16 AVD `trellis_a36`, install over the 1.5.8 data
  snapshot. The AVD is x86_64 and cannot run the arm64 APK, so these numbers
  come from an x86_64 release build of the same commit.
- Cold start: `adb shell am start -W`, TotalTime, median of 11 after one
  settling launch. The box was busy with other work, so the spread is the
  noise floor. A timing win counts only if it beats that spread.
- The snapshot holds no book, only the note "Voice test", so the note stands
  in for a book when the reader is opened.

## Baseline

| Measure | Value |
|---|---|
| APK, arm64 release | 82,398,372 |
| Estimated download (apkanalyzer) | 36,440,802 |
| Native libraries | 79,510,792 |
| Dex, compressed (raw) | 1,670,326 (3,559,144) |
| Resources, compressed (raw) | 452,011 (548,289) |
| Fonts, compressed (raw) | 335,366 (644,100) |
| Other Flutter assets, compressed (raw) | 130,624 (176,397) |
| Everything else, compressed (raw) | 77,747 (429,826) |
| ML model files bundled | 0 |
| Cold start, median of 11 | 859 ms |
| Cold start range | 827 to 898 ms (spread 71 ms, IQR 20 ms) |
| Warm start, median of 5 (HOT) | 80 ms |
| RSS after start | 235,312 KB |
| RSS after opening the note | 237,892 KB |
| RSS with a podcast playing | 278,412 KB |
| `flutter analyze` | 33.4 s, no issues |
| `flutter test --concurrency=2` | 3 min 30 s, 2191 passed, 12 skipped |

Largest native libraries, uncompressed: libonnxruntime 28.6 MB, libapp 12.06 MB,
libavcodec 11.5 MB, libflutter 11.1 MB, libavformat 3.1 MB, libavfilter 2.9 MB,
libwhisper and libwhisper_dotprod 2.6 MB each.

R8, resource shrinking and Material icon tree shaking are already on.

## Final build

Source commit: dfb75d1. Timing and memory as above, on the x86_64 build of
that commit (sha256 4ef68c00...7ddf). The AVD was freshly booted for the final
timing and had been up for hours for the baseline.

| Measure | Baseline (2dac9fd) | Final (dfb75d1) | Change |
|---|---|---|---|
| APK, arm64 release | 82,398,372 | 82,269,153 | -129,219 |
| Cold start, median of 11 | 859 ms | 748 ms | -111 ms, see below |
| Cold start range | 827 to 898 ms | 734 to 813 ms | spread 71 and 79 ms |
| Warm start, median of 5 | 80 ms | 66 ms | -14 ms |
| RSS after start, median of 3 | 235,760 KB | 235,440 KB | within range |
| RSS after opening the note, median of 3 | 239,524 KB | 238,268 KB | within range |
| RSS with a podcast, 10 s, median of 3 | 311,184 KB | 312,132 KB | within range |
| RSS with a podcast, 30 s, median of 3 | 282,272 KB | 278,524 KB | within range |
| RSS with a podcast, 60 s, median of 3 | 284,352 KB | 283,028 KB | within range |
| `flutter test --concurrency=2` | 2191 passed, 12 skipped | 2191 passed, 12 skipped | no change |

- arm64 sha256: 3c36cf549030d11542ba4c4f9f754574e2755a3ef9f7e916b5d6ee59da61afb1.
  Signer 36b34188...6c859, versionCode 4021, both whisper libraries present.
- The cold start gain beats the spread but is not claimed as a win: neither
  change touched start-up, and the emulator's age differed between the runs.
- The three-run memory medians come from runs alternating the two builds.
  Memory peaks about 10 s into playback, then falls by about 30 MB.
- Compared with the baseline table above, its single podcast sample of
  278,412 KB was a low reading, not a typical one.

## What the climb changed

| Step | APK before | APK after | Saved |
|---|---|---|---|
| Remove `cupertino_icons`, used nowhere | 82,398,372 | 82,282,582 | 115,790 |
| Exclude build bookkeeping from the APK | 82,282,582 | 82,269,153 | 13,429 |

Checked and left as they are: all 38 direct dependencies are imported; the
largest duplicate inside the APK is one 3.5 KB licence text. Not attempted:
dead code inside the app, narrower R8 keep rules, and lazy loading. Options
that need a choice are in `docs/size-proposals-2026-11-08.md`.
