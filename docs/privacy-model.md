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

There is **no account, no user id, no server, and no telemetry.** The app performs
**no network requests of its own** for any core function.

## The only ways anything leaves the device

Both are **user-initiated and explicit** — nothing is automatic or background:

1. **Anki export (native only).** When *you* tap "Export to Anki," the app builds an
   `.apkg` file locally and hands it to the OS **share sheet**. Where it goes next is
   your choice in that share sheet; the app itself uploads nothing.
2. **Importing a course** brings *in* a file you chose. That's inbound, and the app
   validates it before storing it (see below).

That's the complete list.

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
  `archive`, `path_provider`, `share_plus`) are used **only** for local Anki export
  and OS sharing — grep `lib/` to confirm none of them run in the core loop.
- **Watch the network** while studying (device network inspector / a proxy): a full
  study session — import, RSVP intake, recall, grade, schedule — emits **zero**
  outbound traffic.
- **Search the source** for HTTP clients: the app has no `HttpClient`/`http` usage in
  its core paths; the markdown `imageBuilder` proves the one obvious fetch site is
  stubbed to a placeholder.

## If sync is ever added

It isn't today, and there are no plans that compromise this posture. Any future sync
must be **opt-in** and travel as **encrypted blobs through a dumb relay** — never a
BaaS, never plaintext, never on by default ([ADR-0001](adr/0001-local-first-no-accounts.md)).
It would get its own ADR and an update to this page.
