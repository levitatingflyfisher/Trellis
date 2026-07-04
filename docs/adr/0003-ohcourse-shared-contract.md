# ADR-0003: `.ohcourse` is a versioned, validated contract

- **Status:** Accepted
- **Date:** 2026-07-03

## Context

A course is authored in one place (the `trellis-author` skill) and consumed in
another (this app, and the ohPrimer PWA). Whenever a producer and a consumer are
separated like that, the file between them is a **contract**. If the app is lax about
what it accepts — coercing missing fields, ignoring a version bump, silently dropping
a bad item — a subtly broken course studies wrong and the failure surfaces much later
as confusing behavior, not a clear error.

## Decision

Treat the `.ohcourse` file as a strict, versioned contract:

- **Version gating.** The parser accepts exactly `schemaVersion: "1.0"` and rejects
  anything else with a clear message. Unknown versions are refused, not guessed.
- **Tolerant of optional, strict about required.** Missing optional fields fall back
  to model defaults; a missing/mistyped *required* field, an unknown item `type`, or
  a non-object node throws a **path-qualified `FormatException`** (e.g.
  `node 'kf-core' item 'kf-1': cloze requires 'text' and 'answers'`).
- **Structural integrity, not just field types.** Every `prereq` must name a real
  node, no node may be its own prereq, and the prerequisite graph must be **acyclic**
  (a cycle would make nodes permanently unreachable, since unlock requires prereq
  mastery). All checked at parse time.
- **Never half-import.** Import is all-or-nothing; the UI shows the exact error.
- A machine-checkable **JSON Schema** ([schema/ohcourse.schema.json](../../schema/ohcourse.schema.json))
  is the companion contract the authoring skill validates against.

## Consequences

- **Buys:** broken courses fail fast, at the boundary, with a traceable message. The
  format can evolve safely — a future reader knows exactly which versions it handles.
- **Costs:** authors must produce well-formed files (mitigated: the skill validates
  before writing); a `schemaVersion` bump requires a deliberate parser update.
- **Forecloses:** best-effort "just render what parses" import. That's the right call
  for a contract shared across surfaces.

## Alternatives considered

- **Permissive parsing (coerce/skip bad parts):** rejected — it hides authoring bugs
  and lets the two readers diverge silently.
- **No version field:** rejected — without it, the format can never change without
  risking mis-parse in an old reader.
