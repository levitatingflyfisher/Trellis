import 'dart:async';

/// Runs a screen's reload at most once at a time, folding every request
/// that arrives mid-run into a single follow-up run.
///
/// An OPML import reports progress once per feed; reloading on each beat
/// stacked a hundred overlapping reads (and their per-feed disk checks) on
/// the UI isolate and froze the import. Each caller's future still
/// completes only after a reload that *started after* its request, so
/// nobody acts on data older than what they asked for.
class CoalescedReload {
  CoalescedReload(this._reload);

  final Future<void> Function() _reload;

  Future<void>? _running;
  Completer<void>? _next;

  Future<void> request() {
    if (_running == null) return _start();
    return (_next ??= Completer<void>()).future;
  }

  Future<void> _start() {
    final run = _reload().whenComplete(() {
      _running = null;
      final next = _next;
      _next = null;
      if (next != null) next.complete(_start());
    });
    return _running = run;
  }
}
