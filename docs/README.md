# Documentation

Organized on the [Diátaxis](https://diataxis.fr/) model — four kinds of docs for
four different needs. Find what you need by *what you're trying to do*, not by
guessing a filename.

| I want to… | I need | Go to |
|---|---|---|
| **learn by doing** | a Tutorial | [Tutorials](#tutorials) |
| **accomplish a specific task** | a How-to guide | [How-to guides](#how-to-guides) |
| **look up exact details** | Reference | [Reference](#reference) |
| **understand why** | Explanation | [Explanation](#explanation) |

New here? Start with the [README quickstart](../README.md), then the
[Tutorials](#tutorials), then [Explanation § concepts](concepts.md).

> **Context in one line:** Trellis is the *native/Flutter* reader in the Trellis
> knowledge-engine line; the *primary* reader is the **ohPrimer** PWA, and both
> share the [`.ohcourse`](curriculum-format.md) format. See [VISION.md](../VISION.md).

---

## Tutorials
*Learning-oriented — take me by the hand through my first success.*

- The **[README quickstart](../README.md)** — install, run, study the bundled
  Kalman-filter course, import your own.

*Gap (contributions welcome):* a hand-held "author your first course and watch a
node unlock in 10 minutes" walkthrough. If you write one, put it in
`docs/tutorials/`.

## How-to guides
*Task-oriented — how do I accomplish X (assumes you know the basics)?*

- **[Build & run](how-to/build-and-run.md)** — get the app running on a device,
  build the APK and the web bundle.
- **[Author & import a course](how-to/author-and-import-a-course.md)** — get an
  `.ohcourse` into the app and validate it.
- **[Export to Anki](how-to/export-to-anki.md)** — turn a course into an `.apkg`
  deck (native targets).
- *Gap (contributions welcome):* a step-by-step "back up and restore your
  progress" walkthrough. See the [encrypted backup ADR](adr/0007-encrypted-backup.md)
  and the [README](../README.md#encrypted-backup) in the meantime.

## Reference
*Information-oriented — tell me exactly, precisely, completely.*

- **[`.ohcourse` format](curriculum-format.md)** — the curriculum file format
  (v1.0): top-level shape, `KnowledgeNode`, the four `RetrievalItem` types, the
  grading and scheduling model. This is the shared contract, co-owned with ohPrimer.
- **[`schema/ohcourse.schema.json`](../schema/ohcourse.schema.json)** — the
  machine-checkable JSON Schema for the format.
- **[Feature status](reference/feature-status.md)** — what's shipped vs. deferred,
  per surface.
- The public domain surface is `lib/features/**/domain/` (`Course`,
  `KnowledgeNode`, `RetrievalItem`, `CardState`, `scheduleSm2`, the grading
  functions) — see the [architecture module map](architecture/OVERVIEW.md#module-map-where-to-look).

## Explanation
*Understanding-oriented — help me understand the ideas and the why.*

- **[Vision](../VISION.md)** — the one idea, the invariants, the honest scorecard.
- **[Architecture overview](architecture/OVERVIEW.md)** — the loop + diagrams.
- **[Architecture Decision Records](adr/)** — why each load-bearing choice was made.
- **[Concepts](concepts.md)** — retrieval-first learning, the concept DAG, the rung
  ladder, RSVP/ORP intake, SM-2, mastery & unlocking, the grading model.
- **[Privacy model](privacy-model.md)** — exactly what does (and doesn't) leave the
  device, and how to check it.
- **[Limitations](limitations.md)** — read before adopting. What it does *not* do.
- **[White paper](whitepaper.md)** — the conceptual case for a *native* reader
  alongside the ohPrimer PWA, honest about built vs. aspirational.

---

### On the absence of a "yellow paper"

openDaisugi (the house-style exemplar) ships a *yellow paper* — a rigorous formal
spec — because it has a machine-checked verification core. Trellis does not, and
deliberately doesn't add one. The single formalizable artifact here is the
**`.ohcourse` format**, and it already has a precise prose spec
([curriculum-format.md](curriculum-format.md)) plus a machine-checkable JSON Schema
([schema/](../schema/ohcourse.schema.json)). That format is the *shared* contract of
the whole Trellis line (canonically co-owned with ohPrimer); a separate yellow paper
would duplicate it, not add rigor. The rest of the "formal" surface — the SM-2
recurrence and the grading thresholds — is a handful of pure functions fully pinned
by unit tests. No padding: the spec that matters already exists as reference.
