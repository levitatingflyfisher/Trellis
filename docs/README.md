# Documentation

[Diátaxis](https://diataxis.fr/) hub — sections fill in as phases land.

- **Tutorials** — none yet (first: "study a podcast in your target language").
- **How-to** — [run-the-skein.md](how-to/run-the-skein.md): running the
  Skein archive daemon beside the app.
  [convert-a-translation-model.md](how-to/convert-a-translation-model.md):
  turning an upstream Marian model into the app's int8 ONNX pair, the
  recipe ADR-0014's “converted by Trellis” rung requires.
- **Reference** — [feature-matrix.md](reference/feature-matrix.md): every
  donor feature and where it lives here (the "nothing lost" ledger).
  [tts-voices.md](reference/tts-voices.md): the verbatim licensing record
  for every TTS voice considered — checkable, not trusted.
  [mt-models.md](reference/mt-models.md): the same record for every
  translation model evaluated — shipped, demoted, and rejected alike.
  [feed-archives.md](reference/feed-archives.md): why a podcast's older
  episodes go missing (host RSS truncation) and the RFC 5005 archive-walk
  escape hatch, including how rarely a host actually publishes it.
- **Explanation** — [adr/](adr/): 0001 chassis, 0002 content spine + cursor
  law, 0003 attention-sovereignty laws, 0004 v1.0 replaces the 0.x line,
  0005 Skein funnel tiers, 0006 speak mode grows a real voice, 0007 the
  voice goes MIT (Supertonic), 0008 Babel — the translation organ, 0009
  the study crown, 0010 reader depth, 0011 triage & rules, 0012 offline
  DSP, 0013 audiobooks are a door, 0014 Babel widens, 0015 honest feeds +
  the media-session gap, 0016 episodes you can tell apart, 0017 the
  fundamentals pass, 0018 background refresh, 0019 Latest is a permanent
  archive, 0020 translation runs on device, verified, 0021 make ahead,
  for shows the person picks, 0022 Trellis's own voices, one per language. (This list was
  stale by six entries before Campaign 9 caught it, and by four again
  before 1.5.9. Keep it current going forward rather than letting it
  drift again.)
- **Personas**: [explanation/personas.md](explanation/personas.md), who agents
  play when they test the UI, with scenarios.
- **The founding request**:
  [explanation/founding-request.md](explanation/founding-request.md), the
  post that started the translation work, and the flow it makes the main
  case to judge against.
- **Provenance** — [research/](research/): the 12-agent design panel's donor
  inventories, cited ML/UX research, four rival proposals, three judgments.
