/// Tracking-parameter stripping (the Miniflux lesson, Campaign 5 Phase 4).
///
/// Applied to outbound article/river links and dedup canonicalization —
/// NEVER to feed fetch URLs themselves: a feed URL's query params can be
/// load-bearing (API keys, pagination cursors, auth tokens), and this
/// normalizer has no way to tell those apart from tracking noise. Callers
/// enforce that boundary; this file only strips what's on the list.
library;

/// The curated, documented tracking-parameter list. Conservative on
/// purpose: a parameter only belongs here when it is KNOWN to be
/// tracking-only across the sites that set it — never a parameter that
/// could plausibly be load-bearing for the page itself. Matched
/// case-insensitively.
const trackerParams = <String>{
  // Google/GA UTM family.
  'utm_source', 'utm_medium', 'utm_campaign', 'utm_term', 'utm_content',
  'utm_id', 'utm_name', 'utm_cid', 'utm_reader', 'utm_referrer',
  'utm_social', 'utm_social-type',
  // Ad-platform click ids.
  'fbclid', 'gclid', 'gclsrc', 'dclid', 'msclkid', 'twclid', 'ttclid',
  'yclid',
  // Newsletter/ESP send tracking.
  'mc_eid', 'mc_cid', '_hsenc', '_hsmi', 'vero_id', 'mkt_tok',
  // Social-share referral trackers.
  'igshid', 'igsh',
};
// A plain "ref" param is deliberately NOT on this list — some sites use
// it as a real routing/referrer-code parameter the page itself reads, so
// stripping it risks breaking a legitimate link; only unambiguous
// tracking-only keys belong here.

/// Strips [trackerParams] from [url]'s query string. Everything else —
/// scheme, host, path, remaining params (including repeated ones, which
/// keep every value), and fragment — is untouched. Not a general
/// canonicalizer: no scheme/host lowercasing, no default-port removal, no
/// path normalization. A URL whose query becomes empty after stripping
/// loses its `?` entirely rather than being left as a bare `?`.
Uri stripTrackingParams(Uri url) {
  if (url.query.isEmpty) return url;
  final all = url.queryParametersAll;
  final kept = <String, List<String>>{};
  var stripped = false;
  all.forEach((key, values) {
    if (trackerParams.contains(key.toLowerCase())) {
      stripped = true;
    } else {
      kept[key] = values;
    }
  });
  if (!stripped) return url;
  if (kept.isEmpty) {
    // Uri.replace has no way to remove the query component entirely:
    // queryParameters: null means "don't touch it" (keeps the original
    // trackers) and queryParameters: {} leaves a bare trailing "?" — both
    // verified empirically, neither is what "no query string" means.
    // Rebuild without a query component instead.
    return Uri(
      scheme: url.scheme,
      userInfo: url.userInfo.isEmpty ? null : url.userInfo,
      host: url.host,
      port: url.hasPort ? url.port : null,
      path: url.path,
      fragment: url.hasFragment ? url.fragment : null,
    );
  }
  return url.replace(queryParameters: kept);
}

/// [stripTrackingParams] over a raw URL string, for dedup canonicalization
/// — never touches storage, only ever a comparison key computed fresh at
/// dedup time. An unparseable string is returned as-is (dedup simply
/// won't match a malformed URL, rather than throwing).
String canonicalizeForDedup(String raw) {
  final Uri parsed;
  try {
    parsed = Uri.parse(raw);
  } on FormatException {
    return raw;
  }
  return stripTrackingParams(parsed).toString();
}
