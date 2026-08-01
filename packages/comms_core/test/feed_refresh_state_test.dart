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

    test('broken skips', () {
      const s = FeedRefreshState(url: 'u', broken: true);
      expect(shouldSkipRefresh(s, nowMs: nowMs), RefreshSkip.broken);
    });

    test('force overrides both', () {
      const s = FeedRefreshState(
          url: 'u', broken: true, throttledUntilMs: nowMs + 5000);
      expect(shouldSkipRefresh(s, nowMs: nowMs, force: true),
          RefreshSkip.none);
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
      expect(next.lastError, 'Feed returned 404/410');
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
        expect(s.lastError, 'Fetch failed');
      }
      s = applyFetchResult(s, const FeedFetchResult.error(), nowMs: nowMs);
      expect(s.consecutiveFailures, 5);
      expect(s.broken, isTrue);
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
