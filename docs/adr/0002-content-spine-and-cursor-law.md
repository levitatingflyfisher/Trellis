# ADR-0002: One content spine; positions never reference a modality

- Status: Accepted
- Date: 2026-08-05

## Context

The commission's hardest requirement: "read, listen to, study anything, from
any language/format to any other, stop, pick it up again in the other format,
continue." Both donors failed this structurally — ohPrimer stored positions
as word indexes inside per-book records (rewriting the whole multi-MB record
on autosave) and bolted translations onto book blobs; Trellis had no media at
all.

## Decision

Every source — podcast episode, article, EPUB chapter, feed item, pasted
text, distilled course intake — normalizes to one shape:

```
Work       identity, kind, source, language, persistence{work|ephemeron}
Segment    the atom: sentence/block-level, ordered, typed (prose/heading/code/table/figure)
Layer      per-segment text in a language, with provenance (original|transcript|mt|human)
MediaAsset audio/video file reference
Alignment  segment ↔ [tStart,tEnd] in a MediaAsset, word timings best-effort
Position   (profile, work) → (segmentIdx, wordIdx, lastModality)
```

**The cursor law (the spine invariant, enforced by test):** a `Position`
never references a modality or a language. Renderers *project* it — RSVP
projects (segment, word); the audio player projects through `Alignment`; a
translation layer projects the same segmentIdx in another language. A format
switch moves zero data; it reads the same row.

**Ephemera decay (sovereignty by structure):** feed items and unpromoted
episodes are `ephemeron` and are swept after a default 30 days. Promotion to
`work` requires the user's hand (extract, pin, or finish). Works persist.

**Cuttings (`.ohparcel`):** the spine serializes to a shareable bundle
(work + segments + layers + alignments + optional course, content-hashed) so
any stronger device can bake the full bilingual experience for any weaker
one.

## Consequences

- Position saves are one tiny row — the donor's rewrite-the-book jank is
  structurally impossible.
- Translations are per-segment layers, so partial translation, mixed
  provenance, and language switching mid-work are all natural.
- Word-level alignment is best-effort by contract (upstream timestamp drift
  on non-English audio); sentence-level is the guarantee. UI copy must
  respect this.
- The spine lives in a pure-Dart package (`loom_core`) with no Flutter or
  Drift imports; storage is an adapter concern.
