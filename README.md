# Trellis

> **Reading is the setup; recall is the product.** A local-first spaced-repetition
> reader that turns any source into a dependency graph of concepts and drills it
> into durable, re-derivable, *teachable* memory.

Stop reading like a caveman. Load any source — a podcast transcript, a paper, a
textbook chapter, a talk — or just name a topic, and Trellis turns it into a
**dependency graph of concepts**, each with a dense **RSVP intake** passage and a
**difficulty-laddered recall** set, then drills it into durable, first-principles,
*teachable* memory with spaced repetition. The bar: you should come out able to
give a 3Blue1Brown/Karpathy-grade explanation — intuitive, re-derivable, story-shaped.

Retrieval-first, not consumption: you read fast, then you *recall*, and the
schedule strips the cue away over time (cloze → free generation).

> **This is the native app in the Trellis line.** The line's *primary, unified*
> reader is **ohPrimer** (the PWA); this Flutter build is the **secondary/native**
> surface — same loop, packaged for offline Android/desktop, with native share and
> Anki export. Both read the same shared `.ohcourse` format. See
> [`VISION.md`](VISION.md), [`docs/whitepaper.md`](docs/whitepaper.md), and
> [ADR-0006](docs/adr/0006-native-secondary-to-ohprimer.md).

**See the docs:** start at [`VISION.md`](VISION.md) (the north star + honest
scorecard), then the [documentation hub](docs/README.md) (Diátaxis-organized:
tutorials · how-to · reference · explanation). Agents/contributors: [`AGENTS.md`](AGENTS.md).

## Three pieces

1. **`.ohcourse` format** — the shareable curriculum file (versioned JSON).
   Spec: [`docs/curriculum-format.md`](docs/curriculum-format.md) · schema:
   [`schema/ohcourse.schema.json`](schema/ohcourse.schema.json). Designed to be
   diffable and GitHub-shareable (the long-term "Yoto-cards-for-knowledge" /
   homeschool-curriculum-sharing vision).
2. **`trellis-author` skill** (external authoring tool) — paste a source *or* give
   it a topic; it researches (deep-research for zero-to-hero), builds the graph +
   intake passages + recall ladder, validates, and writes an `.ohcourse`.
3. **this Flutter app** — imports an `.ohcourse`, runs the loop, schedules (SM-2),
   tracks mastery. Builds to **APK + web**.

## The loop

Library (your courses) → Course map (concept graph, mastery, what's due, prereq
locks) → Study session: **RSVP-intake** a concept → **recall** its items (type the
cloze blanks / answer / pick / self-recall) → **grade** (auto for cloze &
multiple-choice; keyword-suggested self-rate for free recall) → **SM-2 schedules**
the next review → mastery advances and unlocks downstream concepts.

## Run / build

Trellis's encrypted backup ([below](#encrypted-backup)) is built on two shared
packages consumed by **sibling path dependency** (`../packages/...`, the same
convention as `eloEngine`). Clone them next to this repo so the paths resolve:

```
packages/
  sanctuary_auth_core/     # github: levitatingflyfisher/sanctuaryAuthCore
  sanctuary_backup_ui/     # github: levitatingflyfisher/sanctuaryBackupUi
Trellis/                   # this repo
```

```bash
git clone https://github.com/levitatingflyfisher/sanctuaryAuthCore packages/sanctuary_auth_core
git clone https://github.com/levitatingflyfisher/sanctuaryBackupUi packages/sanctuary_backup_ui
git clone <repo-url> Trellis
cd Trellis

# from this directory, using the repo's Flutter SDK
flutter pub get
flutter test                        # 138 tests (parser, SM-2, grading, screen goldens, backup)
flutter run                         # on a device/emulator
flutter build apk --debug           # installable debug APK (build/app/outputs/flutter-apk/)
flutter build web --release         # build/web/  (serve statically)
```

A real **Kalman-filter course** (KF → EKF → UKF → IMM, 5 concepts / 20 items) is
bundled in `assets/courses/`, so the app has content on first launch. Import more
via the **+** button (paste an `.ohcourse`).

## Encrypted backup

The lock icon beside the **+** import button opens **Backup & Restore**: a
12-word recovery phrase you write down once, then use to export an encrypted
`.ohbk` file (imported courses + all study progress, including progress
against the bundled course) or restore one on a new device. There is no
server and no account — the phrase *is* the recovery key. See
[ADR-0007](docs/adr/0007-encrypted-backup.md) and the [privacy
model](docs/privacy-model.md).

## Authoring a course

Use the `trellis-author` skill: *"build me a Trellis course on X"* or *"turn
this transcript into an .ohcourse"*. It writes a validated file you import. The app
validates on import; to check a file by hand, validate it against
[`schema/ohcourse.schema.json`](schema/ohcourse.schema.json).

## Architecture

Clean-ish layers per feature (`domain` / `data` / `presentation`), Riverpod for
state, shared_preferences for persistence (SM-2 card state + imported courses).
See [`docs/architecture/OVERVIEW.md`](docs/architecture/OVERVIEW.md). Pure logic
(parser, SM-2, grading) is unit-tested; the screens have golden tests.

## Roadmap (deferred)

- API-key book/source download + "research and fetch more" from inside the app.
- The shareable curriculum marketplace (GitHub-for-homeschoolers, Yoto-style cards).
- Animated (Manim) explainers as a premium intake surface.
- FSRS scheduler; Drift persistence; visual cloze (image-occlusion) for diagrams/anatomy.
