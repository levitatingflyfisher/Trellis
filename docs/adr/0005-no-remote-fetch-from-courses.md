# ADR-0005: Never fetch from untrusted course content

- **Status:** Accepted
- **Date:** 2026-07-03

## Context

Courses are imported from outside the app — pasted JSON, shared files, eventually
files from other people. The intake and answer prose is rendered as **markdown +
LaTeX**. The default markdown renderer turns `![](https://…)` into an
`Image(NetworkImage(url))` — a **silent outbound GET the moment the passage
renders**. That is a tracking-beacon primitive: an author (or someone who tampered
with a shared file) could learn *when and from where* a course is being studied, and
it quietly violates the "no network of our own / nothing leaves the device" invariant
([ADR-0001](0001-local-first-no-accounts.md)).

## Decision

**Treat all imported course content as untrusted, and never let it initiate a
network request.** Concretely, the shared markdown renderer (`lib/core/markdown.dart`)
supplies an `imageBuilder` that renders a **placeholder icon** instead of fetching
any remote image. No rendering path may reintroduce an implicit fetch.

## Consequences

- **Buys:** the privacy invariant holds even for hostile course files; studying a
  course emits zero network traffic. Verifiable — see [privacy-model.md](../privacy-model.md).
- **Costs:** remote images in a course don't display (a placeholder shows). Diagrams
  travel as `diagramMermaid` text and equations as LaTeX, so the important visuals
  don't depend on remote assets anyway.
- **Forecloses:** convenient inline web images. If images are ever wanted, they must
  be **embedded** in the `.ohcourse` (e.g. data URIs / bundled assets), never fetched.

## Alternatives considered

- **Render remote images normally:** rejected outright — it's a silent egress and
  tracking vector from untrusted input.
- **Allowlist trusted image hosts:** rejected as premature — any fetch breaks the
  "nothing leaves the device" guarantee and adds trust machinery for little gain.
- **Fetch with consent per course:** deferred; if it ever ships it's an explicit,
  per-course opt-in, decided in its own ADR.
