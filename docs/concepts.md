# Concepts

The ideas behind Trellis, in prose. For the file format see
[curriculum-format.md](curriculum-format.md); for how the pieces fit,
[architecture/OVERVIEW.md](architecture/OVERVIEW.md).

## Retrieval-first learning

The core bet: **you remember what you practise retrieving, not what you re-read.**
Two well-replicated effects drive the design — the *testing effect* (recalling
something strengthens it more than restudying it) and the *spacing effect* (reviews
spread over time beat massed cramming). So Trellis inverts the usual reader. Reading
a concept is the *setup*; being made to recall it — repeatedly, on a widening
schedule — is the *product*. The success bar isn't "I recognize this," it's "I can
re-derive and teach it."

## The concept graph (a prerequisite DAG)

A course is not a flat pile of cards. It's a **directed acyclic graph of
`KnowledgeNode`s**, where an edge `A → B` means "understand A before B." Each node
has a short `summary`, a dense `intake` passage, an optional `diagramMermaid`, and a
list of `RetrievalItem`s. The graph does real work:

- **Ordering.** You meet foundations before the things built on them.
- **Gating.** A node stays **locked** until all its prerequisites are *fully
  mastered* — so you can't drill the advanced concept before the ones it depends on.
- **Integrity.** The parser enforces that every prereq names a real node and that
  the graph has **no cycles** (a cycle would leave nodes permanently unreachable).

## The rung ladder (desirable difficulty)

Every `RetrievalItem` carries a **`rung` from 1 to 4**, an estimate of
`H(answer | cue)` — how much you must *generate* rather than *recognize*:

- **Rung 1–2:** high-cue. A cloze blank in a sentence; a fine discrimination.
- **Rung 3–4:** low-cue. Free recall from a bare prompt; explain-it-yourself.

The point is to keep retrieval effortful-but-achievable and to climb the ladder as a
concept sticks — recognition is the training wheels, generation is the goal.

## The four retrieval item types

| Type | What it drills | Graded how |
|---|---|---|
| **cloze** | high-cue recall of specific tokens (`{{c1::answer}}` blanks) | auto: normalized exact match per blank |
| **qa** | free recall — minimal cue, maximal generation (the prize items) | keyword-suggested → **honest self-rate** |
| **discrimination** | fine-precision recognition (near-identical choices) | auto: chosen index == correct index |
| **procedure** | embodied/step knowledge (e.g. perform-and-describe) | rubric-suggested → **honest self-rate** |

`RetrievalItem` is a **sealed** type — the four subtypes are exhaustive, so the
compiler forces every parser and UI site to handle each kind.

## RSVP / ORP intake

The reading step is a **Rapid Serial Visual Presentation** streamer: words flash one
at a time at an adjustable WPM (150–800), each pinned so its **Optimal Recognition
Point** (the letter the eye should fixate) sits on a fixed centre guide. Keeping the
pivot still is what lets the eye stop darting and words stream past. Punctuation gets
a longer beat (sentence ends dwell ~2.2×, clauses ~1.6×) so structure lands. Math and
markup don't speed-read, so the RSVP text collapses equations to a token
(`[equation]`) while the rendered card remains the surface for reading the math
itself.

## SM-2 scheduling

After each recall you (or the auto-grader) assign a **Grade** — again / hard / good /
easy — which maps to an SM-2 quality `q` of 2 / 3 / 4 / 5:

- **`q < 3` is a lapse:** the card resets (reps → 0, a lapse counted) and comes due
  again immediately to relearn this session.
- **`q ≥ 3` graduates it:** the interval grows (first step, then 6 days, then
  `interval × ease`), with *hard* shortening and *easy* stretching the *good*
  interval; the ease factor drifts by the SM-2 recurrence, floored at 1.3.

All scheduling is in **whole days since the Unix epoch (UTC)**, which makes the
scheduler deterministic, timezone-stable, and trivial to unit-test. `CardState`
(ease, interval, due day, reps, lapses) is stored per item, separate from the
immutable course content.

## Mastery and unlocking

A node's **mastery** is the fraction of its items whose interval has reached a
"durable enough" threshold. A node is **due** if any of its items is due (a
never-seen item counts as due-to-learn). A node **unlocks** once *all* its
prerequisite nodes hit full mastery. The course map surfaces all three — a mastery
bar per node, a due-count chip, and a lock icon — plus one overall mastery figure.

## The `.ohcourse` format as the shared contract

The format is the seam between the *authoring skill* that writes courses and the
*readers* that study them (this app and the ohPrimer PWA). It's plain versioned JSON:
diffable, GitHub-shareable, self-contained (everything to run the loop is in the
file), and provenance-carrying (each course, and ideally each item, cites its
source). Because two independent surfaces consume it, it's treated as a strict
contract — see [ADR-0003](adr/0003-ohcourse-shared-contract.md) and the full
[format reference](curriculum-format.md).
