/// The fetch ladder (donor 40-comms.js): direct first, then — only with
/// explicit consent (C5) — public CORS proxies. Every URL passes the SSRF
/// guard; every body is size-capped mid-stream (H16).
///
/// Deliberate donor deviation: a tripped mid-stream size cap surfaces as
/// [SizeCapException] and stops the ladder — a proxy cannot shrink the body,
/// and the donor's swallow-and-retry showed the unrelated generic "all
/// proxies failed" message instead of the size error.
library;

import 'dart:math';
import 'dart:typed_data';

import 'decode.dart';
import 'exceptions.dart';
import 'feed_fetch_result.dart';
import 'http_date.dart';
import 'http_fetcher.dart';
import 'limits.dart';
import 'safe_url.dart';

typedef ProxyUrlBuilder = String Function(String url);

/// True when [host] IS [domain] or a subdomain of it, anchored on a label
/// boundary: `notsubstack.com` is NOT under `substack.com`.
///
/// Deliberate donor deviation: the donor's unanchored host regexes
/// (`/substack\.com$/`, `/medium\.com$/`) matched any host that merely
/// ended in the known domain, so lookalike hosts took the known-host
/// discovery branches (and notmedium.com leaked its path to medium.com).
bool hostIsOrUnder(String host, String domain) =>
    host == domain || host.endsWith('.$domain');

/// `onProgress(percent, got, total)` — percent is null when the response
/// carries no Content-Length (donor semantics).
typedef ProgressCallback = void Function(int? percent, int got, int total);

String _corsEu(String u) => 'https://cors.eu.org/$u';
String _allOrigins(String u) =>
    'https://api.allorigins.win/raw?url=${Uri.encodeComponent(u)}';
String _codetabs(String u) =>
    'https://api.codetabs.com/v1/proxy?quest=${Uri.encodeComponent(u)}';

/// Donor CORS_PROXIES, in ladder order.
const List<ProxyUrlBuilder> defaultCorsProxies = [
  _corsEu,
  _allOrigins,
  _codetabs,
];

/// Donor BINARY_PROXIES (codetabs excluded — it mangles binaries).
const List<ProxyUrlBuilder> defaultBinaryProxies = [_corsEu, _allOrigins];

/// The consent-dialog copy the donor passed to `confirmEgress` — exposed so
/// the app layer shows the same words.
const String proxyConsentPrompt =
    "This page didn't allow a direct fetch. Loading it requires routing the "
    'address and its contents through a public CORS proxy (cors.eu.org / '
    'allorigins.win / codetabs.com), so a third party would see them. '
    'Allow public proxies for this profile?';

/// The app layer's consent store + dialog (donor `activeProfile().prefs.
/// egressConsent.proxy` + `confirmEgress`).
abstract class ProxyConsent {
  /// Whether this profile already consented to public proxies.
  bool get proxyConsented;

  /// Show the consent dialog ([proxyConsentPrompt]); returns the grant.
  /// Implementations should persist a grant so [proxyConsented] flips.
  Future<bool> requestProxyConsent();
}

class BinaryFetchResult {
  const BinaryFetchResult({required this.bytes, required this.contentType});

  final Uint8List bytes;

  /// Response Content-Type, defaulting to `audio/mpeg` like the donor's Blob.
  final String contentType;
}

class CommsClient {
  CommsClient({
    required HttpFetcher fetcher,
    required ProxyConsent consent,
    this.corsProxies = defaultCorsProxies,
    this.binaryProxies = defaultBinaryProxies,
    this.maxTextBytes = maxTextFetchBytes,
    this.maxAudioBytes = maxAudioFetchBytes,
    DateTime Function()? now,
  })  : _fetcher = fetcher,
        _consent = consent,
        nowFn = now ?? DateTime.now;

  final HttpFetcher _fetcher;
  final ProxyConsent _consent;
  final List<ProxyUrlBuilder> corsProxies;
  final List<ProxyUrlBuilder> binaryProxies;

  /// Caps are donor constants by default; injectable for tests.
  final int maxTextBytes;
  final int maxAudioBytes;

  /// Injectable clock (Retry-After date arithmetic).
  final DateTime Function() nowFn;

  /// Donor `ensureProxyConsent`: prior consent wins; otherwise ask only
  /// when interactive.
  Future<bool> ensureProxyConsent({bool interactive = true}) async {
    if (_consent.proxyConsented) return true;
    if (!interactive) return false;
    return _consent.requestProxyConsent();
  }

  /// Donor `fetchAndDecode`: cap the body, then charset-sniff it to text.
  Future<String> fetchAndDecode(FetchResponse r) async {
    final bytes = await collectCapped(
      r.body,
      maxBytes: maxTextBytes,
      message: 'Fetched page is too large '
          '(over ${maxTextBytes ~/ (1024 * 1024)} MB) — refusing to load.',
    );
    return decodeResponseBytes(bytes, r.header('content-type') ?? '');
  }

  /// Donor `fetchWithProxies`: SSRF guard → direct (5 s) → consent gate →
  /// proxy ladder (8 s each).
  Future<String> fetchWithProxies(String url, {bool interactive = true}) async {
    final safe = assertSafeFetchUrl(url);
    // Try direct first (short timeout — CORS failures are fast, hangs are not)
    try {
      final r = await _fetcher.get(safe, timeout: const Duration(seconds: 5));
      if (r.ok) return await fetchAndDecode(r);
      // non-ok falls through to the proxy ladder, like the donor's throw/catch
    } on SizeCapException {
      rethrow; // a proxy cannot shrink the body — surface the cap, no ladder
    } catch (_) {}
    // Direct failed → public-proxy fallback leaves the device. Gate on consent.
    if (!await ensureProxyConsent(interactive: interactive)) {
      throw const FetchFailedException(
          'Direct fetch failed and public proxies are off (enable them when '
          'prompted, or paste the text instead).');
    }
    for (final mkUrl in corsProxies) {
      try {
        final r = await _fetcher.get(Uri.parse(mkUrl(url)),
            timeout: const Duration(seconds: 8));
        if (r.ok) return await fetchAndDecode(r);
      } on SizeCapException {
        rethrow; // the next proxy would serve the same oversized body
      } catch (_) {}
    }
    throw const FetchFailedException(
        'Blocked by CORS — all proxies failed. Try pasting the article text '
        'instead.');
  }

  /// Donor `fetchFeedConditional` (40-comms.js): polite conditional fetch
  /// for feeds. Direct first — the only path where conditional headers are
  /// meaningful. Falls back to proxies WITHOUT ever prompting (this runs
  /// during background refresh, C5): only when consent was already granted.
  Future<FeedFetchResult> fetchFeedConditional(
    String url, {
    String? etag,
    String? lastModified,
  }) async {
    final safe = assertSafeFetchUrl(url);
    final headers = <String, String>{};
    if (etag != null && etag.isNotEmpty) headers['If-None-Match'] = etag;
    if (lastModified != null && lastModified.isNotEmpty) {
      headers['If-Modified-Since'] = lastModified;
    }
    try {
      final r = await _fetcher.get(safe,
          headers: headers, timeout: const Duration(seconds: 8));
      if (r.statusCode == 304) return const FeedFetchResult.notModified();
      if (r.statusCode == 429 || r.statusCode == 503) {
        final ra = r.header('retry-after');
        var retrySec = 60;
        if (ra != null && ra.isNotEmpty) {
          final n = parseIntPrefix(ra);
          if (n != null) {
            retrySec = n;
          } else {
            final d = parseHttpDate(ra);
            if (d != null) {
              retrySec = max(
                  1,
                  ((d.millisecondsSinceEpoch -
                              nowFn().millisecondsSinceEpoch) /
                          1000)
                      .round());
            }
          }
        }
        return FeedFetchResult.throttled(retrySec);
      }
      if (r.statusCode == 404 || r.statusCode == 410) {
        return const FeedFetchResult.notFound();
      }
      if (r.ok) {
        final body = await fetchAndDecode(r);
        return FeedFetchResult.fresh(
          body: body,
          etag: r.header('etag'),
          lastModified: r.header('last-modified'),
        );
      }
      // 4xx: treat as error, caller decides whether to mark broken.
      return FeedFetchResult.error(r.statusCode);
    } on CommsException catch (e) {
      // A typed refusal carries a user-facing sentence (the web fetcher's
      // "the browser blocked this fetch", a size cap, a redirect refusal).
      // When no proxy may rescue the fetch, that sentence IS the outcome —
      // destroying it here would misreport an explained refusal as a
      // generic transport error.
      if (!_consent.proxyConsented) {
        return FeedFetchResult.error(null, e.message);
      }
    } catch (_) {}
    // Fall back to proxies — but never prompt here (background refresh);
    // only use them if the profile already consented (C5).
    if (!_consent.proxyConsented) return const FeedFetchResult.error();
    for (final mkUrl in corsProxies) {
      try {
        final r = await _fetcher.get(Uri.parse(mkUrl(url)),
            timeout: const Duration(seconds: 8));
        if (r.ok) {
          final body = await fetchAndDecode(r);
          return FeedFetchResult.fresh(body: body, viaProxy: true);
        }
      } catch (_) {}
    }
    return const FeedFetchResult.error();
  }

  /// Donor `discoverFeedUrl` (index.html ~6273): feed-looking URLs pass
  /// through; otherwise fetch and sniff, try `<link>` discovery, then a
  /// known-host + generic guess ladder. Gives up by returning [url] so the
  /// caller's parse produces a specific error.
  Future<String> discoverFeedUrl(String url) async {
    // If it already looks like a feed URL, use it directly
    if (_feedPathRe.hasMatch(url) || _feedExtRe.hasMatch(url)) return url;
    // Try fetching the URL — if it's XML, great
    String body;
    try {
      body = await fetchWithProxies(url);
    } catch (_) {
      return url;
    }
    if (_looksLikeXml(body)) return url;
    // It's HTML — look for RSS/Atom link discovery
    final match = _feedLinkRe.firstMatch(body);
    if (match != null) {
      final href = _hrefRe.firstMatch(match.group(0)!);
      if (href != null) {
        final discovered = href.group(1)!;
        // Resolve relative URLs
        try {
          return Uri.parse(url).resolve(discovered).toString();
        } catch (_) {
          return discovered;
        }
      }
    }
    // Build guesses including known-host patterns (Substack, WP, Ghost,
    // Medium, YouTube).
    final guesses = <String>[];
    try {
      final u = Uri.parse(url);
      final host = u.host.toLowerCase();
      // Known hosts first — highest precision. Anchored: lookalike hosts
      // (notsubstack.com) never take these branches.
      if (hostIsOrUnder(host, 'substack.com')) {
        guesses.add(u.resolve('/feed').toString());
      } else if (hostIsOrUnder(host, 'medium.com')) {
        // Donor quirk kept: the @user and publication branches build the
        // same URL.
        final segs = u.path.split('/').where((s) => s.isNotEmpty);
        if (segs.isNotEmpty) {
          guesses.add('https://medium.com/feed/${segs.first}');
        }
      } else if (host == 'www.youtube.com' || host == 'youtube.com') {
        final ch = _youtubeChannelRe.firstMatch(u.path);
        if (ch != null) {
          guesses.add('https://www.youtube.com/feeds/videos.xml'
              '?channel_id=${ch.group(1)}');
        }
      }
      // Generic fallbacks (covers WordPress, Ghost, Jekyll, Hugo, most
      // blogs).
      guesses.addAll([
        u.resolve('/feed').toString(),
        u.resolve('/feed/').toString(),
        u.resolve('/rss').toString(),
        u.resolve('/rss/').toString(),
        u.resolve('/atom.xml').toString(),
        u.resolve('/rss.xml').toString(),
        u.resolve('/index.xml').toString(),
      ]);
    } catch (_) {}
    // De-dup while preserving order.
    final seen = <String>{};
    for (final guess in guesses) {
      if (!seen.add(guess)) continue;
      try {
        final test = await fetchWithProxies(guess);
        if (_looksLikeXml(test)) return guess;
      } catch (_) {}
    }
    return url; // give up, let parseRssFeed produce a specific error
  }

  static bool _looksLikeXml(String body) {
    final t = body.trim();
    return t.startsWith('<?xml') ||
        t.startsWith('<rss') ||
        t.startsWith('<feed');
  }

  static final _feedPathRe =
      RegExp(r'/(feed|rss|atom)(\.xml)?$', caseSensitive: false);
  static final _feedExtRe =
      RegExp(r'\.(rss|atom|xml)$', caseSensitive: false);
  static final _feedLinkRe = RegExp(
      '<link[^>]+type=["\']application/(rss|atom)\\+xml["\'][^>]*>',
      caseSensitive: false);
  static final _hrefRe =
      RegExp('href=["\']([^"\']+)["\']', caseSensitive: false);
  static final _youtubeChannelRe = RegExp(r'/channel/([A-Za-z0-9_-]+)');

  /// Donor `fetchBinaryWithProxies`: direct (15 s) → consent gate → binary
  /// proxy ladder (120 s each); 300 MB cap enforced mid-stream.
  Future<BinaryFetchResult> fetchBinaryWithProxies(
    String url, {
    ProgressCallback? onProgress,
    bool interactive = true,
  }) async {
    assertSafeFetchUrl(url);

    Future<BinaryFetchResult> tryFetch(String u, Duration timeout) async {
      final r = await _fetcher.get(Uri.parse(u), timeout: timeout);
      if (!r.ok) throw FetchFailedException('status ${r.statusCode}');
      final total = int.tryParse(r.header('content-length') ?? '') ?? 0;
      final bytes = await collectCapped(
        r.body,
        maxBytes: maxAudioBytes,
        message:
            'Episode exceeds the ${maxAudioBytes ~/ (1024 * 1024)} MB cap.',
        onBytes: onProgress == null
            ? null
            : (got) => onProgress(
                total > 0 ? (100 * got / total).round() : null, got, total),
      );
      return BinaryFetchResult(
          bytes: bytes,
          contentType: r.header('content-type') ?? 'audio/mpeg');
    }

    try {
      return await tryFetch(url, const Duration(seconds: 15));
    } on SizeCapException {
      rethrow; // a proxy cannot shrink the episode — surface the cap
    } catch (_) {}
    // Direct failed → public-proxy fallback leaves the device (C5).
    if (!await ensureProxyConsent(interactive: interactive)) {
      throw const FetchFailedException(
          'Podcast host blocks direct browser fetch and public proxies are '
          'off. Enable them when prompted, or drop the MP3 in via the Audio '
          'button.');
    }
    for (final mkUrl in binaryProxies) {
      try {
        return await tryFetch(mkUrl(url), const Duration(seconds: 120));
      } on SizeCapException {
        rethrow; // the next proxy would serve the same oversized episode
      } catch (_) {}
    }
    throw const FetchFailedException(
        'Podcast host blocks browser fetch and all CORS proxies failed. Try '
        'saving the MP3 locally and dropping it in via the Audio button.');
  }
}
