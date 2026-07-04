# Feature status

Precise lookup of what's shipped vs. deferred, as of **v1.0.0**. This is the
tabular companion to the [honest scorecard](../../VISION.md#honest-scorecard--built-vs-aspirational).
Law 1 applies — verify against the code/tests before relying on any row.

## Core loop

| Feature | Status | Where |
|---|---|---|
| Import + validate `.ohcourse` (version-gated, path-qualified errors) | ✅ shipped, tested | `curriculum_parser.dart` |
| Referential integrity + prereq-cycle rejection | ✅ shipped, tested | `curriculum_parser.dart` |
| Library screen (list courses, import via **+**) | ✅ shipped | `library_screen.dart` |
| Course map (mastery, prereq locks, due counts) | ✅ shipped | `course_map_screen.dart`, `progress.dart` |
| Study session (intake → recall → grade → schedule) | ✅ shipped | `study_session_screen.dart` |
| RSVP intake (ORP pivot, WPM 150–800, dwell weighting) | ✅ shipped | `rsvp_reader.dart` |
| SM-2 scheduler (pure, UTC epoch-day, deterministic) | ✅ shipped, tested | `sm2_scheduler.dart` |
| Grading: cloze/discrimination auto | ✅ shipped, tested | `grading.dart` |
| Grading: qa/procedure keyword-suggested self-rate | ✅ shipped, tested | `grading.dart` |
| Mastery + prerequisite unlock | ✅ shipped, tested | `progress.dart` |
| Markdown + LaTeX rendering | ✅ shipped | `markdown.dart` |
| Bundled sample course (Kalman / multi-target-tracking) | ✅ shipped | `assets/courses/` |

## Item types (recall ladder)

| Type | Status | Auto-graded? |
|---|---|---|
| `cloze` (`{{cN::answer}}` blanks) | ✅ | yes (normalized exact match) |
| `qa` (free recall) | ✅ | no — keyword-suggested self-rate |
| `discrimination` (choose the odd one out) | ✅ | yes (correct index) |
| `procedure` (perform-and-describe) | ✅ | no — rubric-suggested self-rate |

## Platforms & I/O

| Feature | Status | Notes |
|---|---|---|
| Android APK | ✅ shipped | `flutter build apk` |
| Web (PWA) | ✅ builds/runs | ohPrimer is the line's canonical web reader |
| Anki `.apkg` export | ✅ native only | hidden on web (`dart:io` + `sqlite3`) |
| Local persistence | ✅ `shared_preferences` | keyed per course |

## Deferred / aspirational (documented, not built)

| Feature | Status | Reference |
|---|---|---|
| Drift / SQLite app persistence | ⏳ deferred | [ADR-0002](../adr/0002-shared-preferences-storage.md) |
| FSRS scheduler | ⏳ deferred | [ADR-0004](../adr/0004-retrieval-first-sm2.md) |
| In-app source download / "research more" | ⏳ deferred | [limitations](../limitations.md) |
| Image-occlusion / visual cloze | ⏳ deferred | [limitations](../limitations.md) |
| Animated (Manim) intake | ⏳ deferred | [limitations](../limitations.md) |
| Sync / backup | 🚫 not planned as BaaS | encrypted-blob-only if ever ([ADR-0001](../adr/0001-local-first-no-accounts.md)) |
| Shareable curriculum marketplace | 🌅 horizon | [VISION § Horizons](../../VISION.md#horizons-problems-not-a-dated-feature-list) |

## The format

The `.ohcourse` format itself is documented in the
[format reference](../curriculum-format.md) and pinned by
[`schema/ohcourse.schema.json`](../../schema/ohcourse.schema.json). Current
`schemaVersion`: **`1.0`**.
