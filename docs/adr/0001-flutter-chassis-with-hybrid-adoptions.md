# ADR-0001: Flutter-everywhere chassis, with four adoptions from rival designs

- Status: Accepted
- Date: 2026-08-05

## Context

The owner commissioned a first-principles fusion rebuild of the OpenHearth
learning line: a feature **superset** of both donors — ohPrimer (8065-line
single-file web PWA: reader, podcasts, on-device ML) and Trellis (Flutter:
study engine, prereq DAG, 183 tests) — with an honest potato floor,
attention sovereignty by structure, and a working
podcast-in-a-foreign-language path (ohPrimer's Whisper was `whisper-tiny.en`,
English-only: the flagship use case never worked).

A 12-agent design workflow ran: exhaustive donor inventories (59 + 23
features, archived in `docs/research/`), cited research on the 2026
browser-ML landscape, four rival architectures steelmanned by independent
agents (web-sovereign TS · Flutter-everywhere · two-surfaces-one-format ·
hearth-server), judged by three lenses (feasibility, values, craft). Full
proposals and judgments: `docs/research/proposal-*.md`, `judgment-*.md`.

## Decision

**Adopt the Flutter-everywhere proposal ("Espalier") as the chassis.**
The panel voted 2–1 (feasibility + values lenses; craft preferred the TS PWA
by a nose). The decisive, verified arguments:

1. **Structural privacy.** Native fetch is CORS-free: the entire public
   CORS-proxy layer (which leaks reading/listening habits to third parties on
   every browser-based design) vanishes rather than being consent-fenced.
2. **The canonical user's guaranteed path.** A 40-minute multilingual
   transcription on a cheap phone needs whisper.cpp with NEON threads in a
   foreground service — screen-off, checkpointed, resume-on-kill. Every
   browser design honestly conceded a screen-on, wake-locked, COOP/COEP-hack
   multi-hour vigil for the same job.
3. **Four fleet crown jewels are already Dart** and arrive as dependencies,
   not rewrites: the Trellis study domain (pure Dart, zero Flutter imports —
   183 tests land unmodified), sanctuary_auth_core (OHBK), domovoi
   (ResumableTransfer + Brain seam + stove client), oh_fleet_conformance
   (C1–C7).
4. The craft lens's hardest objection — "this box has no cmake/clang" — is
   **refuted**: `androidDevTools/cmake` and the NDK toolchain are present;
   Android FFI builds use the SDK's own tools.

**Adopted from the rivals (mandated by all three judges):**

- **`.ohparcel` "cuttings"** (hearth-server proposal): a shareable bundle of
  {work, segments, layers, alignment, optional course, content-hash
  manifest}. How compute travels to potatoes and iOS — bake on a desktop,
  import on anything, zero local ML needed.
- **Distill-time discourse** (TS proposal): Socratic follow-ups and
  construction prompts are baked *into* the `.ohcourse` at distillation, so
  a zero-ML phone still studies with discourse, no runtime inference.
- **Revlog as a deterministic fold** (hearth-server proposal): every grade is
  an append-only event; scheduler state is a fold over it. Sync-ready,
  FSRS-ready, and auditable.
- **Rootstock as roadmap** (hearth-server proposal): the same app's desktop
  surface grows overnight jobs and stove *serving* — the household vision on
  this chassis, honoring the "server nobody else has to trust" framing.

Plus two judge mandates: pull browser whisper-tiny forward from Phase 6 when
transformers.js-v4 interop is bounded; do not drop OCR silently (roadmap:
household-desktop OCR job).

## Consequences

- The web surface ships **zero local ML at v1.0** — an honest regression
  vs the donor's janky browser Whisper, stated on a "what runs on this
  device" screen; parcels and BYOK are the browser user's compensations.
- We pay the FFI build matrix (whisper.cpp/llama.cpp/Piper/onnxruntime ×
  platforms) forever. Mitigations: pinned submodules, SDK toolchain,
  prebuilt release artifacts, every native behind a pure-Dart seam with
  recorded-fixture fakes so CI never needs the natives.
- Flutter-web boot weight on potato browsers is a real cost (fleet playbook's
  slow-boot spinner applies); the parcel path is the potato's true floor.
- ADR-0008 in the Trellis repo ("Trellis is the only reader") is superseded
  in spirit by this app; a pointer ADR lands there when this ships.

## Alternatives considered

Recorded in full in `docs/research/`. The two-surfaces design re-litigated a
twice-flipped decision (ADR-0006's own recorded failure) and was ranked last
by all three judges. The hearth-server design contributed its best ideas
(cuttings, fold, graft pairing) but stood on a research-grade
browser↔daemon transport and the largest solo scope on the panel. The TS PWA
was the strongest runner-up; its rewrite-mass argument was real, and its
distill-time discourse idea ships here.
