# AGENTS.md

Guidance for AI coding agents (and humans) working in this repo. This is the
top-level map; the closest `AGENTS.md` to the file you're editing wins.

**Read these three, in order, before non-trivial work:**
1. [VISION.md](VISION.md) — what must stay true and why (the invariants).
2. [docs/architecture/OVERVIEW.md](docs/architecture/OVERVIEW.md) — how it fits together, with diagrams.
3. [docs/curriculum-format.md](docs/curriculum-format.md) — the `.ohcourse` contract everything hangs off.

## Take the code as current-state, not gospel

Every line of source and every comment here was written by an AI assistant. Treat
it as **an accurate record of what currently exists, offered with gratitude and a
grain of salt** — not as a specification and not as guaranteed-correct. A comment
claiming an invariant is a *hypothesis to verify*, not a proof. If a comment and the
tests disagree, the tests win; if the tests and reality disagree, reality wins.
Concrete live example: the older `docs/ARCHITECTURE.md` describes a **Drift**
persistence layer; the code actually uses **`shared_preferences`**. When you rely on
a claim, confirm it (read the code, run the test) first.

## What this is

A local-first, **native (Flutter)** spaced-repetition reader for `.ohcourse`
curriculum files: import a course → walk its concept graph → RSVP-read each concept
→ recall its items up a difficulty ladder → grade → SM-2 schedules the next review →
mastery unlocks downstream concepts. It is the **secondary/native surface** of the
Trellis line; the primary reader is the **ohPrimer PWA**. The `.ohcourse` format is
the shared contract between them — see [VISION.md](VISION.md).

## Non-negotiables (breaking one is a regression, not a feature)

- **Local-first, no accounts, no network of our own.** The app must run fully
  offline with zero server contact. Don't add a login, an analytics SDK, or a
  "cloud sync" that isn't encrypted-blob-through-a-dumb-relay. See
  [ADR-0001](docs/adr/0001-local-first-no-accounts.md).
- **Never fetch from untrusted course content.** Imported `.ohcourse` markdown is
  untrusted input. Remote images render as a placeholder, not a network GET (see
  `lib/core/markdown.dart`). Any new rendering path must keep this property.
  [ADR-0005](docs/adr/0005-no-remote-fetch-from-courses.md).
- **Fail loud on a bad import; never half-import.** The parser throws a
  path-qualified `FormatException` on malformed input and the UI shows it. A new
  field is *tolerant* if optional, *strict* if required — no silent coercions that
  mask a broken course. See `curriculum_parser.dart`.
- **Keep the domain pure.** `sm2_scheduler.dart`, `grading.dart`, `progress.dart`,
  and `models.dart` are pure, deterministic, I/O-free, and unit-tested. Scheduling
  is in whole epoch-days (UTC) so it's timezone-stable. New logic goes here first,
  test-first — not into a widget.
- **TDD, always.** Reproduce → failing test → fix → `flutter test` green → commit.
  Every bugfix ships with a regression test (see `test/regression_test.dart`).
- **Atomic commits, one concern each.** Commit messages state the *why* and the
  failure mode fixed. **No AI-attribution trailers** — don't append machine
  co-author or "made with" sign-off lines to commits. Deliberate project policy.
- **Never commit local working artifacts** — the gitignored agent-instruction file
  and `docs/superpowers/` (local plans/specs). This repo ships `AGENTS.md`.

## Where things are (progressive disclosure)

Start with the module map in
[OVERVIEW.md § Module map](docs/architecture/OVERVIEW.md#module-map-where-to-look).
The short version, by concern:

| You're touching… | Go to |
|---|---|
| **The domain model / `.ohcourse` types** | `lib/features/curriculum/domain/models.dart` |
| **Parsing / validating an imported course** | `lib/features/curriculum/data/curriculum_parser.dart` |
| **Loading & persisting courses** | `lib/features/curriculum/data/course_repository.dart` |
| **Scheduling (SM-2)** | `lib/features/study/domain/sm2_scheduler.dart` |
| **Grading a recall** | `lib/features/study/domain/grading.dart` |
| **Mastery / prerequisite unlock math** | `lib/features/study/domain/progress.dart` |
| **Per-item SRS state persistence** | `lib/features/study/data/card_repository.dart` |
| **The study loop UI** | `lib/features/study/presentation/study_session_screen.dart`, `rsvp_reader.dart` |
| **Library / course-map screens** | `lib/features/curriculum/presentation/*.dart` |
| **Anki export** (native only) | `lib/features/curriculum/data/anki/*.dart` |
| **Markdown/LaTeX rendering + RSVP text prep** | `lib/core/markdown.dart` |
| **Providers / theme / time** | `lib/core/providers.dart`, `theme.dart`, `time.dart` |
| **The format spec / schema** | `docs/curriculum-format.md`, `schema/ohcourse.schema.json` |

Docs are organized [Diátaxis](https://diataxis.fr/)-style — see
[docs/README.md](docs/README.md) for the tutorials / how-to / reference / explanation
split.

## How to work here

```bash
flutter pub get
flutter test              # the suite — must be green before you commit
flutter analyze           # static analysis — must be clean (config in analysis_options.yaml)
flutter run               # on a device/emulator
flutter build apk --debug # installable debug APK -> build/app/outputs/flutter-apk/
flutter build web --release
```

- Flutter, Dart SDK `^3.10.7`. State is **Riverpod**; persistence is
  **`shared_preferences`** (not Drift — see the grain-of-salt note above).
- **Anki export** is a conditional import (`anki_export.dart` → native `dart:io` +
  `sqlite3` impl, or a throwing web stub). `sqlite3`, `crypto`, `archive`,
  `path_provider`, and `share_plus` exist *only* for this feature; the core loop
  uses none of them. Guard on `ankiExportSupported` before calling it.
- **Golden tests** live in `test/visual/`. If a screen changes intentionally,
  regenerate with `flutter test --update-goldens` and eyeball the diff.

## When you're unsure

Prefer a failing test to a plausible fix. Prefer matching the surrounding code to
introducing a new pattern. Prefer rejecting a malformed course to coercing it.
Prefer keeping the app offline to adding one convenient network call. When in doubt
about a decision's rationale, grep [docs/adr/](docs/adr/) before reopening it — you
may be re-litigating a settled trade-off (especially the storage choice and the
ohPrimer relationship).
