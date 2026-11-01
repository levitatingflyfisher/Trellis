# ADR-0003: Attention sovereignty is a set of laws with tests, not a tone

- Status: Accepted
- Date: 2026-08-05

## Context

The commission names the memetic red-queen race (Zvi Mowshowitz, "Things Out
To Get You") as the adversary: modern media is optimized to convert your
attention into someone else's metric. An app that merely *feels* calm loses
that race the first time a well-meaning feature ships a hook. Per the fleet's
prime directive, every value is worth exactly the test that fails when it
stops being true.

## Decision

Seven laws. Where a law is expressible as a test, the test is the law.

1. **The river is reverse-chronological only.** No ranking code path exists —
   there is nothing to A/B, nothing to tune, nothing to test but ordering.
   **Amended 1.5.4:** search answers in fixed sections, each newest first
   (see "Search sections" below). That is not a ranking.
2. **Ephemera decay by default; works persist.** Promotion requires the
   user's hand. (Sweep behavior tested in `loom_core`.)
   **Superseded by [ADR-0019](0019-latest-is-a-permanent-archive.md):**
   nothing decays; Latest is a permanent archive.
3. **Sessions are bounded.** A study session declares its size before it
   starts and has an end screen. No infinite queue exists.
   The podcast Queue is not a study session and is bounded another way: the
   person fills it by hand, and it ends. Going on to the next entry, and
   taking an episode off once it is played or marked played, serve that
   choice. What fills a queue stays the person's hand alone.
4. **The Brain never runs unprompted.** Every inference has a user gesture in
   its call graph (tested: no Brain call reachable from timers or boot).
   **Amended 1.6.x, owner, 10 November 2026: "Yes, for shows I pick":** a
   show's own switch, "Make new episodes in <language> ahead", is a standing
   gesture for on-device transcription, translation and speech, for that
   show alone, for episodes that arrive after it was switched on, on Wi-Fi
   while charging. It is one narrow exception, never a door for anything
   else. The Brain itself (an LLM, anything taking `UserGesture`) is never
   reachable from it. See [ADR-0021](0021-make-ahead.md).
   `test/features/listen/make_ahead_line_test.dart` fails if a show with no
   switch is made ahead; `make_ahead_sovereignty_test.dart` fails if the
   listen feature or the background check can reach the Brain.
5. **No streaks, no leaderboards, no guilt.** v1 ships zero notifications
   except live job progress. Stats are additive lifetime totals.
6. **One egress chokepoint.** Cloud LLM, web-surface proxies, and model
   downloads all pass one consent gate with a WeatherGlass-style "what leaves
   your device" screen. Local/LAN endpoints are exempt by definition.
   **Amended 1.5.5:** a link shared into Trellis from another app (the
   Android share sheet) is fetched without a second dialog. The share
   itself names the one address that leaves the device and is the
   person's own gesture, so it is the consent. The SSRF guard still runs
   first, and nothing beyond that one page is fetched; following a feed
   still takes its own tap.
   **Amended 1.6.x (ADR-0021):** switching a show on to make ahead asks
   once, on the same consent sheet, for every model that language needs.
   Without that yes it never fetches a model; a no leaves the switch off.
   The episode's own audio comes with the switch, on Wi-Fi only.
7. **The permission surface is a test** (conformance C4, both directions,
   release merged manifest): INTERNET, FOREGROUND_SERVICE(dataSync,
   mediaPlayback), POST_NOTIFICATIONS, WAKE_LOCK — and nothing else.

## Search sections (1.5.4)

Search used to be one newest-first list cut at 100 rows. A word in a
long-followed show's name filled the list with that show's newest
episodes, and the title match being looked for sat past the cut with no
sign it existed. The fix is placing, not scoring. Results fall into
fixed sections by where the words were found:

- **Shows**: followed shows by name, in shelf order;
- **In titles**: the work's title, or an episode's show name;
- **In the text**: its show notes, a post's text or an episode's
  description, or words split between those and the title;
- **Said in**: transcript sentences, of any work.

Each section of works is newest first; every section says its true count
and pages through every row ("Show all N"). A work is listed in its
first section only among Shows, In titles and In the text; Said in lists
every matching sentence, even of a work found above, since the jump to
the sentence is the point. Law 1 holds because nothing is scored: the
section a row lands in is a fact about the row (does the title hold
these words?), the same for every user and every query, with nothing to
weigh or tune. A relevance score (`bm25`) was considered and refused for
the reason law 1 exists.

## Consequences

- Some growth mechanics are simply unavailable to this product, forever.
  That is the point.
- Positive framing: progress is shown as what has been built (lifetime rings,
  ripening fruit on the wall), never as what would be lost by stopping.
- Law 7 means the APK cannot claim the fleet's no-INTERNET badge — podcasts
  and model downloads need the network. The narrow, named permission list is
  this app's version of the same discipline.
