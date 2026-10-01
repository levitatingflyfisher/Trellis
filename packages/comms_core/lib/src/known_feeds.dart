/// Addresses whose feed lives at a known place: a Bluesky or Mastodon
/// profile, a Substack front page. People share or paste the page they
/// see, never the feed behind it, so the conversion is one pure function
/// that the subscribe screen and the share sheet both ask.
library;

import 'comms_client.dart' show hostIsOrUnder;

enum KnownFeedKind { bluesky, mastodon, substack }

/// A profile or publication's feed, with a name fit for "Subscribe to …".
class KnownFeed {
  final String feedUrl;
  final String name;
  final KnownFeedKind kind;
  const KnownFeed(
      {required this.feedUrl, required this.name, required this.kind});
}

// Handles are domains or DIDs (did:plc:…), so dots and colons stay in.
final _blueskyProfileRe = RegExp(r'^/profile/([A-Za-z0-9.:_-]+)/?$');

// Mastodon usernames are letters, digits and underscores. A second @ is a
// remote account seen from this server, whose .rss is not served here.
final _mastodonProfileRe = RegExp(r'^/@([A-Za-z0-9_]+)/?$');

/// Hosts whose profiles also read `/@user` and are not Mastodon. Medium
/// and YouTube have feeds of their own, found by discovery.
const _notMastodon = [
  'medium.com',
  'youtube.com',
  'substack.com',
  'threads.net',
  'threads.com',
  'tiktok.com',
  'instagram.com',
  'x.com',
  'twitter.com',
  'bsky.app',
];

/// The feed behind [url] when it is a profile or publication front page
/// whose feed address is a fixed rule; null for anything else, a post or
/// status on those same sites included.
KnownFeed? knownFeedOf(Uri url) {
  if (url.scheme != 'https' && url.scheme != 'http') return null;
  final host = url.host.toLowerCase();
  if (host.isEmpty) return null;
  final path = url.path;

  if (host == 'bsky.app' || host == 'www.bsky.app') {
    final m = _blueskyProfileRe.firstMatch(path);
    if (m == null) return null;
    final handle = m.group(1)!;
    return KnownFeed(
        feedUrl: 'https://bsky.app/profile/$handle/rss',
        name: '@$handle',
        kind: KnownFeedKind.bluesky);
  }

  if (hostIsOrUnder(host, 'substack.com')) {
    if (host == 'substack.com' || host == 'www.substack.com') return null;
    if (path.isNotEmpty && path != '/') return null;
    return KnownFeed(
        feedUrl: 'https://$host/feed',
        name: host.substring(0, host.length - '.substack.com'.length),
        kind: KnownFeedKind.substack);
  }

  if (_notMastodon.any((d) => hostIsOrUnder(host, d))) return null;
  final m = _mastodonProfileRe.firstMatch(path);
  if (m == null) return null;
  final user = m.group(1)!;
  return KnownFeed(
      feedUrl: 'https://$host/@$user.rss',
      name: '@$user@$host',
      kind: KnownFeedKind.mastodon);
}

final _feedPathRe = RegExp(r'/(feed|rss|atom)(\.xml)?$', caseSensitive: false);
final _feedExtRe = RegExp(r'\.(rss|atom|xml)$', caseSensitive: false);

/// Whether [url] already reads as a feed address (`/feed`, `rss.xml`), so
/// discovery has nothing to find.
bool looksLikeFeedUrl(String url) =>
    _feedPathRe.hasMatch(url) || _feedExtRe.hasMatch(url);

final _feedLinkRe = RegExp(
    '<link[^>]+type=["\']application/(rss|atom)\\+xml["\'][^>]*>',
    caseSensitive: false);
final _hrefRe = RegExp('href=["\']([^"\']+)["\']', caseSensitive: false);

/// The feed an HTML page advertises in its `<link rel="alternate">`,
/// resolved against [pageUrl]; null when it names none.
String? advertisedFeedIn(String html, String pageUrl) {
  final match = _feedLinkRe.firstMatch(html);
  if (match == null) return null;
  final href = _hrefRe.firstMatch(match.group(0)!);
  if (href == null) return null;
  final found = href.group(1)!;
  try {
    return Uri.parse(pageUrl).resolve(found).toString();
  } catch (_) {
    return found;
  }
}

/// Whether [url] is a site's front page. Nearly every blog post advertises
/// its blog's feed too; only the front page is the site itself.
bool isSiteRoot(Uri url) => url.path.isEmpty || url.path == '/';
