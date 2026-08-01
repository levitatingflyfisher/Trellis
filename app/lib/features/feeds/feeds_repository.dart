/// The feeds feature's one door to the network: comms_core's hygiene
/// (SSRF guard, conditional GET, size caps) over an injected [HttpFetcher],
/// with the refresh breaker persisted per feed row.
///
/// Native surfaces fetch direct — proxy consent is structurally denied here
/// (proposal-2 §8: "the entire public-CORS-proxy layer vanishes"), so
/// comms_core's proxy ladder is dead code on this path by construction.
library;

import 'dart:async';

import 'package:comms_core/comms_core.dart';

import '../../db/database.dart';
import '../../services/device_services.dart';
import 'audio_eviction.dart';
import 'feed_dedup.dart';
import 'feed_ingest.dart';
import 'feed_rules.dart';

/// Proxy consent that never grants: the native app has no proxy path.
class NativeDirectConsent implements ProxyConsent {
  const NativeDirectConsent();
  @override
  bool get proxyConsented => false;
  @override
  Future<bool> requestProxyConsent() async => false;
}

sealed class SubscribeResult {
  const SubscribeResult();
}

class SubscribeSuccess extends SubscribeResult {
  const SubscribeSuccess(
      {required this.feedId, required this.title, required this.newItems});
  final int feedId;
  final String title;
  final int newItems;
}

class AlreadySubscribed extends SubscribeResult {
  const AlreadySubscribed(this.title);
  final String title;
}

class SubscribeFailure extends SubscribeResult {
  const SubscribeFailure(this.message);
  final String message;
}

sealed class PodcastSearchOutcome {
  const PodcastSearchOutcome();
}

class PodcastSearchSuccess extends PodcastSearchOutcome {
  const PodcastSearchSuccess(this.results);
  final List<PodcastSearchResult> results;
}

class PodcastSearchFailure extends PodcastSearchOutcome {
  const PodcastSearchFailure(this.message);
  final String message;
}

enum RefreshStatus {
  /// New body parsed and ingested.
  fresh,

  /// 304 — validators held.
  notModified,

  /// 429/503 — the throttle window was recorded.
  throttled,

  /// 404/410 — broken immediately.
  notFound,

  /// Transport or HTTP error — failure counted, breaker at 5.
  error,

  /// Fresh body that would not parse; bookkeeping untouched (donor parity).
  parseFailed,

  /// Breaker verdict: throttle window still open, or feed marked broken.
  skipped,
}

typedef RefreshOutcome = ({RefreshStatus status, int newItems});

/// The calm line the feed detail screen shows after a feed's oldest known
/// episode when the host publishes no RFC 5005 archive at all — the
/// overwhelmingly common case. Shared with [FeedsRepository.fetchOlderEpisodes]'s
/// own defensive fallback so the two never drift apart.
const String noFeedArchiveNote =
    "The publisher's feed offers only these episodes — older ones aren't "
    'published in it.';

typedef FetchOlderOutcome = ({int newItems, String message});

class FeedsRepository {
  FeedsRepository(
      {required this.db,
      required HttpFetcher fetcher,
      this.services,
      DateTime Function()? now})
      : nowFn = now ?? DateTime.now,
        _fetcher = fetcher,
        client = CommsClient(
            fetcher: fetcher, consent: const NativeDirectConsent(), now: now);

  final AppDatabase db;
  final CommsClient client;

  /// Where downloaded audio files live — needed only for the "archive,
  /// never forget" eviction pass after a fresh refresh (P4). Null (the
  /// default) simply skips eviction; every other refresh behavior is
  /// unaffected, so tests that don't care about storage never need it.
  final DeviceServices? services;

  /// The raw seam, kept for the one non-feed fetch this repository makes:
  /// the podcast-directory search (no conditional GET, no breaker).
  final HttpFetcher _fetcher;
  final DateTime Function() nowFn;

  int get _nowMs => nowFn().millisecondsSinceEpoch;

  /// One podcast-directory search (itunes.apple.com). The typed words leave
  /// the device — the screen states that plainly, and this only ever runs
  /// from type + submit (the gesture; ADR-0003). Results are text; artwork
  /// URLs are mapped, never fetched. Every failure is a calm sentence.
  ///
  /// Web tier: itunes.apple.com sends no CORS headers, so a browser refuses
  /// this fetch and the transport sentence below shows. That is the honest
  /// behaviour — no proxy workaround, by design.
  Future<PodcastSearchOutcome> searchPodcasts(String term) async {
    final t = term.trim();
    if (t.isEmpty) {
      return const PodcastSearchFailure('Type something to search for.');
    }
    final Uri url;
    try {
      // Re-guard even our own built URL — the url_intake precedent.
      url = assertSafeFetchUrl(buildItunesSearchUrl(t).toString());
    } on UnsafeUrlException catch (e) {
      return PodcastSearchFailure(e.message);
    }
    final FetchResponse response;
    try {
      response = await _fetcher.get(url,
          headers: const {'accept': 'application/json'},
          timeout: const Duration(seconds: 10));
    } on TimeoutException {
      return const PodcastSearchFailure(
          'The directory took too long to answer — try again later.');
    } on CommsException catch (e) {
      return PodcastSearchFailure(e.message);
    } catch (_) {
      return const PodcastSearchFailure(
          "The podcast directory couldn't be reached right now.");
    }
    if (!response.ok) {
      return PodcastSearchFailure(
          'The directory answered with an error (${response.statusCode}).');
    }
    try {
      final bytes = await collectCapped(response.body,
          maxBytes: maxXmlBytes,
          message: 'The directory answer was too large to read.');
      return PodcastSearchSuccess(parseItunesSearchResults(
          decodeResponseBytes(bytes, response.header('content-type') ?? '')));
    } on SizeCapException catch (e) {
      return PodcastSearchFailure(e.message);
    } on FormatException {
      return const PodcastSearchFailure(
          "The directory's answer couldn't be read.");
    } catch (_) {
      return const PodcastSearchFailure(
          'The answer stopped arriving before it finished.');
    }
  }

  /// Subscribe by URL: SSRF guard → feed discovery → fetch → parse →
  /// feed row + items as ephemera.
  Future<SubscribeResult> subscribe(
      {required int profileId, required String rawUrl}) async {
    var input = rawUrl.trim();
    if (input.isEmpty) return const SubscribeFailure('Enter a web address.');
    if (!input.contains('://')) input = 'https://$input';
    try {
      assertSafeFetchUrl(input);
    } on UnsafeUrlException catch (e) {
      return SubscribeFailure(e.message);
    }

    final String feedUrl;
    try {
      feedUrl = await client.discoverFeedUrl(input);
    } on CommsException catch (e) {
      return SubscribeFailure(e.message);
    }

    final existing = await db.feedsDao.feedByUrl(profileId, feedUrl);
    if (existing != null) {
      return AlreadySubscribed(
          existing.title.isEmpty ? existing.url : existing.title);
    }

    final res = await client.fetchFeedConditional(feedUrl);
    if (res.status != FeedFetchStatus.fresh) {
      // A typed refusal carries its own sentence (the web tier's honest
      // "the browser blocked this fetch"); only an unexplained failure
      // falls back to the generic one.
      return SubscribeFailure(res.message ??
          "That address couldn't be reached as a feed right now.");
    }
    final ParsedFeed parsed;
    try {
      parsed = parseRssFeed(res.body!, feedUrl);
    } on FeedParseException catch (e) {
      return SubscribeFailure(e.message);
    }

    final nowMs = _nowMs;
    final feedId =
        await db.feedsDao.insertFeed(profileId: profileId, url: feedUrl);
    final state = applyFetchResult(
        FeedRefreshState(url: feedUrl), res,
        nowMs: nowMs, parsedTitle: parsed.title);
    await _persistState(feedId, state,
        nextPageUrl: parsed.nextPageUrl, updateNextPageUrl: true,
        imageUrl: parsed.imageUrl, updateImageUrl: true);
    await _maybeFetchArtwork(feedId, newUrl: parsed.imageUrl, oldUrl: null);
    // A brand-new feed has no rules yet (rulesJson is still the '[]'
    // default) — nothing to decode, the ingest default applies.
    final added = await ingestFeedItems(
        db: db,
        profileId: profileId,
        feedId: feedId,
        items: parsed.items,
        nowMs: nowMs);
    if (added > 0) await _runDedupPass(profileId);
    return SubscribeSuccess(
        feedId: feedId, title: state.title, newItems: added);
  }

  /// One feed's conditional refresh under the breaker's verdict.
  Future<RefreshOutcome> refreshFeed(Feed feed, {bool force = false}) async {
    final nowMs = _nowMs;
    var state = stateOfFeed(feed);
    if (shouldSkipRefresh(state, nowMs: nowMs, force: force) !=
        RefreshSkip.none) {
      return (status: RefreshStatus.skipped, newItems: 0);
    }
    final res = await client.fetchFeedConditional(feed.url,
        etag: feed.etag, lastModified: feed.lastModified);

    if (res.status == FeedFetchStatus.fresh) {
      final ParsedFeed parsed;
      try {
        parsed = parseRssFeed(res.body!, feed.url);
      } on FeedParseException {
        // Donor parity (comms_core note): a fresh body that fails to parse
        // skips ALL bookkeeping — an unparseable feed never trips the
        // breaker.
        return (status: RefreshStatus.parseFailed, newItems: 0);
      }
      state = applyFetchResult(state, res,
          nowMs: nowMs, parsedTitle: parsed.title);
      await _persistState(feed.id, state,
          nextPageUrl: parsed.nextPageUrl, updateNextPageUrl: true,
          imageUrl: parsed.imageUrl, updateImageUrl: true);
      await _maybeFetchArtwork(feed.id,
          newUrl: parsed.imageUrl, oldUrl: feed.imageUrl);
      final added = await ingestFeedItems(
          db: db,
          profileId: feed.profileId,
          feedId: feed.id,
          items: parsed.items,
          nowMs: nowMs,
          rules: decodeFeedRules(feed.rulesJson));
      if (added > 0) await _runDedupPass(feed.profileId);
      final deviceServices = services;
      if (deviceServices != null) {
        await evictStaleAudio(
            db: db, services: deviceServices, feedId: feed.id, nowMs: nowMs);
      }
      return (status: RefreshStatus.fresh, newItems: added);
    }

    state = applyFetchResult(state, res, nowMs: nowMs);
    await _persistState(feed.id, state);
    return (
      status: switch (res.status) {
        FeedFetchStatus.notModified => RefreshStatus.notModified,
        FeedFetchStatus.throttled => RefreshStatus.throttled,
        FeedFetchStatus.notFound => RefreshStatus.notFound,
        _ => RefreshStatus.error,
      },
      newItems: 0
    );
  }

  /// Pull-to-refresh: every feed of the profile, breaker rules applied
  /// per feed. Returns the total number of new items.
  Future<int> refreshAll(int profileId, {bool force = false}) async {
    var added = 0;
    for (final feed in await db.feedsDao.feedsOf(profileId)) {
      final outcome = await refreshFeed(feed, force: force);
      added += outcome.newItems;
    }
    return added;
  }

  Future<void> _persistState(int feedId, FeedRefreshState s,
          {String? nextPageUrl,
          bool updateNextPageUrl = false,
          String? imageUrl,
          bool updateImageUrl = false}) =>
      db.feedsDao.updateRefreshState(feedId,
          title: s.title,
          etag: s.etag,
          lastModified: s.lastModified,
          breakerJson: encodeBreakerState(s),
          nextPageUrl: nextPageUrl,
          updateNextPageUrl: updateNextPageUrl,
          imageUrl: imageUrl,
          updateImageUrl: updateImageUrl);

  /// Fetch-once, offline-first (Campaign 9 Phase 5): downloads [newUrl] to
  /// this feed's deterministic artwork file (`DeviceServices.artworkFileFor`)
  /// only when it actually differs from [oldUrl] — an unchanged URL across
  /// refreshes never re-fetches, and a host that publishes no artwork at all
  /// ([newUrl] null) has nothing to fetch. Reuses the fleet's one download
  /// engine (the same [AudioFetcher] the transcription pipeline resumes
  /// episode audio through) rather than opening a second HTTP path for a
  /// small image. A null [services] (most unit tests) simply skips this —
  /// storage is optional the same way DSP eviction above is.
  Future<void> _maybeFetchArtwork(int feedId,
      {required String? newUrl, required String? oldUrl}) async {
    final deviceServices = services;
    if (deviceServices == null) return;
    if (newUrl == null || newUrl == oldUrl) return;
    await deviceServices.audioFetcher
        .fetch(newUrl, deviceServices.artworkFileFor(feedId));
  }

  /// The explicit "Fetch older episodes" action (RFC 5005): walks the
  /// archive from [feed]'s last-known [Feed.nextPageUrl] and ingests
  /// whatever the walk turns up through the same dedup path a normal
  /// refresh uses — a host repeating an already-stored episode across
  /// archive pages adds nothing new.
  ///
  /// Reported plainly: how many episodes this call actually added, and one
  /// sentence — the two exact happy-path sentences the feed detail screen
  /// promises, or comms_core's own honest account of a walk that stopped
  /// short (capped, a failed hop, an unsafe next link) rather than a false
  /// claim of "nothing more to find".
  Future<FetchOlderOutcome> fetchOlderEpisodes(Feed feed) async {
    final startUrl = feed.nextPageUrl;
    if (startUrl == null) {
      return (newItems: 0, message: noFeedArchiveNote);
    }
    final result = await walkFeedArchive(client, startPageUrl: startUrl);
    final added = await ingestFeedItems(
        db: db,
        profileId: feed.profileId,
        feedId: feed.id,
        items: result.items,
        nowMs: _nowMs,
        rules: decodeFeedRules(feed.rulesJson));
    if (added > 0) await _runDedupPass(feed.profileId);
    final message = added > 0
        ? 'Found $added older ${added == 1 ? 'episode' : 'episodes'}.'
        : (result.stopReason == ArchiveWalkStopReason.noMorePages
            ? "No older episodes were published in the feed's archive."
            : result.message);
    return (newItems: added, message: message);
  }

  /// Cross-feed dedup (Campaign 5 Phase 3): re-evaluates every currently-
  /// visible episode in the profile's river and suppresses any new
  /// duplicate pair — see `feed_dedup.dart`. Runs after any ingest that
  /// actually added something; a no-op refresh (304, throttled, error)
  /// never touches dedup state. Called once per ingest site rather than
  /// once per [refreshAll] pass — [refreshAll] loops [refreshFeed] per
  /// feed, so a multi-feed pull-to-refresh may run this more than once;
  /// each pass is correct on its own (already-suppressed rows are
  /// excluded from the candidate pool) and the repeat cost is a full
  /// profile scan, acceptable at a personal river's size.
  Future<void> _runDedupPass(int profileId) async {
    final candidates = await db.feedsDao.dedupCandidatesOf(profileId);
    final verdicts = findDuplicates(candidates);
    for (final entry in verdicts.entries) {
      await db.feedsDao.setDedup(entry.key,
          reason: entry.value.reason,
          canonicalWorkId: entry.value.canonicalWorkId);
    }
  }
}
