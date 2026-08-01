/// comms_core — the network-hygiene core.
///
/// SSRF guard, proxy-consent gating, mid-stream size caps, charset decoding,
/// RSS/Atom/Media-RSS parsing, conditional GET, refresh breaker state,
/// feed discovery and OPML — pure Dart, all HTTP behind [HttpFetcher].
library;

export 'src/comms_client.dart';
export 'src/decode.dart';
export 'src/exceptions.dart';
export 'src/feed_archive.dart';
export 'src/feed_fetch_result.dart';
export 'src/feed_models.dart';
export 'src/feed_parser.dart';
export 'src/feed_refresh_state.dart';
export 'src/http_date.dart';
export 'src/http_fetcher.dart';
export 'src/limits.dart';
export 'src/opml.dart';
export 'src/podcast_search.dart';
export 'src/safe_url.dart';
export 'src/tracker_strip.dart';
