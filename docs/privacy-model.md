# Privacy model

Trellis is built so the honest answer to "what leaves my device?" is **nothing,
unless you deliberately push it out.** This page says exactly what that means and how
to check it yourself. (Law 1 applies: the code was AI-authored — so this page tells
you how to *verify*, not just trust.)

## What data exists

| Data | Where it lives | Leaves the device? |
|---|---|---|
| Imported courses (`.ohcourse` JSON) | `shared_preferences`, on-device | No |
| Bundled courses | `assets/courses/` in the app | No |
| Study progress (per-item SM-2 `CardState`) | `shared_preferences`, on-device | No |
| WPM / UI preferences | in-memory / on-device | No |
| Recovery phrase / derived encryption keys | OS keychain (`flutter_secure_storage`), on-device | No |
| Encrypted `.ohbk` backup file | wherever *you* save/share it (see below) | Only when you export it, and only as ciphertext |

There is **no account, no user id, no server, and no telemetry.** The app performs
**no network requests of its own** for any core function.

## The only ways anything leaves the device

All are **user-initiated and explicit** — nothing is automatic or background:

1. **Anki export (native only).** When *you* tap "Export to Anki," the app builds an
   `.apkg` file locally and hands it to the OS **share sheet**. Where it goes next is
   your choice in that share sheet; the app itself uploads nothing.
2. **Exporting an encrypted backup.** When *you* tap "Export backup" (the lock icon
   → Backup & Restore), the app builds a **ChaCha20-Poly1305-encrypted** `.ohbk` file
   locally — under a key derived from a 12-word recovery phrase only you hold — and
   hands it to the OS share sheet, same as Anki export. Nobody without your phrase can
   read it, including whoever it's shared through. See
   [ADR-0007](adr/0007-encrypted-backup.md).
3. **Importing a course** or **restoring a backup file** brings data *in* — a file
   you chose. Course imports are validated before storing (see below); backup restores
   are decrypted locally and never touch the network either.

That's the complete list.

## The encrypted-backup dependency, honestly

Encrypted backup is built on `sanctuary_auth_core`, a shared OpenHearth package.
That package's *own* dependency tree includes `http` and a `SyncService` — because it
also implements a cross-device sync tier for apps that want one. **Trellis never
instantiates that sync tier or the `http` client it needs.** The `flutter analyze` /
`pubspec.yaml` dependency list will show `http` and `flutter_secure_storage` after
this feature; the former is dead weight for Trellis's purposes (only the keychain
wrapper and the local encrypt/decrypt primitives are used), not a live network path.
Encrypted backup here is **local-file only**: out via the share sheet, in via the
file picker, zero network — exactly like Anki export was before it.

## The tracking vector we deliberately closed

Course markdown is **untrusted input** (you may study a file someone else wrote or
shared). A naïve markdown renderer turns `![](https://…)` into a live network fetch —
a silent outbound GET that leaks *when and from where* you're studying and could be
used as a tracking beacon. Trellis renders such images as a **placeholder icon and
never fetches them** (`lib/core/markdown.dart`; [ADR-0005](adr/0005-no-remote-fetch-from-courses.md)).
So even a hostile course file cannot make the app phone home.

## Malformed / hostile course files

Import is **strict and all-or-nothing**: the parser version-gates, type-checks,
enforces referential integrity, and rejects prerequisite cycles, throwing a
path-qualified error the UI shows. A corrupt *stored* course or card blob is skipped
rather than allowed to crash the library or a study session. A bad file can't
silently half-load.

## How to verify this yourself

- **Read the dependency list** (`pubspec.yaml`): there is no analytics, ads, crash-
  reporting, or account SDK. The networking-capable packages (`sqlite3`, `crypto`,
  `archive`, `path_provider`, `share_plus`, `file_picker`) are used **only** for local
  Anki/backup export and OS sharing — grep `lib/` to confirm none of them run in the
  core loop. `sanctuary_auth_core` pulls in `http`, but grep its consumer,
  `lib/features/sanctuary_backup/`, and `lib/main.dart`'s provider overrides: only
  `sanctuaryAppDomainProvider`, `sanctuaryBackupConfigProvider`, and
  `backupSerializerProvider` are touched — the package's `syncServiceProvider` (the
  one thing that would actually use `http`) is never referenced.
- **Watch the network** while studying, importing, exporting, or restoring a backup
  (device network inspector / a proxy): every one of those flows emits **zero**
  outbound traffic — encryption and decryption both happen entirely on-device.
- **Search the source** for HTTP clients: the app has no `HttpClient`/direct `http`
  usage in its own code; the markdown `imageBuilder` proves the one obvious fetch site
  is stubbed to a placeholder.

## If sync is ever added

It isn't today, and there are no plans that compromise this posture. Any future sync
must be **opt-in** and travel as **encrypted blobs through a dumb relay** — never a
BaaS, never plaintext, never on by default ([ADR-0001](adr/0001-local-first-no-accounts.md)).
It would get its own ADR and an update to this page.
