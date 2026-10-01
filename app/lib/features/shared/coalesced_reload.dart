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

/// Lets requests through at most once per [interval]: the first at once,
/// and whatever arrives inside the window folded into one at its end.
///
/// [CoalescedReload] alone starts the next reload as soon as one ends, so
/// a 118-feed import still reloaded Subscriptions back to back for its
/// whole length, every run queued behind the import's own writes. A list
/// a second behind the progress bar is enough to watch it fill.
class RequestThrottle {
  RequestThrottle(this._fire, {this.interval = const Duration(seconds: 1)});

  final void Function() _fire;
  final Duration interval;

  Timer? _window;
  bool _pending = false;

  void request() {
    if (_window != null) {
      _pending = true;
      return;
    }
    _fire();
    _window = Timer(interval, () {
      _window = null;
      if (_pending) {
        _pending = false;
        request();
      }
    });
  }

  /// Drops a folded request and ends the window; for dispose.
  void cancel() {
    _window?.cancel();
    _window = null;
    _pending = false;
  }
}
