# How to run the Skein

Skein is a small daemon (`packages/skein`) that serves the Trellis web
build on your own machine and fetches web pages on the app's behalf, so the
browser tab and its fetcher share one origin. That's what lets the reader
pull in a Substack essay, a feed, or a Project Gutenberg book from the
browser tier — things a plain browser tab can't do, because most sites
refuse a cross-origin script's read (see ADR-0005 for why, and what this
deliberately does not solve yet: reaching Skein from a phone or another
machine on the LAN).

## Build the web artifact

From `app/`:

```
flutter build web --base-href /Trellis/
```

This is the exact same build gh-pages already serves — Skein reuses the
artifact, it doesn't need its own build.

## Run Skein

From `packages/skein/`:

```
dart run skein --web-root ../../app/build/web
```

Skein binds `127.0.0.1` only — there is no flag to widen that — and prints
the address it's serving. Open it in a browser **on this same machine**:

```
http://localhost:4664/Trellis/
```

(`--port` picks a different port if 4664 is taken; `stove`, the household
Brain daemon, owns 4663.)

## What works there that doesn't in a plain browser tab

- Pasting a URL into "From the web" fetches directly, same as the installed
  app — no CORS refusal, no proxy.
- Project Gutenberg search *and* the book download both work (in a plain
  browser tab, only the search does — gutenberg.org's book files refuse the
  read).
- Feed subscription and refresh work against sites that block a bare
  browser read.
- The PWA installs and its service worker registers normally: `localhost`
  is a secure context by browser specification, so this needs no
  certificate.

## What still doesn't

- Local on-device transcription, translation, and TTS beyond system
  speech — the web tier's ML story is unchanged by Skein (VISION's
  horizons: the transformers.js-v4 tier is a separate, later fix).
- Reaching this from a phone or another machine on the LAN. Skein binds
  loopback only; `http://<this-machine's-lan-ip>:4664/` will not connect,
  and even if binding were widened, plain HTTP over a LAN address is not a
  secure context — no service worker, no install. That tier is an open
  problem (ADR-0005), not a missing flag.

## What leaves your device

Nothing that a plain fetch wouldn't already have sent — Skein changes
*where* a request originates from (your own machine, not a stranger's
proxy), not *what* it sends. Every URL you fetch through Skein still goes
straight to that site, same as the installed app; Skein never contacts
anything else, keeps no request log, and the daemon refuses any request that
didn't originate from this machine — that's what "binds loopback only"
means in practice. Podcast audio never routes through Skein at all: your
browser plays it directly, the same way it always could.
