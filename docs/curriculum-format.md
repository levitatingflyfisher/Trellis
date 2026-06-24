# The `.ohcourse` curriculum format (v1.0)

The single contract between the **authoring skill** (writes it) and the
**Trellis app** (ingests it). A plain, versioned JSON file — diffable,
GitHub-shareable, and designed to be *built up over time* (the long-term
"Yoto-cards-for-knowledge" / homeschool-curriculum-sharing vision). One file =
one course someone can drop into their brain.

## Design principles

- **Retrieval-first.** A course is not text to read; it's a dependency graph of
  concepts, each with (a) a dense *intake* passage and (b) a ladder of
  *retrieval items* that force recall. Consumption is the setup; recall is the
  product.
- **The difficulty ladder is explicit.** Every item carries a `rung` (1–4) ≈
  `H(answer | cue)` — how much you must generate from memory. Rung 1 = high-cue
  (cloze), rung 4 = free generation. The scheduler graduates you up the ladder.
- **Provenance is first-class.** Every course and ideally every item cites where
  it came from, so a learner can trust and trace it.
- **Self-contained.** No external fetches needed to study; everything to run the
  loop is in the file.

## Top-level shape

```jsonc
{
  "schemaVersion": "1.0",
  "id": "kebab-case-stable-id",
  "title": "Human title",
  "subtitle": "one line",
  "subject": "domain",
  "level": "elementary | undergrad | grad | undergrad-to-frontier",
  "description": "what you'll be able to do after — the 3b1b/Karpathy bar",
  "provenance": {
    "kind": "researched | from-source",
    "generatedBy": "trellis-author",
    "created": "YYYY-MM-DD",
    "sources": [ { "title": "...", "url": "...", "note": "..." } ]
  },
  "srsDefaults": { "algorithm": "sm2", "initialEase": 2.5, "firstIntervalDays": 1 },
  "nodes": [ /* KnowledgeNode[] — a prerequisite DAG */ ]
}
```

## `KnowledgeNode`

```jsonc
{
  "id": "kebab-id",
  "title": "Concept name",
  "summary": "one-sentence what-it-is",
  "prereqs": ["other-node-id", "..."],     // edges of the DAG (must reference earlier-resolvable nodes)
  "diagramMermaid": "flowchart LR; A-->B",  // optional: a diagram for this node (rendered as a graphic)
  "intake": "A dense, RSVP-ready passage that teaches the concept from first principles, story-first, intuition-before-formalism. This is the speed-read payload.",
  "items": [ /* RetrievalItem[] — the recall ladder for this node */ ]
}
```

## `RetrievalItem`

One of four `type`s. All share `id`, `rung` (1–4), optional `hints` (progressive),
optional `sources`.

```jsonc
// cloze — high-cue recall (rung 1–2). Anki-style {{cN::answer}} blanks.
{ "id": "n1-i1", "type": "cloze", "rung": 1,
  "text": "The KF runs a recursive {{c1::predict}}→{{c2::update}} cycle.",
  "answers": { "c1": "predict", "c2": "update" } }

// qa — free recall (rung 2–4). The prize items: minimal cue, maximal generation.
{ "id": "n1-i2", "type": "qa", "rung": 3,
  "prompt": "IMM solves a different problem than EKF/UKF. What, and how does the mechanism work?",
  "answer": "Model/regime switching (e.g. a maneuvering target). A bank of filters, one per motion model, mixed each step via a Markov transition matrix into a probability-weighted estimate.",
  "acceptable": ["regime switching", "bank of filters", "markov"],   // keyword anchors for lenient auto-grading
  "rubric": "Must name (a) the switching problem and (b) the bank + Markov mixing." }

// discrimination — fine-precision recognition (the near-identical-MC dial).
{ "id": "n1-i3", "type": "discrimination", "rung": 2,
  "prompt": "Exactly one is false:",
  "choices": ["UKF requires Jacobians", "EKF can diverge under strong nonlinearity",
              "IMM runs multiple models in parallel", "The linear KF is MMSE-optimal under linear-Gaussian assumptions"],
  "correctIndex": 0,
  "explanation": "UKF is derivative-free (sigma points), so it needs no Jacobians." }

// procedure — actionable/embodied knowledge (e.g. a stretch you perform).
{ "id": "n1-i4", "type": "procedure", "rung": 2,
  "prompt": "Perform and describe the doorway pec stretch — setup, what you should feel, hold time.",
  "steps": ["Forearms on the door frame, elbows ~shoulder height", "Step one foot through, lean gently",
            "Feel a stretch across the chest/front shoulder — never sharp", "Hold 20–30s, 2–3×"],
  "rubric": "Must capture arm position, the lean, the chest stretch sensation, and a ~20–30s hold." }
```

## Grading model (how the app scores a recall)

- **cloze / discrimination** → auto-graded (exact/normalized match, or correct index).
- **qa / procedure** → graded against `acceptable` keyword anchors for a *suggested*
  score, then the learner self-rates (Again / Hard / Good / Easy) — the rubric is
  shown after the attempt so self-grading is honest. Self-rating drives the SRS.

## Scheduling

The app holds per-item SRS state (not in the file). `srsDefaults.algorithm` is
`sm2` for v1 (ease factor + interval + reps; FSRS is the productionization path).
A node is "due" when any of its items is due; mastery = fraction of its items at
interval ≥ a threshold.

## Validation

`schema/ohcourse.schema.json` is the machine-checkable contract. The authoring
skill validates its output against it before writing; the app validates on import
and refuses malformed files with a clear message.
