# ADR-0007: Encrypted backup via the shared `sanctuary_*` packages

- **Status:** Accepted
- **Date:** 2026-07-12

## Context

Local-first storage ([ADR-0001](0001-local-first-no-accounts.md),
[ADR-0002](0002-shared-preferences-storage.md)) has the same downside every
on-device app has: lose the phone, lose your imported courses and every
day of SM-2 progress against them. A backup must not reintroduce the
account/server model ADR-0001 exists to avoid, so it has to be **encrypted
on the device, under a key only the user holds**, portable as a plain file.

Auth/crypto is security-sensitive code that should be written and audited
once and shared across the OpenHearth fleet, not reimplemented per app —
`sanctuary_auth_core` (the crypto primitives) and `sanctuary_backup_ui` (the
seed-phrase setup / export / restore UI, extracted from Lullaby) already
exist for exactly this.

## Decision

Add Ghost-tier encrypted backup by consuming the two shared packages as
**sibling path dependencies** (the `eloEngine` precedent) and implementing
one interface, `BackupSerializer`, over Trellis's own store.

- **The key** is derived from a 12-word recovery phrase (BIP39 + PBKDF2),
  isolated to this app via `appDomain: 'trellis'` — a fresh app on this
  wave, so it gets its own key material rather than Lullaby's legacy
  household-wide derivation.
- **The payload** is Trellis's *entire* backup-scoped shared_preferences
  state — not a re-derived export — encrypted with ChaCha20-Poly1305 and
  framed as an `.ohbk` file, AEAD-bound to the context `trellis-backup/v1`
  so a blob made for a different app can never decrypt here.
- **Backup scope:** imported courses (content + the `imported_ids` index)
  and SM-2 progress for *every* course with progress, bundled or imported.
  Bundled course content itself is never dumped — it ships inside the app —
  but a user's study history against it is theirs and must survive a
  restore.
- **Restore is destructive**: every key this serializer owns is wiped, then
  the backup's keys are written back — nothing from before the restore
  that isn't in the backup survives. shared_preferences has no cross-key
  transaction, so the write order (course/card data, then the
  `imported_ids` index last) is the honest substitute for the
  single-transaction guarantee a Drift-backed app gets — a reader trusting
  the index never observes an id with missing data. A backup whose schema
  version is newer than the running app understands is rejected outright.
- **No new crypto in this repo.** Trellis calls only
  `sanctuary_auth_core`/`sanctuary_backup_ui` primitives — no hand-rolled
  HKDF/AEAD.

## Consequences

- **Buys:** durable, portable backups with zero server and zero plaintext
  egress; a shared, auditable crypto module instead of a bespoke one; a
  small serializer (~150 lines) instead of a new persistence layer.
- **Costs:** the recovery phrase is unrecoverable if lost — there is no
  reset email, by design. Two more dependencies (`file_picker`, plus the
  two sibling packages) on an app that previously had a very small
  dependency surface; see the [privacy model](../privacy-model.md) update
  for what that does and doesn't change.
- **Forecloses:** server-side key escrow or account-based recovery.
  Recovery is the user's responsibility, mediated only by the phrase.

## Alternatives considered

- **Plaintext export as the only backup:** rejected — study content and
  performance history is low-sensitivity but still the user's own; a
  plaintext dump on disk is a needless liability once an audited encrypted
  path exists for free.
- **In-repo crypto:** rejected — security code belongs in one audited,
  shared place ([ADR-0001](0001-local-first-no-accounts.md) already
  forecloses a bespoke server; the same logic applies to bespoke crypto).
- **Route the serializer through `CourseRepository`/`CardRepository`:**
  rejected in favor of reading/writing `SharedPreferences` directly,
  mirroring Lullaby's serializer working straight against `AppDatabase`
  rather than its filtered per-baby DAOs — a backup dump should be a
  faithful full-store copy, not filtered through a repository built for a
  different (single-course, single-baby) access pattern.
