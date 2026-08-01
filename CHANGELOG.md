# Changelog

This repo had no CHANGELOG.md before this entry — the release notes surface
that existed was `fastlane/metadata/android/en-US/changelogs/`, which is
keyed by Android versionCode and isn't the right place to record a change
that ships no version bump. This file starts here as a narrative record
alongside it, in the common "Unreleased" convention, not a replacement for
it.

## 1.2.0 (2026-08-14) — build 2006

The first APK to carry the neural voice — and it carries it MIT-clean.
1.1.0's sentence-paced speak mode and the Skein lane ship to Android for
the first time here too (1.1.0 released as a PWA only, its APK held back
precisely because of the licensing question this release resolves).

### Changed

- Speak mode's neural voice rung moves from sherpa-onnx (Piper voices) to
  Supertonic, over `flutter_onnxruntime`. Supertonic needs no phonemizer —
  the model consumes raw character indices — so the shipped APK is MIT-clean
  end to end; sherpa-onnx's TTS path statically bundled espeak-ng
  (GPL-3.0), which meant the previous rung would have made any APK built
  with it a GPL-3.0 binary the moment it shipped. See
  `docs/adr/0007-the-voice-goes-mit.md` for the full accounting.
- The starter voice registry entry moves from `piper-en-libritts-r-medium`
  (23.4 MB, CC-BY-4.0 + GPL-3.0) to `supertonic-en-m1` (~263.5 MB,
  OpenRAIL-M) — a real, honest size increase the models screen states
  plainly before any download starts. The voice's minimum device tier
  moves from T1 to T2, matching VISION's own freedom-of-compute ladder.
- `sherpa_onnx` and its per-platform native packages are removed from
  `app/pubspec.yaml`.

### Added

- `SupertonicVoiceLayout` (`packages/ml_runtime`) — names which downloaded
  filename plays which role for a voice whose files ship loose (no archive
  to extract), the same "data, not code" contract `VoiceArchiveLayout`
  gives an archived voice.
