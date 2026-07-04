# ADR-0006: Flutter Trellis is secondary to the ohPrimer PWA

- **Status:** Accepted
- **Date:** 2026-07-03

## Context

The Trellis knowledge engine has more than one reader. There is **ohPrimer**, a
progressive web app, and there is **this** native Flutter app. Both read the same
`.ohcourse` format and run the same retrieval loop. A future maintainer who doesn't
know the relationship will eventually ask the dangerous question — "where does this
feature go?" — and get it wrong, forking the format or duplicating the loop in two
places that then drift apart. This ADR pins the answer.

## Decision

**ohPrimer (the PWA) is the primary, unified surface of the Trellis line. This
Flutter app is the secondary, native surface.** The **`.ohcourse` format is the
shared contract** and the seam between them.

- Changes to the *format* or the *core loop's semantics* belong to the shared
  contract (and land in ohPrimer), not forked into this repo.
- This app exists for what a **native** package buys over the web: dependable offline
  use and on-device storage, precise RSVP timing, native OS **share**, file import,
  and **Anki `.apkg` export** — things a PWA does poorly or not at all. That's the
  case made in the [white paper](../whitepaper.md).
- A course authored once must study **identically** in either reader. Keeping the
  two in lockstep on `schemaVersion` is a first-order maintenance duty.

## Consequences

- **Buys:** a clear home for every kind of change; no silent divergence; honest docs
  a newcomer can trust about which surface is canonical.
- **Costs:** two codebases to keep format-compatible; native-only features (Anki
  export) live here and aren't part of the "unified" surface.
- **Forecloses:** treating this repo as the canonical product, or evolving the format
  here without upstreaming it.

## Alternatives considered

- **Flutter app as the single canonical product:** rejected — the PWA reaches more
  people with zero install and is where the line's centre of gravity sits.
- **Web-only (drop the native app):** rejected — offline reliability, native share,
  and Anki export are real reasons a household wants the installed app.
- **Fork the format per reader:** rejected — it destroys the "author once, study
  anywhere" property that makes the format worth having.
