# Feed archives: why episodes go missing, and what actually gets them back

A listener who subscribes to a long-running podcast often sees only its
newest few years of episodes, with no way to reach older ones from inside
Trellis. The cause is almost never a Trellis bug: most podcast hosts cap
the RSS document itself at the newest N items (N is host-chosen — often
somewhere between 100 and 300 — and undocumented per feed), so the older
episodes were never in the document Trellis fetched. [RFC 5005](https://www.rfc-editor.org/rfc/rfc5005)
defines the standard escape hatch — a feed can publish a `rel="next"` (or,
for a fully archived feed, `rel="prev-archive"`) link pointing at the next
older page of the same feed, letting a client walk backward through the
full history a page at a time. `comms_core`'s parser reads this link when a
host publishes it (`ParsedFeed.nextPageUrl`), and `walkFeedArchive` follows
the chain, capped at 25 pages, on the explicit "Fetch older episodes"
action in the feed detail screen — never silently, and never as part of a
normal refresh.

The honest limit: almost no host publishes it. Nothing in this repo's donor
inventories, prior code, or prior tests (ohPrimer's `rebuild/`, Trellis's
own donor, `docs/research/inventory-*.md`) names or exercises RFC 5005 in
any form — searched before this feature existed, there is no positive
evidence of it anywhere in this project's history. That tracks the wider
ecosystem: RFC 5005 dates to 2007, sits behind a handful of large blogging
platforms and feed generators that opted in, and the podcast-hosting
majority (Libsyn, Buzzsprout, Simplecast, Anchor/Spotify for Podcasters,
and the rest) generally does not emit it. So the archive-walk action will
be invisible on nearly every feed a listener follows — the feed detail
screen's calm fallback line ("The publisher's feed offers only these
episodes — older ones aren't published in it.") is the path almost
everyone will actually see, and that is stated as the honest default, not
a hidden regret.
