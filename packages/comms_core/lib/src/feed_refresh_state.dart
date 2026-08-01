/// The per-feed refresh bookkeeping (donor refreshFeeds, index.html
/// ~5862–5902) as a pure state machine. The caller owns persistence and the
/// clock; this file owns the transitions:
///
/// - inside the throttle window → skip (unless forced)
/// - broken → skip (unless forced)
/// - notModified → failures reset
/// - throttled → window recorded (`now + retryAfter`)
/// - notFound (404/410) → broken immediately
/// - error → failures + 1; broken at 5
/// - fresh → everything reset, validators/title adopted
/// - fresh body that fails to parse → [applyParseFailure]: failures + 1,
///   broken at 5, lastChecked stamped (the server did answer)
///
/// Deliberate donor deviation: in the donor, a fresh body that failed to
/// PARSE threw past all bookkeeping — a persistently unparseable feed never
/// tripped the breaker and never stamped lastChecked. Here callers route
/// that case through [applyParseFailure] so it eventually breaks.
library;

import 'feed_fetch_result.dart';

class FeedRefreshState {
  const FeedRefreshState({
    required this.url,
    this.title = '',
    this.etag,
    this.lastModified,
    this.consecutiveFailures = 0,
    this.broken = false,
    this.lastError,
    this.throttledUntilMs,
    this.lastCheckedMs,
  });

  final String url;
  final String title;
  final String? etag;
  final String? lastModified;
  final int consecutiveFailures;
  final bool broken;
  final String? lastError;

  /// Epoch millis until which the feed is throttled (donor throttledUntil).
  final int? throttledUntilMs;

  /// Epoch millis of the last successful contact (donor lastChecked — not
  /// stamped on fetch failures; parse failures DO stamp it, the server
  /// answered).
  final int? lastCheckedMs;

  FeedRefreshState copyWith({
    String? title,
    String? etag,
    String? lastModified,
    int? consecutiveFailures,
    bool? broken,
    String? lastError,
    bool clearLastError = false,
    int? throttledUntilMs,
    bool clearThrottledUntil = false,
    int? lastCheckedMs,
  }) {
    return FeedRefreshState(
      url: url,
      title: title ?? this.title,
      etag: etag ?? this.etag,
      lastModified: lastModified ?? this.lastModified,
      consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
      broken: broken ?? this.broken,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      throttledUntilMs:
          clearThrottledUntil ? null : (throttledUntilMs ?? this.throttledUntilMs),
      lastCheckedMs: lastCheckedMs ?? this.lastCheckedMs,
    );
  }
}

enum RefreshSkip { none, throttled, broken }

/// Donor: `if(!opts.force&&f.throttledUntil&&f.throttledUntil>now)` then
/// `if(!opts.force&&f.broken)`.
RefreshSkip shouldSkipRefresh(FeedRefreshState s,
    {required int nowMs, bool force = false}) {
  if (force) return RefreshSkip.none;
  final until = s.throttledUntilMs;
  if (until != null && until > nowMs) return RefreshSkip.throttled;
  if (s.broken) return RefreshSkip.broken;
  return RefreshSkip.none;
}

/// Applies a fetch result to the state. For [FeedFetchStatus.fresh] pass the
/// parsed feed title as [parsedTitle] — and only call this after the parse
/// succeeded; a fresh body that fails to parse goes through
/// [applyParseFailure] instead (see the library note).
FeedRefreshState applyFetchResult(FeedRefreshState s, FeedFetchResult r,
    {required int nowMs, String? parsedTitle}) {
  switch (r.status) {
    case FeedFetchStatus.notModified:
      return s.copyWith(lastCheckedMs: nowMs, consecutiveFailures: 0);
    case FeedFetchStatus.throttled:
      return s.copyWith(
        throttledUntilMs: nowMs + (r.retryAfterSeconds ?? 60) * 1000,
        lastCheckedMs: nowMs,
      );
    case FeedFetchStatus.notFound:
      return s.copyWith(
        consecutiveFailures: s.consecutiveFailures + 1,
        broken: true,
        lastError: 'Feed returned 404/410',
      );
    case FeedFetchStatus.error:
      final failures = s.consecutiveFailures + 1;
      return s.copyWith(
        consecutiveFailures: failures,
        broken: failures >= 5 ? true : s.broken,
        lastError: 'Fetch failed',
      );
    case FeedFetchStatus.fresh:
      var title = s.title;
      if ((title.isEmpty || title == s.url) &&
          parsedTitle != null &&
          parsedTitle.isNotEmpty) {
        title = parsedTitle;
      }
      return s.copyWith(
        title: title,
        // Donor: if(res.etag)f.etag=res.etag — absent validators keep the old.
        etag: (r.etag != null && r.etag!.isNotEmpty) ? r.etag : null,
        lastModified: (r.lastModified != null && r.lastModified!.isNotEmpty)
            ? r.lastModified
            : null,
        lastCheckedMs: nowMs,
        consecutiveFailures: 0,
        broken: false,
        clearLastError: true,
        clearThrottledUntil: true,
      );
  }
}

/// Applies a parse failure of a fresh body: one more consecutive failure
/// (breaker at 5, like [FeedFetchStatus.error]) and — unlike a fetch
/// failure — `lastChecked` is stamped, because the server did answer.
///
/// Deliberate donor deviation (see the library note): the donor's parse
/// exception skipped all bookkeeping, so a persistently unparseable feed
/// never tripped the breaker.
FeedRefreshState applyParseFailure(FeedRefreshState s,
    {required int nowMs, String error = 'Feed could not be parsed'}) {
  final failures = s.consecutiveFailures + 1;
  return s.copyWith(
    consecutiveFailures: failures,
    broken: failures >= 5 ? true : s.broken,
    lastError: error,
    lastCheckedMs: nowMs,
  );
}
