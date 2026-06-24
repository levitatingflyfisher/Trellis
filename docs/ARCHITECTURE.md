# Trellis — architecture

**Goal:** stop reading like a caveman. Load any source (or research a topic),
turn it into a dependency graph of concepts with intake passages + a recall
ladder, and drill it in so it becomes durable, first-principles, *teachable*
knowledge (the 3b1b/Karpathy bar). Retrieval-first, spaced, mastery-tracked.

## Three pieces

1. **`.ohcourse` format** (`docs/curriculum-format.md` + `schema/`) — the
   shareable contract. Skill writes it; app ingests it.
2. **`trellis-author` skill** (in `iss-skills/`) — source-or-topic →
   researched dependency graph → intake passages + recall ladder → `.ohcourse`.
3. **`Trellis` Flutter app** (this repo) — import `.ohcourse`, run the loop,
   schedule, track mastery. Builds to **APK + web**.

## App — Clean Architecture (portfolio convention: Riverpod + Drift)

```
lib/
  core/            constants, theme, json/schema helpers
  features/
    curriculum/
      domain/      Course, KnowledgeNode, RetrievalItem (immutable models) + parser
      data/        Drift DB (courses, card SRS state, review log) + repository
      presentation/ providers, Library screen (import/list), CourseMap screen
    study/
      domain/      SRS scheduler (SM-2), grading (cloze/qa/discrimination/procedure), CardState, due-selection
      data/        repository over the Drift card-state store
      presentation/ providers, StudySession screen: RSVP intake → recall ladder → grade → schedule
```

- **State:** Riverpod (providers per feature).
- **Persistence:** Drift — `courses` (the imported JSON, denormalized for query),
  `cards` (per-item SRS state: ease, intervalDays, due, reps, lapses, lastRung),
  `reviews` (log). Course content itself is parsed from the stored JSON.
- **SRS:** SM-2 variant — quality 0–5 from grade (Again/Hard/Good/Easy → 1/3/4/5,
  auto-grade contributes), updates ease+interval+due. Pure, unit-tested. FSRS is
  the documented productionization path.
- **Intake:** RSVP word-streamer (the ohPrimer idea, native in Flutter — a timed
  `Text` swap with an ORP-highlighted pivot letter), WPM-adjustable.
- **Grading:** cloze/discrimination auto; qa/procedure → keyword-anchored
  suggestion + honest self-rate against the shown rubric.

## The loop (StudySession)

pick due node → **RSVP-intake** its passage → for each due item, **recall** (type
the answer / pick / self-recall) → **grade** → **schedule** (SM-2) → mastery bar
updates → next. Miss → resurfaces sooner and the cue stays low on the ladder;
nail it → interval grows and the cue is stripped (rung climbs).

## Milestones (checkpoints = commits)

- [x] scaffold + format spec + schema
- [ ] authoring skill + a real generated Kalman `.ohcourse` (validates the format, seeds the app)
- [ ] domain: parser + SRS + grading (TDD)
- [ ] data: Drift store + repositories
- [ ] presentation: Library, CourseMap, StudySession (RSVP + recall ladder)
- [ ] bundle the sample course; end-to-end loop works
- [ ] golden tests (visual-loop); code-review + simplify pass
- [ ] build APK + web

## Deferred (user said "long term")

API-key book download / fetch-more-sources; the shareable curriculum marketplace
(GitHub-for-homeschoolers, Yoto-style); animated (Manim) explainers; FSRS.
