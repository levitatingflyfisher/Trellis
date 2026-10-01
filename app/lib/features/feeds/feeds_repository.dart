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
import 'feed_parse.dart';
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

  /// Fresh body that would not parse; counted toward the breaker with the
  /// parser's reason, validators untouched.
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
    "The publisher’s feed offers only these episodes. Older ones aren’t "
    'published in it.';

typedef FetchOlderOutcome = ({int newItems, String message});

/// What one parsed listing says about its Subscriptions shelf (ADR-0016):
/// audio on any item says podcast, none says blog or newsletter. Judged on
/// the whole listing, before rules skip anything. Null when the listing is
/// empty, which says nothing either way. A blog verdict is only a hint;
/// see [FeedsRepository._settleOrigin].
String? originOf(ParsedFeed parsed) {
  if (parsed.items.isEmpty) return null;
  return parsed.items.any((i) => i.enclosure != null) ? 'podcast' : 'blog';
}

/// How many distinct episode images one refresh may fetch.
const episodeArtworkFetchLimit = 20;

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
          'The directory took too long to answer. Try again later.');
    } on CommsException catch (e) {
      return PodcastSearchFailure(e.message);
    } catch (_) {
      return const PodcastSearchFailure(
          "The podcast directory couldn’t be reached right now.");
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
          "The directory’s answer couldn’t be read.");
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

    String feedUrl;
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
          "That address couldn’t be reached as a feed right now.");
    }
    final ParsedFeed parsed;
    final String bodyHash;
    // A permanent move is believed only once the body proves to be a
    // feed: a host that 301s every URL to its home page must not rewrite
    // the address to one that isn't one.
    final moved = res.movedTo;
    final parseUrl = moved ?? feedUrl;
    try {
      final body = await parseFeedBody(res.body!, parseUrl);
      parsed = body.feed!;
      bodyHash = body.hash;
    } on FeedParseException catch (e) {
      return SubscribeFailure(e.message);
    }
    if (moved != null && moved != feedUrl) {
      final there = await db.feedsDao.feedByUrl(profileId, moved);
      if (there != null) {
        return AlreadySubscribed(there.title.isEmpty ? there.url : there.title);
      }
      feedUrl = moved;
    }

    final nowMs = _nowMs;
    final feedId =
        await db.feedsDao.insertFeed(profileId: profileId, url: feedUrl);
    final state = applyFetchResult(
        FeedRefreshState(url: feedUrl), res,
        nowMs: nowMs, parsedTitle: parsed.title);
    // A brand-new feed has no rules yet (rulesJson is still the '[]'
    // default) — nothing to decode, the ingest default applies.
    final added = await ingestFeedItems(
        db: db,
        profileId: profileId,
        feedId: feedId,
        items: parsed.items,
        nowMs: nowMs);
    // Validators and the body hash only once the items have landed; see
    // [_refreshOne].
    await _persistState(feedId, state,
        nextPageUrl: parsed.nextPageUrl, updateNextPageUrl: true,
        imageUrl: parsed.imageUrl, updateImageUrl: true);
    await db.feedsDao.setBodyHash(feedId, bodyHash);
    await _settleOrigin(feedId, parsed);
    if (added > 0) await _runDedupPass(profileId);
    _fetchArtworkLater(() async {
      await _maybeFetchArtwork(feedId, newUrl: parsed.imageUrl, oldUrl: null);
      await _fetchEpisodeArtwork(feedId, showImageUrl: parsed.imageUrl);
    });
    return SubscribeSuccess(
        feedId: feedId, title: state.title, newItems: added);
  }

  /// One feed's conditional refresh under the breaker's verdict.
  Future<RefreshOutcome> refreshFeed(Feed feed, {bool force = false}) async {
    final outcome = await _refreshOne(feed, force: force);
    if (outcome.newItems > 0) await _runDedupPass(feed.profileId);
    return outcome;
  }

  /// [refreshFeed] minus the dedup pass, which scans the whole profile and
  /// so runs once per batch in [refreshMany] rather than once per feed.
  Future<RefreshOutcome> _refreshOne(Feed feed, {bool force = false}) async {
    final nowMs = _nowMs;
    var state = stateOfFeed(feed);
    if (shouldSkipRefresh(state, nowMs: nowMs, force: force) !=
        RefreshSkip.none) {
      return (status: RefreshStatus.skipped, newItems: 0);
    }
    final res = await client.fetchFeedConditional(feed.url,
        etag: feed.etag, lastModified: feed.lastModified);

    if (res.status == FeedFetchStatus.fresh) {
      final ParsedBody body;
      try {
        // The hash vouches for rows the last ingest wrote; with none left
        // (all swept or purged since), the same body ingests again.
        final unchangedHash = await db.feedsDao.hasEpisodes(feed.id)
            ? feed.bodyHash
            : null;
        body = await parseFeedBody(res.body!, res.movedTo ?? feed.url,
            unchangedHash: unchangedHash);
      } on FeedParseException catch (e) {
        await _persistState(feed.id,
            applyParseFailure(state, nowMs: nowMs, error: e.message));
        return (status: RefreshStatus.parseFailed, newItems: 0);
      }
      final parsed = body.feed;
      if (parsed == null) {
        // The same bytes as the last body that ingested: a 304 the host
        // didn't know how to send. The answer still counts as contact
        // (failures reset, validators adopted); the archive link and
        // artwork it would re-derive are the ones already stored.
        state = applyFetchResult(state, res, nowMs: nowMs);
        await _persistState(feed.id, state);
        await _adoptMove(feed, res.movedTo);
        _fetchArtworkLater(() =>
            _fetchEpisodeArtwork(feed.id, showImageUrl: feed.imageUrl));
        return (status: RefreshStatus.notModified, newItems: 0);
      }
      state = applyFetchResult(state, res,
          nowMs: nowMs, parsedTitle: parsed.title);
      final added = await ingestFeedItems(
          db: db,
          profileId: feed.profileId,
          feedId: feed.id,
          items: parsed.items,
          nowMs: nowMs,
          rules: decodeFeedRules(feed.rulesJson));
      // Only now do the validators, the hash and a permanent move land.
      // Written before, an ingest that failed would leave validators that
      // turn every later fetch into a 304 (or a hash match) for a body
      // whose items never arrived.
      await _persistState(feed.id, state,
          nextPageUrl: parsed.nextPageUrl, updateNextPageUrl: true,
          imageUrl: parsed.imageUrl, updateImageUrl: true);
      await db.feedsDao.setBodyHash(feed.id, body.hash);
      await _adoptMove(feed, res.movedTo);
      await _maybeFetchArtwork(feed.id,
          newUrl: parsed.imageUrl, oldUrl: feed.imageUrl);
      await _settleOrigin(feed.id, parsed);
      // Every fresh refresh, not only one with new episodes: a fetch
      // that failed, or a URL filled in on an episode already stored,
      // still needs its file.
      _fetchArtworkLater(() =>
          _fetchEpisodeArtwork(feed.id, showImageUrl: parsed.imageUrl));
      final deviceServices = services;
      if (deviceServices != null) {
        await evictStaleAudio(
            db: db, services: deviceServices, feedId: feed.id, nowMs: nowMs);
      }
      return (status: RefreshStatus.fresh, newItems: added);
    }

    state = applyFetchResult(state, res, nowMs: nowMs);
    await _persistState(feed.id, state);
    // A 304 is the feed answering at its new address: proof enough.
    if (res.status == FeedFetchStatus.notModified) {
      await _adoptMove(feed, res.movedTo);
    }
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
    final outcomes =
        await refreshMany(await db.feedsDao.feedsOf(profileId), force: force);
    return outcomes.values.fold<int>(0, (sum, o) => sum + o.newItems);
  }

  /// Refreshes [feeds] a few at a time, keyed by feed id. The caps keep a
  /// 100-feed import from taking minutes one-by-one without opening a
  /// hundred sockets, or hammering one host that serves many of the feeds.
  /// A feed that throws counts as an error and never stalls the rest.
  Future<Map<int, RefreshOutcome>> refreshMany(List<Feed> feeds,
      {bool force = false,
      int maxConcurrent = 4,
      int maxPerHost = 2,
      void Function(int done, int total)? onProgress}) async {
    final outcomes = <int, RefreshOutcome>{};
    if (feeds.isEmpty) return outcomes;
    final pending = [...feeds];
    final perHost = <String, int>{};
    final finished = Completer<void>();
    var running = 0;

    String hostOf(Feed f) {
      final host = Uri.tryParse(f.url)?.host ?? '';
      // Malformed URLs must not all queue behind one shared empty host.
      return host.isEmpty ? f.url : host;
    }

    void pump() {
      // Skip past feeds whose host is at its cap so other hosts still run.
      for (var i = 0; i < pending.length && running < maxConcurrent;) {
        final feed = pending[i];
        final host = hostOf(feed);
        if ((perHost[host] ?? 0) >= maxPerHost) {
          i++;
          continue;
        }
        pending.removeAt(i);
        running++;
        perHost[host] = (perHost[host] ?? 0) + 1;
        () async {
          RefreshOutcome outcome;
          try {
            outcome = await _refreshOne(feed, force: force);
          } catch (_) {
            outcome = (status: RefreshStatus.error, newItems: 0);
          } finally {
            running--;
            perHost[host] = perHost[host]! - 1;
          }
          outcomes[feed.id] = outcome;
          onProgress?.call(outcomes.length, feeds.length);
          if (outcomes.length == feeds.length) {
            finished.complete();
          } else {
            pump();
          }
        }();
      }
    }

    pump();
    await finished.future;
    if (outcomes.values.any((o) => o.newItems > 0)) {
      await _runDedupPass(feeds.first.profileId);
    }
    return outcomes;
  }

  /// Follows each OPML outline not already followed, in one transaction so
  /// the list can show them all before any is fetched. URLs are only
  /// trimmed: rewriting them further could merge feeds that differ.
  Future<List<Feed>> followOutlines(
      int profileId, List<OpmlOutline> outlines) async {
    final ids = await db.transaction(() async {
      final seen = <String>{};
      final ids = <int>[];
      for (final o in outlines) {
        final url = o.url.trim();
        if (url.isEmpty || !seen.add(url)) continue;
        if (await db.feedsDao.feedByUrl(profileId, url) != null) continue;
        ids.add(await db.feedsDao
            .insertFeed(profileId: profileId, url: url, title: o.title));
      }
      return ids;
    });
    final wanted = ids.toSet();
    return [
      for (final f in await db.feedsDao.feedsOf(profileId))
        if (wanted.contains(f.id)) f,
    ];
  }

  /// A 301/308 chain says the feed lives elsewhere now, so the row
  /// follows it; a 302/307 never reaches here (comms_core only reports an
  /// unbroken permanent run). Called only once the answer proved to be
  /// the feed (a parsed body, or a 304). When this profile already
  /// follows the new address, the two rows are one show: the row keeps
  /// its own address (merging settings and kept episodes is the
  /// listener's call), and the usual post-ingest dedup pass hides the
  /// episodes they share.
  Future<void> _adoptMove(Feed feed, String? movedTo) async {
    if (movedTo == null || movedTo == feed.url) return;
    if (await db.feedsDao.feedByUrl(feed.profileId, movedTo) != null) return;
    await db.feedsDao.setUrl(feed.id, movedTo);
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

  /// Runs after the parse is ingested. Audio in this listing always makes
  /// a podcast; a text-only listing makes a blog only when no stored
  /// episode has audio either, so one show-notes post or a trimmed feed
  /// can't move a podcast off its shelf.
  Future<void> _settleOrigin(int feedId, ParsedFeed parsed) async {
    final origin = originOf(parsed);
    if (origin == null) return;
    if (origin == 'blog' && await db.feedsDao.hasAudioEpisodes(feedId)) {
      return;
    }
    await db.feedsDao.setOrigin(feedId, origin);
  }

  Future<void> _artwork = Future.value();

  /// Completes once artwork started by the last subscribe or refresh has
  /// landed or failed. Nothing waits on it but tests: following a show
  /// shouldn't hang on a slow image host.
  Future<void> get artworkSettled => _artwork;

  /// Queues artwork behind any still under way, one fetch at a time, so
  /// two refreshes never write the same file at once. A failure is just a
  /// missing thumbnail, retried by the next refresh.
  void _fetchArtworkLater(Future<void> Function() fetch) {
    final previous = _artwork;
    _artwork = () async {
      await previous;
      try {
        await fetch();
      } catch (_) {}
    }();
  }

  /// An episode's own artwork, fetched with the episodes rather than at
  /// render, through the same engine as the show's. Only images that
  /// differ from the show's, only for the newest
  /// [episodeArtworkFetchLimit], so following a 500-episode back
  /// catalogue doesn't mean 500 image requests; older rows show the
  /// show's artwork. A failed image is just a missing thumbnail.
  Future<void> _fetchEpisodeArtwork(int feedId,
      {required String? showImageUrl}) async {
    final deviceServices = services;
    // existsSync throws on the web tier, and nothing there reads the file.
    if (deviceServices == null || !deviceServices.localMlAvailable) return;
    final wanted = <String>{};
    for (final e in await db.feedsDao.episodesOfFeed(feedId)) {
      final url = e.episode.imageUrl;
      if (url == null || url == showImageUrl) continue;
      wanted.add(url);
      if (wanted.length == episodeArtworkFetchLimit) break;
    }
    for (final url in wanted) {
      final file = deviceServices.episodeArtworkFileFor(url);
      if (file.existsSync()) continue;
      try {
        await deviceServices.audioFetcher.fetch(url, file);
      } catch (_) {
        // Retried by the next refresh, since the file is still missing.
      }
    }
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
    final result = await walkFeedArchive(client,
        startPageUrl: startUrl, parse: parseFeedOffThread);
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
            ? "No older episodes were published in the feed’s archive."
            : result.message);
    return (newItems: added, message: message);
  }

  /// Cross-feed dedup (Campaign 5 Phase 3): re-evaluates every currently-
  /// visible episode in the profile's river and suppresses any new
  /// duplicate pair — see `feed_dedup.dart`. Runs after any ingest that
  /// actually added something; a no-op refresh (304, throttled, error)
  /// never touches dedup state. Runs once per batch in [refreshMany]:
  /// concurrent passes would interleave their whole-profile read-then-write.
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
