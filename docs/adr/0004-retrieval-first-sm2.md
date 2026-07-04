# ADR-0004: Retrieval-first, cue-laddered items; SM-2 for v1

- **Status:** Accepted
- **Date:** 2026-07-03

## Context

Most "learning" apps optimize *consumption* — read faster, highlight, summarize. The
evidence (testing effect, spacing effect) says the durable gains come from
**retrieval** and from **desirable difficulty**: recalling with less and less cueing
over time. The design question is how to encode that in a course file and a
scheduler without over-engineering the first version.

## Decision

Make **retrieval the product** and encode difficulty explicitly:

- Every `RetrievalItem` carries a **`rung` (1–4)** ≈ `H(answer | cue)` — how much you
  must generate from memory. Rung 1 = high-cue (cloze); rung 4 = free generation. The
  ladder is a first-class field, not an afterthought.
- **Four item types**, matched to what's being drilled: `cloze` (high-cue recall),
  `qa` (free recall — the prize items), `discrimination` (fine-precision
  recognition), `procedure` (embodied/step knowledge).
- **Grading matches the type.** `cloze`/`discrimination` auto-grade (there's a
  definitive answer). `qa`/`procedure` have no machine answer, so the app measures
  coverage of the author's `acceptable` keyword anchors to *suggest* a grade, then
  the learner **self-rates honestly against the shown rubric** — and that self-rating
  drives the schedule.
- **SM-2** is the scheduler for v1: a small, well-understood, pure, deterministic
  recurrence (ease + interval + reps, whole-day epoch scheduling). **FSRS** is the
  documented productionization path behind the same pure-function seam.

## Consequences

- **Buys:** the app teaches for re-derivation, not recognition; the format captures
  pedagogy an author intends; the scheduler is trivially testable and timezone-stable.
- **Costs:** self-rating is honest-effort dependent (by design — the rubric is shown
  to keep it grounded); SM-2 is cruder than FSRS on long-run scheduling.
- **Forecloses:** nothing hard — the pure-scheduler seam lets FSRS drop in; new
  recall types (e.g. image-occlusion cloze) extend the sealed `RetrievalItem` set.

## Alternatives considered

- **Consumption-first (speed-reading only):** rejected — RSVP intake stays, but as
  the *setup*, not the point.
- **FSRS now:** deferred — more accurate but heavier; SM-2 proves the loop first.
- **Auto-grade everything:** impossible for `qa`/`procedure` without an on-device
  judge; the keyword-suggested honest self-rate is the pragmatic, offline answer.
