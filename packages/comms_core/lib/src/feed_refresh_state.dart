/// The per-feed refresh bookkeeping (donor refreshFeeds, index.html
/// ~5862–5902) as a pure state machine. The caller owns persistence and the
/// clock; this file owns the transitions:
///
/// - inside the throttle window → skip (unless forced)
/// - broken → skip until its weekly retry (unless forced)
/// - inside a failure's backoff → skip (unless forced)
/// - notModified → failures reset, broken cleared
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

import 'dart:math';

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
    this.nextAttemptMs,
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

  /// Epoch millis before which an automatic refresh leaves this feed alone
  /// (ADR-0017): exponential backoff after a failure, a week once broken.
  /// An explicit refresh ignores it.
  final int? nextAttemptMs;

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
    int? nextAttemptMs,
    bool clearNextAttempt = false,
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
      nextAttemptMs:
          clearNextAttempt ? null : (nextAttemptMs ?? this.nextAttemptMs),
    );
  }
}

enum RefreshSkip { none, throttled, backoff, broken }

/// The first retry's wait; each further failure doubles it.
const feedBackoffBaseMs = 30 * 60 * 1000;
const feedBackoffCapMs = 24 * 60 * 60 * 1000;

/// How long a broken feed waits between automatic retries. Never giving
/// up means a show that comes back is found again; a week keeps a dead
/// one from costing more than a request a week.
const brokenFeedRetryMs = 7 * 24 * 60 * 60 * 1000;

/// A random number in [0, 1); spreads retries so feeds that failed
/// together (a network drop) don't all retry in the same second.
typedef Jitter = double Function();

final _random = Random();
double _defaultJitter() => _random.nextDouble();

/// When to try again after [failures] consecutive failures: base·2^(n-1),
/// ±20 %, never past a day. A broken feed waits [brokenFeedRetryMs].
int nextAttemptAfter(int failures,
    {required int nowMs,
    required bool broken,
    Jitter jitter = _defaultJitter,
    int baseMs = feedBackoffBaseMs}) {
  if (broken) return nowMs + brokenFeedRetryMs;
  final exp = failures < 1 ? 0 : (failures - 1).clamp(0, 30);
  final raw = baseMs * pow(2, exp) * (0.8 + 0.4 * jitter());
  return nowMs + min(raw, feedBackoffCapMs.toDouble()).round();
}

/// Donor: `if(!opts.force&&f.throttledUntil&&f.throttledUntil>now)` then
/// `if(!opts.force&&f.broken)`.
///
/// Deliberate donor deviation: the donor never retried a broken feed on its
/// own. Here a broken feed whose weekly retry is due refreshes like any
/// other, and a failing one waits out its backoff.
RefreshSkip shouldSkipRefresh(FeedRefreshState s,
    {required int nowMs, bool force = false}) {
  if (force) return RefreshSkip.none;
  final until = s.throttledUntilMs;
  if (until != null && until > nowMs) return RefreshSkip.throttled;
  final next = s.nextAttemptMs;
  if (s.broken) {
    // Broken with no retry scheduled broke before retries existed: its
    // weekly retry is due now, and the next failure schedules the one
    // after.
    return next == null || next <= nowMs
        ? RefreshSkip.none
        : RefreshSkip.broken;
  }
  if (next != null && next > nowMs) return RefreshSkip.backoff;
  return RefreshSkip.none;
}

/// Applies a fetch result to the state. For [FeedFetchStatus.fresh] pass the
/// parsed feed title as [parsedTitle] — and only call this after the parse
/// succeeded; a fresh body that fails to parse goes through
/// [applyParseFailure] instead (see the library note).
///
/// [jitter] spreads the backoff a failure schedules; injectable for tests.
FeedRefreshState applyFetchResult(FeedRefreshState s, FeedFetchResult r,
    {required int nowMs, String? parsedTitle, Jitter jitter = _defaultJitter}) {
  switch (r.status) {
    case FeedFetchStatus.notModified:
      return s.copyWith(
          lastCheckedMs: nowMs,
          consecutiveFailures: 0,
          broken: false,
          clearNextAttempt: true);
    case FeedFetchStatus.throttled:
      return s.copyWith(
        throttledUntilMs: nowMs + (r.retryAfterSeconds ?? 60) * 1000,
        lastCheckedMs: nowMs,
      );
    case FeedFetchStatus.notFound:
      return s.copyWith(
        consecutiveFailures: s.consecutiveFailures + 1,
        broken: true,
        lastError: feedGoneReason,
        nextAttemptMs: nextAttemptAfter(s.consecutiveFailures + 1,
            nowMs: nowMs, broken: true),
      );
    case FeedFetchStatus.error:
      final failures = s.consecutiveFailures + 1;
      final broken = failures >= 5 ? true : s.broken;
      return s.copyWith(
        consecutiveFailures: failures,
        broken: broken,
        nextAttemptMs: nextAttemptAfter(failures,
            nowMs: nowMs, broken: broken, jitter: jitter),
        lastError: r.message ??
            (r.errorCode != null
                ? feedRefusedReason(r.errorCode!)
                : feedUnreachableReason),
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
        clearNextAttempt: true,
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
    {required int nowMs,
    String error = 'Feed could not be parsed',
    Jitter jitter = _defaultJitter,
    int baseMs = feedBackoffBaseMs}) {
  final failures = s.consecutiveFailures + 1;
  final broken = failures >= 5 ? true : s.broken;
  return s.copyWith(
    consecutiveFailures: failures,
    broken: broken,
    nextAttemptMs: nextAttemptAfter(failures,
        nowMs: nowMs, broken: broken, jitter: jitter, baseMs: baseMs),
    lastError: error,
    lastCheckedMs: nowMs,
  );
}
