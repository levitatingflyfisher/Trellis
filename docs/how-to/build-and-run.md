# How-to: build & run Trellis

Task-oriented. Assumes you have the repo's Flutter SDK available and a device or
emulator. For the shape of the codebase, see
[architecture/OVERVIEW.md](../architecture/OVERVIEW.md).

## Prerequisites

- Flutter with a Dart SDK matching `^3.10.7` (see `environment` in `pubspec.yaml`).
- A device/emulator for `run`; nothing extra for `test`/`analyze`.

## First run

```bash
flutter pub get        # fetch dependencies
flutter test           # run the suite — should be green
flutter analyze        # static analysis — should be clean
flutter run            # launch on a connected device/emulator
```

On first launch the app already has content: a bundled **Kalman-filter /
multi-target-tracking** course (`assets/courses/`). Open it to walk the whole loop
without importing anything.

## Build an installable APK

```bash
flutter build apk --debug     # -> build/app/outputs/flutter-apk/app-debug.apk
```

Use `--release` for a release build (needs signing config). The debug APK is the
quickest way to sideload onto an Android device.

## Build the web bundle (PWA)

```bash
flutter build web --release   # -> build/web/  (serve statically)
```

The web build runs, but note **Anki export is native-only** and hidden on web (it
needs `dart:io` + `sqlite3`). For the canonical web experience of the Trellis line,
use the **ohPrimer** PWA — see [ADR-0006](../adr/0006-native-secondary-to-ohprimer.md).

## Tests & goldens

- The suite covers the parser, SM-2 scheduler, grading, card repository, and a
  regression file, plus **golden tests** for the screens (`test/visual/`).
- If you change a screen on purpose and a golden fails, regenerate and eyeball the
  diff:

```bash
flutter test --update-goldens
```

Golden failures write diffs under `test/visual/failures/` (gitignored). Always look
at the image before accepting a new golden.
