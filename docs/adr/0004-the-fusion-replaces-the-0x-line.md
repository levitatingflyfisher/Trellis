# ADR-0004: v1.0 replaces the 0.x line; its ADRs are archived, not carried

- Status: Accepted
- Date: 2026-08-12
- Supersedes: the 0.x repo's ADR-0001 through ADR-0008 (see below for the
  disposition of each)

## Context

Before the fusion, this repository's coordinates
(`levitatingflyfisher/Trellis`) held the 0.x line: the Flutter study-only
reader whose decision record ran ADR-0001 through ADR-0008. Its final entry,
ADR-0008 ("Trellis is the only reader; ohPrimer is retired"), anticipated its
own supersession — the reconciliation plan called for an ADR-0009 once the
fusion design landed. This is that record. It lives in the fusion repo, not
the 0.x repo, because publication replaces the 0.x history wholesale at the
same coordinates; an ADR written into a history about to be replaced would
record nothing.

## Decision

**v1.0 — this repository — is the Trellis line.** The 0.x ADRs are neither
carried nor renumbered here; every decision they made was re-made from first
principles during the fusion design (ADR-0001 here, plus the panel record in
`docs/research/`). Their dispositions:

| 0.x ADR | Disposition in v1.0 |
|---|---|
| 0001 local-first, no accounts | carried — fleet canon, enforced by ADR-0003's laws |
| 0002 shared-preferences storage | superseded — the Drift spine (ADR-0002 here) |
| 0003 `.ohcourse` shared contract | carried — `study_core` consumes it verbatim |
| 0004 retrieval-first SM-2 + monotonic floor | carried — the engine is a verbatim port, donor tests green |
| 0005 no remote fetch from courses | carried as law — courses never carry URLs the app follows |
| 0006 native secondary to ohPrimer | already superseded by 0.x ADR-0008 |
| 0007 encrypted backup | carried — `backup_core` on the real `sanctuary_auth_core`, plus both-donor import |
| 0008 Trellis is the only reader | fulfilled and closed — there is one reader again: this one |

The complete 0.x history (through its final commit `5f47535`) is preserved
offline by the maintainers; the public repository carries the fusion history
only. The 0.x tags and releases (`v0`, `v0-apk`, `pre-superapp`) are removed
from the public repo — a release channel that points at a replaced history is
a trap, not a courtesy.

## Consequences

- Version numbering continues rather than restarting: v1.0 ships
  `versionCode 2004`, one above 0.x's last shipped build, signed with the
  same key, so it installs over a 0.x install as an upgrade.
- 0.x user data survives the crossing: `.ohcourse` files import unchanged,
  and the backup restorer accepts both 0.x Trellis and ohPrimer envelopes.
- Anyone holding a 0.x clone holds a valid, MIT-licensed snapshot of the old
  app; nothing about the replacement revokes it.
