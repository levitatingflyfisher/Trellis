# Architecture Decision Records

An ADR captures **one architectural decision**: the context that forced it, the
choice made, and the consequences we accepted. They are immutable once accepted — if
a decision is revisited, add a *new* ADR that supersedes the old one (and mark the
old one `Superseded by ADR-NNNN`) rather than editing history.

Read these when you're about to change something load-bearing and want to know
whether you're fixing a mistake or unknowingly reopening a settled trade-off.

## Index

| # | Decision | Status |
|---|---|---|
| [0001](0001-local-first-no-accounts.md) | Local-first, no accounts, no server | Accepted |
| [0002](0002-shared-preferences-storage.md) | `shared_preferences` for storage now; Drift deferred | Accepted |
| [0003](0003-ohcourse-shared-contract.md) | `.ohcourse` is a versioned, validated contract | Accepted |
| [0004](0004-retrieval-first-sm2.md) | Retrieval-first, cue-laddered items; SM-2 for v1 | Accepted |
| [0005](0005-no-remote-fetch-from-courses.md) | Never fetch from untrusted course content | Accepted |
| [0006](0006-native-secondary-to-ohprimer.md) | Flutter Trellis is secondary to the ohPrimer PWA | Accepted |
| [0007](0007-encrypted-backup.md) | Encrypted backup via the shared `sanctuary_*` packages | Accepted |

## Writing a new one

Copy [`0000-template.md`](0000-template.md) to the next number, fill it in, add a row
above. Keep it to ~one screen — an ADR that needs scrolling is two ADRs.
