/// Skein: the household daemon. Serves the Trellis web build and fetches
/// on the app's behalf so the page and its fetcher share one origin and
/// CORS dissolves. Localhost-only in v1 — see docs/adr/0005 in the Trellis
/// repo for why, and the open LAN/phone-tier problem it deliberately does
/// not solve yet.
library;

export 'src/fetch_route.dart'
    show
        SkeinFetcher,
        skeinErrorHeader,
        forwardableRequestHeaders,
        forwardableResponseHeaders;
export 'src/skein_server.dart';
export 'src/host_guard.dart' show HostResolver, isUnsafeResolvedAddress;
export 'src/limits.dart' show skeinMaxFetchBytes;
export 'src/mime_types.dart' show mimeTypeFor;
export 'src/static_files.dart' show resolveStaticFile;
export 'src/version.dart' show skeinVersion;
