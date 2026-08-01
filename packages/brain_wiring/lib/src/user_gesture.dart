/// The no-unprompted-inference law, made a type (ADR-0003 law 4:
/// "The Brain never runs unprompted. Every inference has a user gesture
/// in its call graph.")
library;

/// Proof of a human hand.
///
/// Every brain_wiring entry point that leads to a Brain call takes a
/// `required UserGesture userGesture` with no default. The token carries
/// no data — its whole job is to make the law visible at the call site:
/// a timer or boot path that wants inference has to construct one, and
/// that construction is exactly what the app-level sovereignty test
/// (no `UserGesture(` reachable from timers or boot) hunts for.
///
/// Construct it in the widget/CLI layer, in direct response to a tap or
/// command. Never store one, never make one in a scheduler.
final class UserGesture {
  const UserGesture();
}
