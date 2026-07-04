# Limitations — read before adopting

Honest boundaries. What Trellis does *not* do today (v1.0.0), so you can decide with
open eyes. This complements the [honest scorecard](../VISION.md#honest-scorecard--built-vs-aspirational)
in VISION.md — and remember Law 1: the code was AI-authored; verify a claim before
you rely on it.

## It doesn't author courses

This repo is a **reader**. Turning a source or topic into an `.ohcourse` is the job
of the external `trellis-author` skill. Without a course to import (or the bundled
one), the app has nothing to drill.

## It doesn't fetch, research, or download anything

There is **no in-app source download**, no "research more," no web fetch of any kind
— by design ([ADR-0001](adr/0001-local-first-no-accounts.md),
[ADR-0005](adr/0005-no-remote-fetch-from-courses.md)). Remote images referenced in
course markdown render as a placeholder, not a download. You bring the course; the
app never phones out.

## Storage is `shared_preferences`, and install-scoped

Progress lives in `shared_preferences` on the device
([ADR-0002](adr/0002-shared-preferences-storage.md)). Consequences:

- **No sync, no backup, no cross-device continuity.** Uninstalling loses your
  progress unless you've separately exported the course.
- **No review history / analytics.** Only current SM-2 state per item is kept, not a
  log of past reviews.
- **Whole-map read/writes.** A course's card map is loaded and saved as one blob —
  fine at the current scale (courses of tens of items), not designed for decks of
  many thousands.

## The scheduler is SM-2, not FSRS

SM-2 is a solid, simple baseline, but it's cruder than modern schedulers (FSRS) at
modelling long-run forgetting. FSRS is the documented path, behind the same
pure-function seam — but it is **not built**.

## Free-recall grading leans on honest self-rating

For `qa` and `procedure` items there is no machine "right answer." The app suggests a
grade from keyword coverage and shows the rubric, but **you self-rate**. There's no
on-device judge model; a learner who over-rates themselves will get an easier
schedule than they've earned. That's an inherent trade-off of offline free-recall
grading, mitigated (not removed) by showing the rubric after each attempt.

## Rendering & intake constraints

- **Remote images don't display** (placeholder only) — see above. Diagrams ride as
  `diagramMermaid`; equations as LaTeX.
- **No image-occlusion / visual cloze** yet (natural next recall type, not built).
- **No animated (Manim) intake** — named as a future premium surface, not present.

## Web build vs. Anki export

The app builds to web (PWA), but **Anki `.apkg` export is native-only** — it needs
`dart:io` + `sqlite3`, so the export button is hidden on the web target. For the web
reading experience, the Trellis line's canonical PWA is **ohPrimer**
([ADR-0006](adr/0006-native-secondary-to-ohprimer.md)).

## No marketplace / sharing infrastructure

Courses are files you move around by hand. The "shareable curriculum marketplace"
(GitHub-for-homeschoolers, Yoto-style cards) is a *horizon*, not a feature — there is
no discovery, hosting, or trust layer for shared courses in the app.
