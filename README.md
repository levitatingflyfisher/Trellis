# Trellis

**Read, listen, study — anything, in any language, on any compute you own.**

One local-first app for a household's whole knowledge diet: a speed-reader
with four modes, a podcast player that transcribes episodes on your own
device (multilingual — including into English via Whisper's translate task),
per-sentence audio↔text↔translation alignment, and the proven Trellis study
engine — concepts on a prerequisite lattice, spaced repetition with a
monotonic-interval guarantee, and discourse-grade recall items.

An espalier is a tree trained on a trellis to bear more fruit in less space.
**You train the tree; the tree never trains you** — reverse-chronological
feeds only, ephemera decay by default, zero engagement optimization, and
every one of those claims is a test, not a promise.

## Status

v1.0. Reader (four modes), EPUB/URL/paste/Gutenberg intake, feeds and
podcasts with on-device multilingual transcription (whisper.cpp aboard
the APK), courses on the Espalier Wall, discourse study over a BYOK
brain, encrypted backup with both-donor migration, and the household
dashboard — all shipped, 374 app tests plus the package suites green.
See [VISION.md](VISION.md) for the honest scorecard (what is not in
v1.0 is listed there just as plainly) and `docs/adr/` for the
decisions.

## The compute ladder

Works on a $90 phone's browser with zero models (read, feeds, full study
engine, import pre-baked parcels). One 40MB download adds on-device
multilingual transcription. The family desktop can do the heavy work for
every phone in the house over LAN — no cloud is ever load-bearing.

## Reading order

`README.md` → [VISION.md](VISION.md) → [AGENTS.md](AGENTS.md) →
[docs/README.md](docs/README.md). Decisions live in `docs/adr/`; the design
provenance (12-agent architecture panel, donor inventories, cited research)
in `docs/research/`.

## License

MIT.
