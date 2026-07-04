# ADR-0001: Local-first, no accounts, no server

- **Status:** Accepted
- **Date:** 2026-07-03 (documenting a decision load-bearing since the first release)

## Context

Trellis holds two kinds of user data: the courses you import and your *study
progress* — what you've learned, how well, and what's due. That progress is personal
and revealing (it's a map of what you don't yet know). The default industry answer is
an account and a cloud sync, which turns a study tool into a data-collection surface
and makes it useless offline. OpenHearth's whole thesis is the opposite: software
that serves the household without harvesting it.

## Decision

The app is **local-first and account-free**. Concretely:

- All state — imported courses and per-item SM-2 `CardState` — lives on the device
  in `shared_preferences`. Bundled courses ship in `assets/courses/`.
- There is **no login, no user identity, no server**. The app makes **no network
  calls of its own** for any core function.
- Any future sync must be opt-in and travel as **encrypted blobs through a dumb
  relay** — never a BaaS (Firebase/Supabase/Auth0), never plaintext.

## Consequences

- **Buys:** full offline operation; zero attack surface for account/data breaches;
  nothing to track the user *with*; instant startup; a privacy story you can verify
  by reading the dependency list. See [privacy-model.md](../privacy-model.md).
- **Costs:** no cross-device continuity out of the box; progress is scoped to the
  install (uninstall loses it unless separately exported).
- **Forecloses:** analytics, "sign in to sync," server-side course hosting. Adding
  any of them reopens this ADR.

## Alternatives considered

- **Account + cloud sync:** rejected — it's the exact data-collection posture
  OpenHearth exists to avoid, and it breaks offline use.
- **Anonymous cloud backup:** deferred, not adopted. If it ever ships it must be the
  encrypted-blob-through-a-dumb-relay pattern, decided in its own ADR.
