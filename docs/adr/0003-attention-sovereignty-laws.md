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
2. **Ephemera decay by default; works persist.** Promotion requires the
   user's hand. (Sweep behavior tested in `loom_core`.)
3. **Sessions are bounded.** A study session declares its size before it
   starts and has an end screen. No infinite queue exists.
4. **The Brain never runs unprompted.** Every inference has a user gesture in
   its call graph (tested: no Brain call reachable from timers or boot).
5. **No streaks, no leaderboards, no guilt.** v1 ships zero notifications
   except live job progress. Stats are additive lifetime totals.
6. **One egress chokepoint.** Cloud LLM, web-surface proxies, and model
   downloads all pass one consent gate with a WeatherGlass-style "what leaves
   your device" screen. Local/LAN endpoints are exempt by definition.
7. **The permission surface is a test** (conformance C4, both directions,
   release merged manifest): INTERNET, FOREGROUND_SERVICE(dataSync,
   mediaPlayback), POST_NOTIFICATIONS, WAKE_LOCK — and nothing else.

## Consequences

- Some growth mechanics are simply unavailable to this product, forever.
  That is the point.
- Positive framing: progress is shown as what has been built (lifetime rings,
  ripening fruit on the wall), never as what would be lost by stopping.
- Law 7 means the APK cannot claim the fleet's no-INTERNET badge — podcasts
  and model downloads need the network. The narrow, named permission list is
  this app's version of the same discipline.
