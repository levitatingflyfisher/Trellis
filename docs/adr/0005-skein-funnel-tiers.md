# ADR-0005: Skein — a household daemon dissolves the web tier's CORS wall; localhost only in v1

- Status: Accepted
- Date: 2026-08-14

## Context

The feature-matrix's Degraded list and the VISION scorecard both say the same
measured thing (2026-08-12, from the deployed origin): the web tier fetches
directly from the browser with no proxy fallback, by design, and most sites
refuse the read. Nearly every article site (Substack included), Substack RSS,
and gutenberg.org's book files are unreachable from a browser tab — not
because Trellis fails to ask, but because the target site's CORS policy
never invited a cross-origin script to read it, and the browser enforces
that regardless of what Trellis wants.

Every RSS/read-later product that needs to read arbitrary sites from a web
page solves this with a server standing between the page and the target —
a CORS proxy. comms_core already ports the donor's consent-gated public-proxy
ladder (`cors.eu.org`, `allorigins.win`, `codetabs.com`), but it is wired
behind a consent that never grants (feature-matrix, Dropped): routing a
household's reading list and article contents through a stranger's server is
exactly the kind of quiet leak this fleet's privacy-by-default value exists
to refuse. That verdict stands. It does not make the underlying need go
away — a family member who wants to read a Substack essay from the browser
tab still can't, and the honest sentence naming the browser as the reason is
a good citizen, not a solved problem.

The one server a family can route through without it being a leak is a
server the family owns. The household already keeps a desktop or a homelab
box for `stove` (DomovoiDiscernment's household-Brain daemon, port 4663).
The same shape of answer works here: a small daemon on that machine that (a)
serves the Trellis web build itself and (b) fetches on the page's behalf.
Once the page and its fetcher share one origin, CORS does not need defeating
— it was never in the way of same-origin requests to begin with.

## Decision

**Skein** (`packages/skein`, pure Dart, no Flutter): a daemon that binds
`127.0.0.1` only — no flag widens it — and serves two things from one
process:

1. **The web build**, at the exact artifact shape `flutter build web
   --base-href /Trellis/` already produces for gh-pages. One build serves
   both destinations; there is no second build target to keep in sync.
2. **`/api/fetch?url=...`**, a same-origin proxy: the app's `DioHttpFetcher`
   rewrites its outgoing GETs to this relative path instead of the target
   URL directly, so the browser sees a same-origin request start to finish.

The SSRF guard (`comms_core`'s `assertSafeFetchUrl`) runs on the requested
URL and is re-run on every redirect hop the upstream server sends back — a
public site cannot use the daemon to read the family's own router or a
sibling machine on the LAN by bouncing a 3xx off it. The proxied body is
capped (32 MiB — documents and EPUBs, never media: podcast audio plays
directly through the browser's `<audio>` element, which needs no CORS at
all, so it never touches this daemon or its cap). Every failure is a JSON
sentence with an honest status code, matching ADR-0003's tone law.

**v1 is the localhost tier only.** The desktop browser is the family's
top-of-funnel surface for Trellis, and `localhost` is a secure context by
browser specification — the service worker and PWA install both work with
zero certificate ceremony the moment Skein is running. A phone or another
machine on the LAN cannot reach `127.0.0.1` on the desktop by definition, so
this tier does not extend to them; they keep the APK, which fetches
natively and was never CORS-bound to start with.

The app probes for a live Skein once at boot: a relative, same-origin
`GET /api/health` (deliberately outside the SSRF guard — a fixed relative
path is not an attacker-controlled URL, so there is nothing for that guard
to check). The result — `WebFetchLane.direct` or `WebFetchLane.skein` — is
cached for the session and threaded to the two web-only intake doors the
same way `DeviceServices.localMlAvailable` already reaches the doors that
must not offer what would fail: they swap their CORS-refusal warning for a
quiet "Fetching through your Skein on this computer" line, and never show
both.

## Security: closing the DNS-rebinding gap in the SSRF guard

`assertSafeFetchUrl` is lexical: it parses the host string and cannot see
DNS. A public-looking hostname a site controls can resolve to `127.0.0.1`
or a LAN address and sail straight past it — the classic rebinding attack
against a server-side fetcher, and Skein is the first consumer of this
guard that runs server-side rather than in a sandboxed browser tab. Skein
adds a second, resolve-time layer on top (comms_core itself is untouched):
after the lexical guard passes, the hostname is looked up and every
returned address is classified — loopback, link-local, RFC1918 private,
unique-local IPv6, unspecified, and the IPv4-mapped IPv6 forms of each are
all refused. To close the TOCTOU window between that check and the actual
connection (a second lookup could answer differently), the outgoing socket
is pinned to the exact checked address via `HttpClient.connectionFactory`,
preserving the original hostname for the Host header and, for HTTPS, for
SNI and certificate verification — verified by hand against a real
self-signed certificate server (a positive case proving the pin still
delivers a valid response, and a negative control proving verification
really targets the original hostname and not the connected IP, since
pointing it at the IP instead correctly fails). What remains open: the
classification list, while broad, is not exhaustive of every RFC 6890
special-purpose range, and a resolver that itself lies inside the pinning
window (a compromised or adversarial DNS resolver, as opposed to ordinary
rebinding) is out of scope — Skein trusts whatever resolver the OS hands
it, same as every other program on the machine.

## Consequences

- The feature-matrix's CORS-bound Degraded entry gains an exception rather
  than being resolved: most browser users are still CORS-bound, and Skein
  is opt-in infrastructure a household chooses to run, not a default.
- The public-proxy ladder in `comms_core` stays wired to a consent that
  never grants (unchanged verdict) — Skein is the family's own server, the
  proxy ladder is a stranger's; they are not the same trade.
- **Open problem, deliberately not solved here: the LAN/phone tier.** A
  phone reaching Skein over the LAN would need `http://<lan-ip>:4664/`,
  which is not a secure context — no service worker, no PWA install, and
  several browser APIs the reader may eventually want are gated on secure
  contexts. Candidate answers exist (`mkcert` for a locally-trusted
  certificate, a public-domain DNS-01 challenge pointed at a LAN address,
  Tailscale's MagicDNS + cert issuance) and none is chosen. This ADR
  records the problem so it is not silently assumed solved; the fix is
  future work, not implied by anything shipped now.
- Podcast audio is explicitly out of Skein's proxy: documenting this in
  code (not just here) matters because the instinct to "just proxy
  everything through Skein for consistency" would spend the byte cap on
  traffic that already works directly.
