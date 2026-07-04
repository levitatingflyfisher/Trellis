# Trellis — White Paper

*Why a native reader for durable memory, alongside a web one: the case for the
Flutter surface of the Trellis knowledge engine.*

**Status:** conceptual/strategic overview. For the invariants see
[VISION.md](../VISION.md); for the mechanics, [architecture/OVERVIEW.md](architecture/OVERVIEW.md);
for the format, [curriculum-format.md](curriculum-format.md). This document is honest
about the line between what is built and what is aspirational — see §6.

---

## Abstract

Knowledge tools overwhelmingly optimize *consumption*: read faster, summarize,
highlight. The durable gains, though, come from *retrieval* under *spacing* and
*desirable difficulty*. The Trellis knowledge engine is built on that inversion —
courses are prerequisite graphs of concepts, each drilled by a cue-laddered recall
loop on an SM-2 schedule. The engine ships as a shared file format (`.ohcourse`) and
more than one reader. Its **primary** reader is **ohPrimer**, a progressive web app.
This paper makes the case for the **secondary, native (Flutter)** reader — this repo
— and is precise about what a native surface buys that the web cannot, while keeping
both honest to the same local-first ethos.

## 1. The problem

Two problems, really. The pedagogical one: most study software helps you *feel*
productive (re-reading, highlighting) while doing little for durable memory. The
distribution one: the fix — spaced retrieval — is usually delivered by cloud apps
that require an account and treat your learning history as data to collect. A record
of what you *don't yet know* is intimate; renting it to a server is the wrong default.

## 2. The idea

**Make retrieval the product, and keep it local.** A course is a dependency graph of
concepts; each concept is read fast (RSVP intake) and then *recalled* up a difficulty
ladder (cloze → free generation), with SM-2 spacing the reviews and prerequisite
mastery gating what unlocks next. The whole thing runs on-device with no account and
no network of its own. The unit of sharing is a **file**, not a service.

## 3. Two readers, one format

The engine deliberately separates *authoring*, *format*, and *reading*:

- **Authoring** is an external skill (`trellis-author`): source-or-topic → researched
  concept graph → intake passages → recall ladder → a validated `.ohcourse`.
- **The format** (`.ohcourse`, versioned JSON + JSON Schema) is the contract. It is
  diffable, self-contained, provenance-carrying, and — crucially — read by more than
  one app.
- **Reading** is done by ohPrimer (PWA, primary) and by this native app (secondary).

Keeping the *format* as the seam is what lets the two readers coexist without
becoming a fork: author a course once, study it identically anywhere. See
[ADR-0006](adr/0006-native-secondary-to-ohprimer.md).

## 4. Why a native surface at all

If the PWA is primary, why build and maintain a native app? Because a handful of
things a durable-memory reader wants are exactly the things a web app does poorly:

- **Dependable offline + on-device store.** A study habit can't be hostage to
  connectivity or to a browser evicting local storage. A native app owns its storage
  and runs the same on a plane as on the couch.
- **Precise, jank-free RSVP timing.** Word-level presentation at up to 800 WPM with
  punctuation-weighted dwell wants a tight, native frame loop; it's where the web is
  weakest and the reading experience is most sensitive.
- **First-class OS integration.** Native **file import** of `.ohcourse` files and the
  OS **share sheet** for sending a deck onward — smoother than the browser's clumsier
  equivalents.
- **Anki `.apkg` export.** Building a real Anki package needs a local SQLite database
  and zip packaging (`dart:io` + `sqlite3`) — genuinely native, and it lets Trellis
  interoperate with the largest existing spaced-repetition ecosystem instead of
  competing with it. (It's hidden on the web build for exactly this reason.)
- **A sideloadable APK.** A file you install and own, no store account required — the
  household-friendly distribution the portfolio favours.

None of these change the *loop*; they change how reliably and pleasantly you can live
inside it every day.

## 5. Positioning: a reader, not the engine

The temptation for any app in a multi-surface product is to quietly become the
canonical one. This app resists that on purpose. It does **not** author courses, it
does **not** own the format, and it is **not** where format or loop decisions get
made — those belong to the shared contract and to ohPrimer. Its job is to be the best
*native* place to study an `.ohcourse`, and to stay format-compatible so the "author
once, study anywhere" promise holds. That restraint is the whole reason two readers
can exist without rotting into two incompatible products.

## 6. What is built, and what is not

A white paper that overclaims is marketing. Honestly, as of v1.0.0:

**Built, tested, load-bearing:** the full loop — import + validate an `.ohcourse`
(version-gated, referential-integrity + cycle checked), browse the concept map
(mastery, prerequisite locks, due counts), study a node (RSVP intake with ORP pivot →
cue-laddered recall → grade → SM-2 schedule → mastery unlock). The parser, SM-2
scheduler, grading, and progress/unlock math are pure and unit-tested; screens have
golden tests. Anki `.apkg` export works on native targets. A real Kalman-filter /
multi-target-tracking course is bundled. Builds to APK and web. It runs fully
offline, with no account and no network of its own.

**Aspirational — documented, not code:** **Drift/SQLite** persistence (the code is
shaped for it behind repository seams; storage is `shared_preferences` today);
**FSRS** scheduling; **in-app source download / "research more"**; **animated (Manim)
intake** and **image-occlusion cloze**; and the **shareable curriculum marketplace**.
Sync of any kind is deliberately absent; if it ever ships it's encrypted-blob-through-
a-dumb-relay, never a BaaS. The honest boundary: this is a solid *reader* of a shared
format, not the engine, and not yet a network for sharing what it reads.

## 7. Why it's worth doing

Because the durable-memory loop deserves a home you can trust and rely on: one that
works offline, keeps your learning history on your own device, interoperates with
Anki instead of locking you in, and installs as a file you own. The web reader
reaches the most people with zero friction; the native reader is for the person who
studies every day and wants it *solid*. Same loop, same format, two honest surfaces.

---

## References

- Roediger, H. L. & Karpicke, J. D. (2006). *Test-Enhanced Learning.* — the testing
  effect this design is built on.
- Cepeda, N. et al. (2006). *Distributed practice in verbal recall tasks.* — the
  spacing effect.
- Wozniak, P. (1990). *SuperMemo-2 (SM-2) algorithm.* — the v1 scheduler.
- The FSRS project — the documented productionization path for scheduling.
- Diátaxis (Procida, D.) — the framework this project's [docs](README.md) follow.

*The code and comments referenced here were authored by an AI assistant and describe
what currently exists — take them with gratitude and a grain of salt, and verify
before relying.*
