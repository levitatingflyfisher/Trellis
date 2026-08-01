/// iTunes podcast directory search — the one public catalogue with no key
/// and no account (`https://itunes.apple.com/search?media=podcast&term=…`).
///
/// Pure logic only: build the search URL, map the JSON. The caller fetches
/// through its own guarded seam; the `feedUrl` each result carries comes off
/// the wire, so it must go back through `assertSafeFetchUrl` (the existing
/// subscribe-by-URL path does exactly that) before anyone fetches it.
///
/// Calm by construction: results are text. [PodcastSearchResult.artworkUrl]
/// is mapped as a string for completeness and is never fetched — a search
/// screen built on this stays a list of names, not a wall of covers.
library;

import 'dart:convert';

/// One directory hit, mapped down to what a text-only picker needs.
class PodcastSearchResult {
  /// The show's name (iTunes `collectionName`, falling back to `trackName`).
  final String collectionName;

  /// The publisher (iTunes `artistName`); empty when the directory has none.
  final String artistName;

  /// The show's RSS feed — what subscribe-by-URL actually consumes.
  final String feedUrl;

  /// Artwork address, mapped but NEVER fetched by this line of code.
  final String? artworkUrl;

  const PodcastSearchResult({
    required this.collectionName,
    required this.artistName,
    required this.feedUrl,
    this.artworkUrl,
  });
}

/// `https://itunes.apple.com/search?media=podcast&term=<term>&limit=<limit>`.
///
/// Browser CORS reality, stated once at the source: itunes.apple.com sends
/// no `Access-Control-Allow-Origin` header, so on the web tier the browser
/// refuses this fetch and the caller's calm transport sentence shows. That
/// is the honest behaviour — no proxy workaround, by design.
Uri buildItunesSearchUrl(String term, {int limit = 25}) =>
    Uri.https('itunes.apple.com', '/search',
        {'media': 'podcast', 'term': term, 'limit': '$limit'});

/// Maps one iTunes Search response. Entries without a `feedUrl` are dropped
/// (there is nothing to subscribe to). Throws [FormatException] when the
/// body is not JSON or not shaped like a search response — the caller turns
/// that into a calm sentence.
List<PodcastSearchResult> parseItunesSearchResults(String body) {
  final Object? decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic> || decoded['results'] is! List) {
    throw const FormatException('Not an iTunes search response.');
  }
  return [
    for (final r in decoded['results'] as List)
      if (r is Map<String, dynamic> &&
          r['feedUrl'] is String &&
          (r['feedUrl'] as String).isNotEmpty)
        PodcastSearchResult(
          collectionName: (r['collectionName'] as String?) ??
              (r['trackName'] as String?) ??
              '',
          artistName: (r['artistName'] as String?) ?? '',
          feedUrl: r['feedUrl'] as String,
          artworkUrl: (r['artworkUrl100'] as String?) ??
              (r['artworkUrl600'] as String?) ??
              (r['artworkUrl60'] as String?),
        ),
  ];
}
