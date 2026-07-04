# Vision

> The north star for Trellis. If you (person or agent) are about to change
> something load-bearing, read this first — it says what must stay true and why.
> For *how it's built*, see [docs/architecture/OVERVIEW.md](docs/architecture/OVERVIEW.md);
> for *why each decision was made*, [docs/adr/](docs/adr/).

## The one idea

**Reading is the setup; recall is the product.** Most study tools help you
*consume* material faster. Trellis treats consumption as a warm-up and puts the
weight on *retrieval*: load any source — a transcript, a paper, a chapter, a talk,
or just a topic — turn it into a **dependency graph of concepts**, read each one
fast, then be made to *recall* it, on a schedule that strips the cue away over time
(cloze → free generation). The bar isn't "I've seen this." It's "I can re-derive
and teach this from first principles."

## What this is

A **local-first spaced-repetition reader** — a native Flutter app that imports a
course file (`.ohcourse`), walks you through its concept graph, and drills each
concept into durable memory with a difficulty-laddered recall loop scheduled by
SM-2.

Trellis is the **native app in the Trellis knowledge-engine line**. There are three
pieces to the line, and only one of them lives in this repo:

1. **The `.ohcourse` format** — a versioned, GitHub-shareable JSON curriculum file
   (one file = one course you can drop into your head). Spec:
   [docs/curriculum-format.md](docs/curriculum-format.md) · schema:
   [schema/ohcourse.schema.json](schema/ohcourse.schema.json).
2. **An authoring skill** (external, `trellis-author`) — pastes a source or takes a
   topic and *writes* a validated `.ohcourse`.
3. **A reader app** that ingests an `.ohcourse` and runs the loop. This repo is one
   such reader: the **native / Flutter** one.

> **Which surface is canonical?** The Trellis line's **primary, unified reader is
> ohPrimer** — the progressive web app (PWA). This Flutter build is the
> **secondary, native surface**: the same reading loop, packaged for offline
> Android/desktop where a native app buys things the web can't (see
> [docs/whitepaper.md](docs/whitepaper.md) and
> [ADR-0006](docs/adr/0006-native-secondary-to-ohprimer.md)). If you're deciding
> where a *format* or *loop* change belongs, ohPrimer is where the product's centre
> of gravity sits; this app follows the shared `.ohcourse` contract. Don't let the
> two drift apart silently.

## Design commitments (the invariants — do not break these)

These are the load-bearing beliefs Trellis shares with every OpenHearth app, in
this app's own terms. Breaking one is a design regression, not a feature.

1. **Local-first, no account, ever.** Courses and every scrap of study progress
   live on the device (`shared_preferences`). There is no login, no server, no
   cloud dependency for anything the app does. Ghost mode *is* the product.
   ([ADR-0001](docs/adr/0001-local-first-no-accounts.md))
2. **Nothing leaves the device unless you push it out.** The app makes no network
   calls of its own. The only egress is user-initiated: sharing an exported Anki
   deck. Untrusted course markdown is explicitly forbidden from phoning home — a
   remote `![](https://…)` image renders as a placeholder, never a silent GET.
   ([ADR-0005](docs/adr/0005-no-remote-fetch-from-courses.md), [docs/privacy-model.md](docs/privacy-model.md))
3. **No ads, no tracking, no telemetry** — architecturally, not just by promise.
   Grep the dependency list: there is nothing to phone home *with*.
4. **The `.ohcourse` file is a contract.** It is versioned (`schemaVersion`),
   JSON-Schema-checkable, and diffable. The app accepts exactly the versions it
   understands and refuses a malformed file with a traceable error — it never
   half-imports. ([ADR-0003](docs/adr/0003-ohcourse-shared-contract.md))
5. **Retrieval-first, cue-laddered.** Every recall item carries a `rung` (1–4) ≈
   *how much you must generate from memory*. The schedule graduates you up the
   ladder; the point is generation, not recognition.
   ([ADR-0004](docs/adr/0004-retrieval-first-sm2.md))
6. **Genuine craft.** Pure logic (parser, SM-2, grading, progress) is unit-tested;
   screens have golden tests. Clean-ish layers per feature (domain / data /
   presentation), Riverpod for state. Warm, not sterile.

## Honest scorecard — built vs. aspirational

A guiding light has to tell the truth about where the light reaches. **Every line
of source and every comment in this repo was written by an AI assistant.** Treat it
as *an accurate record of what currently exists, offered with gratitude and a grain
of salt* — not a specification and not guaranteed-correct. If a comment and the
tests disagree, the tests win; if the tests and reality disagree, reality wins.
Verify a claim before you rely on it. As of v1.0.0:

**Real, tested, load-bearing:**
- The full loop: import an `.ohcourse` → browse the concept map (mastery,
  prerequisite locks, due counts) → study a node (RSVP intake → recall ladder →
  grade → SM-2 schedules the next review → mastery advances and unlocks downstream
  concepts). This is the whole thesis and it runs.
- The `.ohcourse` **parser**: schema-version gated, referential-integrity checked,
  prerequisite-cycle rejecting, path-qualified error messages. Unit-tested.
- The **SM-2 scheduler**, **grading** (cloze/discrimination auto; qa/procedure
  keyword-suggested self-rate), and **progress/unlock** math — all pure functions,
  unit-tested, timezone-stable (whole-day epoch scheduling).
- **RSVP intake** with an ORP-aligned pivot and per-word dwell weighting.
- **Anki `.apkg` export** (native targets only; hidden on web).
- A real **multi-target-tracking / Kalman-filter course** is bundled, so the app
  has content on first launch. Builds to **APK** and **web**.

**Aspirational — documented, not shipped:**
- **Drift / SQLite persistence.** Storage is `shared_preferences` today; the code
  is written behind repository classes so Drift is a drop-in later, but it is *not*
  built. (The older `docs/ARCHITECTURE.md` that claimed Drift was ahead of the
  code — a Law-1 grain-of-salt example. See [ADR-0002](docs/adr/0002-shared-preferences-storage.md).)
- **FSRS scheduling**, **in-app source download / "research more"**, **animated
  (Manim) intake**, **visual/image-occlusion cloze**, and the **shareable
  curriculum marketplace** — all named directions, none built here.
- **Sync of any kind.** There is none, by design; if it ever arrives it travels as
  encrypted blobs through a dumb relay, never a BaaS.

The loop is real. Anything about a *different scheduler*, a *different store*, or a
*marketplace* is still a hope. Keep that line bright.

## Horizons (problems, not a dated feature list)

- **Near** — Decide storage honestly: either ship the Drift store the code is shaped
  for, or delete the aspiration and commit to `shared_preferences`. Keep the
  `.ohcourse` schema in lockstep with ohPrimer so a course authored for one reader
  studies identically in the other.
- **Mid** — A better forgetting curve (FSRS) behind the same pure-scheduler seam.
  Richer intake surfaces (diagrams already ride in `diagramMermaid`; image-occlusion
  cloze is the natural next recall type).
- **Far** — The open one worth naming: **course sharing without a server.** The
  format is already diffable and file-shaped; the unsolved part is a trustworthy,
  account-free way to publish and discover courses (the "Yoto-cards-for-knowledge /
  homeschool-curriculum-sharing" idea) that stays true to local-first.

## The name

**Trellis** — the frame you grow a plant up. A trellis doesn't make the plant; it
gives structure so growth goes somewhere and holds. Here the plant is your
understanding, and the trellis is the concept graph plus the recall schedule:
prerequisites below, new concepts unlocking above, each one drilled until it bears
weight. You do the growing; Trellis just makes sure it climbs.
