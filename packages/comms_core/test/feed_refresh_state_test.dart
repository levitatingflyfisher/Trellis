/// The refresh breaker (donor refreshFeeds bookkeeping, index.html
/// ~5862–5902) as a pure state machine: throttle window, 5-failure breaker,
/// 404/410 instant break, validator adoption, title adoption. The caller
/// persists the state; nothing here touches a clock or the network.
library;

import 'package:comms_core/comms_core.dart';
import 'package:test/test.dart';

void main() {
  const nowMs = 1000000;

  group('shouldSkipRefresh', () {
    test('inside the throttle window skips', () {
      const s = FeedRefreshState(url: 'u', throttledUntilMs: nowMs + 5000);
      expect(shouldSkipRefresh(s, nowMs: nowMs), RefreshSkip.throttled);
    });

    test('an expired throttle window does not skip', () {
      const s = FeedRefreshState(url: 'u', throttledUntilMs: nowMs - 1);
      expect(shouldSkipRefresh(s, nowMs: nowMs), RefreshSkip.none);
    });

    test('broken skips until its weekly retry', () {
      const s = FeedRefreshState(
          url: 'u', broken: true, nextAttemptMs: nowMs + 5000);
      expect(shouldSkipRefresh(s, nowMs: nowMs), RefreshSkip.broken);
    });

    test('broken with no retry scheduled (it broke before retries '
        'existed) is due now', () {
      const s = FeedRefreshState(url: 'u', broken: true);
      expect(shouldSkipRefresh(s, nowMs: nowMs), RefreshSkip.none);
    });

    test('force overrides both', () {
      const s = FeedRefreshState(
          url: 'u', broken: true, throttledUntilMs: nowMs + 5000);
      expect(shouldSkipRefresh(s, nowMs: nowMs, force: true),
          RefreshSkip.none);
    });
  });

  group('backoff (ADR-0017)', () {
    const minute = 60 * 1000;
    const hour = 60 * minute;
    const error = FeedFetchResult.error();

    // r = 0.5 is the jitter's midpoint: no spread at all.
    FeedRefreshState failTimes(int n, {double r = 0.5}) {
      var s = const FeedRefreshState(url: 'u');
      for (var i = 0; i < n; i++) {
        s = applyFetchResult(s, error, nowMs: nowMs, jitter: () => r);
      }
      return s;
    }

    test('each failure doubles the wait from 30 minutes', () {
      expect(failTimes(1).nextAttemptMs, nowMs + 30 * minute);
      expect(failTimes(2).nextAttemptMs, nowMs + 60 * minute);
      expect(failTimes(3).nextAttemptMs, nowMs + 120 * minute);
    });

    test('jitter spreads the wait by at most a fifth either way', () {
      expect(failTimes(1, r: 0).nextAttemptMs, nowMs + 24 * minute);
      expect(failTimes(1, r: 1).nextAttemptMs, nowMs + 36 * minute);
    });

    test('the wait never passes a day, jitter included', () {
      // At the default base the breaker trips (four hours in) long before
      // the cap matters; a longer base shows the cap holds.
      final four = applyFetchResult(
          const FeedRefreshState(url: 'u', consecutiveFailures: 3), error,
          nowMs: nowMs, jitter: () => 0.5);
      expect(four.nextAttemptMs, nowMs + 4 * hour);
      final capped = applyParseFailure(
          const FeedRefreshState(url: 'u', consecutiveFailures: 3),
          nowMs: nowMs, jitter: () => 1, baseMs: 10 * hour);
      expect(capped.nextAttemptMs, nowMs + 24 * hour);
    });

    test('an automatic refresh waits; an explicit one does not', () {
      final s = failTimes(1);
      expect(shouldSkipRefresh(s, nowMs: nowMs + minute), RefreshSkip.backoff);
      expect(shouldSkipRefresh(s, nowMs: nowMs + minute, force: true),
          RefreshSkip.none);
      expect(shouldSkipRefresh(s, nowMs: nowMs + 31 * minute),
          RefreshSkip.none);
    });

    test('a broken feed is tried again automatically once a week', () {
      final gone = applyFetchResult(
          const FeedRefreshState(url: 'u'), const FeedFetchResult.notFound(),
          nowMs: nowMs, jitter: () => 0.5);
      const week = 7 * 24 * hour;
      expect(gone.nextAttemptMs, nowMs + week);
      expect(shouldSkipRefresh(gone, nowMs: nowMs + week - 1),
          RefreshSkip.broken);
      expect(shouldSkipRefresh(gone, nowMs: nowMs + week), RefreshSkip.none);
      final fifth = failTimes(5);
      expect(fifth.broken, isTrue);
      expect(fifth.nextAttemptMs, nowMs + week);
    });

    test('an answer clears the wait', () {
      final s = applyFetchResult(failTimes(3),
          const FeedFetchResult.notModified(), nowMs: nowMs);
      expect(s.nextAttemptMs, isNull);
      final f = applyFetchResult(failTimes(3),
          const FeedFetchResult.fresh(body: ''), nowMs: nowMs);
      expect(f.nextAttemptMs, isNull);
    });
  });

  group('applyFetchResult', () {
    test('notModified: failures reset, lastChecked stamped, meta kept', () {
      const s = FeedRefreshState(
          url: 'u', etag: 'E', consecutiveFailures: 3);
      final next = applyFetchResult(s, const FeedFetchResult.notModified(),
          nowMs: nowMs);
      expect(next.consecutiveFailures, 0);
      expect(next.lastCheckedMs, nowMs);
      expect(next.etag, 'E');
    });

    test('throttled: window recorded, failures untouched', () {
      const s = FeedRefreshState(url: 'u', consecutiveFailures: 2);
      final next = applyFetchResult(s, const FeedFetchResult.throttled(120),
          nowMs: nowMs);
      expect(next.throttledUntilMs, nowMs + 120 * 1000);
      expect(next.lastCheckedMs, nowMs);
      expect(next.consecutiveFailures, 2);
      expect(next.broken, isFalse);
    });

    test('notFound: instant break', () {
      const s = FeedRefreshState(url: 'u');
      final next = applyFetchResult(s, const FeedFetchResult.notFound(),
          nowMs: nowMs);
      expect(next.broken, isTrue);
      expect(next.consecutiveFailures, 1);
      expect(next.lastError, feedGoneReason);
      expect(next.lastCheckedMs, isNull,
          reason: 'donor does not stamp lastChecked on failures');
    });

    test('parse failure counts toward the breaker and stamps lastChecked', () {
      // Why: fixed donor bug — its parse exception skipped all bookkeeping,
      // so a persistently unparseable feed NEVER tripped the 5-failure
      // breaker (and the successful contact was never stamped).
      var s = const FeedRefreshState(url: 'u');
      for (var i = 1; i <= 4; i++) {
        s = applyParseFailure(s, nowMs: nowMs);
        expect(s.consecutiveFailures, i);
        expect(s.broken, isFalse, reason: 'not yet at failure $i');
        expect(s.lastCheckedMs, nowMs,
            reason: 'the server answered — contact is stamped');
        expect(s.lastError, 'Feed could not be parsed');
      }
      s = applyParseFailure(s, nowMs: nowMs);
      expect(s.consecutiveFailures, 5);
      expect(s.broken, isTrue,
          reason: 'persistently unparseable feeds must eventually break');
    });

    test('parse failure carries the parse error message when given', () {
      final s = applyParseFailure(const FeedRefreshState(url: 'u'),
          nowMs: nowMs, error: 'Not a valid RSS or Atom feed');
      expect(s.lastError, 'Not a valid RSS or Atom feed');
    });

    test('error: breaker trips at 5 consecutive failures', () {
      var s = const FeedRefreshState(url: 'u');
      for (var i = 1; i <= 4; i++) {
        s = applyFetchResult(s, const FeedFetchResult.error(), nowMs: nowMs);
        expect(s.consecutiveFailures, i);
        expect(s.broken, isFalse, reason: 'not yet at failure $i');
        expect(s.lastError, feedUnreachableReason);
      }
      s = applyFetchResult(s, const FeedFetchResult.error(), nowMs: nowMs);
      expect(s.consecutiveFailures, 5);
      expect(s.broken, isTrue);
    });

    test('error: a server refusal names its status code', () {
      final s = applyFetchResult(
          const FeedRefreshState(url: 'u'), const FeedFetchResult.error(403),
          nowMs: nowMs);
      expect(s.lastError, contains('403'));
    });

    test('error: a typed refusal keeps its own sentence', () {
      final s = applyFetchResult(const FeedRefreshState(url: 'u'),
          const FeedFetchResult.error(202, feedBotWallReason),
          nowMs: nowMs);
      expect(s.lastError, feedBotWallReason);
    });

    group('fresh', () {
      const fresh = FeedFetchResult.fresh(
          body: '<rss/>', etag: 'E2', lastModified: 'LM2');

      test('resets the breaker and clears throttle/error', () {
        const s = FeedRefreshState(
            url: 'u',
            consecutiveFailures: 4,
            broken: true,
            lastError: 'Fetch failed',
            throttledUntilMs: nowMs + 999);
        final next =
            applyFetchResult(s, fresh, nowMs: nowMs, parsedTitle: 'T');
        expect(next.consecutiveFailures, 0);
        expect(next.broken, isFalse);
        expect(next.lastError, isNull);
        expect(next.throttledUntilMs, isNull);
        expect(next.lastCheckedMs, nowMs);
      });

      test('adopts validators only when the response carried them', () {
        const s = FeedRefreshState(url: 'u', etag: 'E1', lastModified: 'LM1');
        final withBoth =
            applyFetchResult(s, fresh, nowMs: nowMs, parsedTitle: 'T');
        expect(withBoth.etag, 'E2');
        expect(withBoth.lastModified, 'LM2');
        final without = applyFetchResult(
            s, const FeedFetchResult.fresh(body: '<rss/>'),
            nowMs: nowMs, parsedTitle: 'T');
        expect(without.etag, 'E1',
            reason: 'donor: if(res.etag) — null keeps the old validator');
        expect(without.lastModified, 'LM1');
      });

      test('adopts the parsed title when title is empty or equals the url',
          () {
        const empty = FeedRefreshState(url: 'u', title: '');
        expect(
            applyFetchResult(empty, fresh, nowMs: nowMs, parsedTitle: 'New')
                .title,
            'New');
        const asUrl = FeedRefreshState(url: 'u', title: 'u');
        expect(
            applyFetchResult(asUrl, fresh, nowMs: nowMs, parsedTitle: 'New')
                .title,
            'New');
        const custom = FeedRefreshState(url: 'u', title: 'My Name');
        expect(
            applyFetchResult(custom, fresh, nowMs: nowMs, parsedTitle: 'New')
                .title,
            'My Name');
      });
    });
  });
}
