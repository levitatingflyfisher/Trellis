# AGENTS.md — how to work in this repo

## What this is

The fusion rebuild of the OpenHearth learning line: feature superset of two
donors — **ohPrimer** (`OpenHearth/ohPrimer`, single-file web PWA: reader,
podcasts, on-device ML) and **Trellis** (`OpenHearth/Trellis`, Flutter study
engine). Both donors stay frozen and readable; neither is the future. Read
`VISION.md`, then `docs/adr/0001` for why this chassis.

## Map

```
packages/
  study_core/   Trellis domain VERBATIM + its tests (SM-2 monotonic floor,
                prereq DAG, 4 item types, .ohcourse parser). Pure Dart.
                Do not "improve" the semantics — the tests are the spec.
  loom_core/    Content spine: Work/Segment/Layer/Alignment/Position,
                the cursor law (ADR-0002), ephemera decay, .ohparcel.
                Pure Dart, TDD from scratch.
  comms_core/   Feed/network hygiene: SSRF guard (stricter than donor),
                conditional GET, RSS/Atom, OPML, breaker. HTTP behind a seam.
  intake_core/  EPUB / article-extraction / Gutenberg parsers.
  jobs_core/    Checkpointed-job engine; byte-identical resume law.
  ml_runtime/   Transcriber/Synthesizer/Vad seams, overlap-merge law,
                PINNED model registry (sha256 fail-closed).
  whisper_ffi/  dart:ffi over natives/ whisper.cpp (wfs_ shim ABI).
  transcribe_core/ The 30s/5s pipeline as a ChunkedTask; kill-proven.
  brain_wiring/ Brain tiers (domovoi), AnthropicBrain, Distiller with the
                generated-course-must-parse invariant, discourse grading,
                RecapGenerator (spoiler-safe "Catch me up?" summaries).
  stardict_core/ Pure-Dart StarDict dictionary parser: .ifo/.idx/.dict.dz,
                real dictzip random access (per-chunk inflate, never a
                whole-file decompress). Pure Dart, TDD from scratch.
  backup_core/  .ohbk envelope (appDomain constant renames with the app) +
                both-donor migration. Sanctuary dep is Flutter-bound, so
                its tests run under flutter test.
  skein/        The household daemon (ADR-0005): serves the web build +
                same-origin /api/fetch proxy so the browser tier's CORS
                wall dissolves. Pure Dart, but dart:io by necessity (it's a
                server) — the *_core "no dart:io" law below doesn't apply
                to it; it isn't a *_core package.
app/            Flutter app (pkg name trellis): reader, library, intake,
                feeds/river, player, study, models, transcribe, echo (the
                lifetime-totals/year-in-review screen). Drift schema
                versioned with migration tests.
docs/research/  The design panel's full output. Treat as provenance, not law.
```

## Laws

- **TDD, strictly.** Watch the test fail first. The donor feature inventories
  (`docs/research/inventory-*.md`) are the parity checklist — 59 + 23
  features, each needs a home or an honest "degraded/dropped" entry in
  `docs/reference/feature-matrix.md`.
- **Pure packages stay pure.** No Flutter, no Drift, no dart:io in
  `*_core` packages (dart:typed_data is fine). Storage and platform are
  adapter concerns.
- **Sovereignty laws are tests** (ADR-0003). If you add a timer that calls
  the Brain, the suite must fail.
- **Commit convention:** atomic, message states the *why*, author is the
  neutral persona. No AI-attribution trailers, ever. Never commit `CLAUDE.md`
  or `docs/superpowers/`.
- **Naming:** app-level naming ("Espalier") is provisional until the owner
  confirms; that's why internal packages carry no app name. The
  applicationId decision (ADR pending) is irreversible — do not invent one.

## Building

Pure packages: `dart test` inside the package. App/FFI phases are not
scaffolded yet; the natives plan (whisper.cpp via the Android SDK's own
cmake/NDK) is in `docs/research/proposal-2.md`.
