# ADR-0002: `shared_preferences` for storage now; Drift deferred

- **Status:** Accepted
- **Date:** 2026-07-03

## Context

The app persists two things: imported course JSON (a handful of KB each) and per-item
SM-2 `CardState` (a small map keyed by course id). The OpenHearth portfolio
convention is **Drift over sqflite** for local storage, and an earlier
`docs/ARCHITECTURE.md` in this repo described a Drift schema (`courses`, `cards`,
`reviews`) as if it were built. It was not — the code uses `shared_preferences`. That
gap is a live example of Law 1: take comments as a hypothesis, not gospel.

The real question a maintainer faces: honor the Drift convention now, or ship the
simplest store that fits the current data shape?

## Decision

Use **`shared_preferences`** as the store for v1, behind plain repository classes
(`CourseRepository`, `CardRepository`) that hide it. Course state is stored as JSON
under `course:<id>`; card state as JSON under `cards:<courseId>`. Drift is the
**documented productionization path**, not a current dependency.

The repository seam is deliberate: swapping in Drift later means reimplementing two
small classes, not touching the domain or UI.

## Consequences

- **Buys:** minimal dependencies for the core loop (no native DB in the hot path);
  trivial web support; the data volume genuinely fits a key-value store.
- **Costs:** no relational queries, no review-log history, no partial loads. The
  whole card map for a course is read/written at once (fine at current sizes,
  wrong at 10k items).
- **Forecloses:** nothing permanently — the seam keeps Drift a drop-in. What it
  *does* foreclose is trusting the old `ARCHITECTURE.md`; that file is now a redirect
  to [architecture/OVERVIEW.md](../architecture/OVERVIEW.md).

## Alternatives considered

- **Drift now:** deferred. It's the right end-state but overweight for KB-scale
  key-value data; adopting it should be driven by a real need (review history, large
  decks), and it gets its own ADR when it lands.
- **Raw `sqlite3`:** rejected as the general store. Note `sqlite3` *is* a dependency,
  but only for **Anki `.apkg` export** ([ADR reference in OVERVIEW](../architecture/OVERVIEW.md#consumption-surfaces--build-targets)),
  not for app persistence.
