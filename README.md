# Trellis

Stop reading like a caveman. Load any source — a podcast transcript, a paper, a
textbook chapter, a talk — or just name a topic, and Trellis turns it into a
**dependency graph of concepts**, each with a dense **RSVP intake** passage and a
**difficulty-laddered recall** set, then drills it into durable, first-principles,
*teachable* memory with spaced repetition. The bar: you should come out able to
give a 3Blue1Brown/Karpathy-grade explanation — intuitive, re-derivable, story-shaped.

Retrieval-first, not consumption: you read fast, then you *recall*, and the
schedule strips the cue away over time (cloze → free generation).

## Three pieces

1. **`.ohcourse` format** — the shareable curriculum file (versioned JSON).
   Spec: [`docs/curriculum-format.md`](docs/curriculum-format.md) · schema:
   [`schema/ohcourse.schema.json`](schema/ohcourse.schema.json). Designed to be
   diffable and GitHub-shareable (the long-term "Yoto-cards-for-knowledge" /
   homeschool-curriculum-sharing vision).
2. **`trellis-author` skill** (in `iss-skills/`) — paste a source *or* give it a
   topic; it researches (deep-research for zero-to-hero), builds the graph + intake
   passages + recall ladder, validates, and writes an `.ohcourse`.
3. **this Flutter app** — imports an `.ohcourse`, runs the loop, schedules (SM-2),
   tracks mastery. Builds to **APK + web**.

## The loop

Library (your courses) → Course map (concept graph, mastery, what's due, prereq
locks) → Study session: **RSVP-intake** a concept → **recall** its items (type the
cloze blanks / answer / pick / self-recall) → **grade** (auto for cloze &
multiple-choice; keyword-suggested self-rate for free recall) → **SM-2 schedules**
the next review → mastery advances and unlocks downstream concepts.

## Run / build

```bash
# from this directory, using the repo's Flutter SDK
flutter pub get
flutter test                        # 99 tests (parser, SM-2, grading, screen goldens)
flutter run                         # on a device/emulator
flutter build apk --debug           # installable debug APK (build/app/outputs/flutter-apk/)
flutter build web --release         # build/web/  (serve statically)
```

A real **Kalman-filter course** (KF → EKF → UKF → IMM, 5 concepts / 20 items) is
bundled in `assets/courses/`, so the app has content on first launch. Import more
via the **+** button (paste an `.ohcourse`).

## Authoring a course

Use the `trellis-author` skill: *"build me a Trellis course on X"* or *"turn
this transcript into an .ohcourse"*. It writes a validated file you import. Validate
by hand with `python3 iss-skills/skills/trellis-author/scripts/validate_ohcourse.py <file>`.

## Architecture

Clean-ish layers per feature (`domain` / `data` / `presentation`), Riverpod for
state, shared_preferences for persistence (SM-2 card state + imported courses).
See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). Pure logic (parser, SM-2,
grading) is unit-tested; the screens have golden tests.

## Roadmap (deferred)

- API-key book/source download + "research and fetch more" from inside the app.
- The shareable curriculum marketplace (GitHub-for-homeschoolers, Yoto-style cards).
- Animated (Manim) explainers as a premium intake surface.
- FSRS scheduler; Drift persistence; visual cloze (image-occlusion) for diagrams/anatomy.
