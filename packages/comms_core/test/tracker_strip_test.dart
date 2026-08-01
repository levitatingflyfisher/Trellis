import 'package:comms_core/comms_core.dart';
import 'package:test/test.dart';

/// The Miniflux lesson (Campaign 5 Phase 4): strip known tracking
/// parameters from outbound article/river links and dedup
/// canonicalization — NEVER from feed fetch URLs themselves (a feed
/// URL's query params can be load-bearing: API keys, pagination tokens).
/// This file only exercises [stripTrackingParams]; the "never touches
/// feed fetch URLs" law is structural (feed fetches never call it), not
/// something this file alone can prove — the app-level integration test
/// covers that.
void main() {
  group('stripTrackingParams', () {
    test('strips a utm_* parameter', () {
      final url = Uri.parse('https://a.test/post?utm_source=newsletter');
      expect(stripTrackingParams(url).toString(), 'https://a.test/post');
    });

    test('strips fbclid, gclid, and mc_eid together', () {
      final url = Uri.parse(
          'https://a.test/post?fbclid=1&gclid=2&mc_eid=3');
      expect(stripTrackingParams(url).toString(), 'https://a.test/post');
    });

    test('strips igshid', () {
      final url = Uri.parse('https://a.test/post?igshid=abc123');
      expect(stripTrackingParams(url).toString(), 'https://a.test/post');
    });

    test('keeps a real, non-tracking query parameter', () {
      final url = Uri.parse('https://a.test/post?id=42');
      expect(stripTrackingParams(url).toString(), 'https://a.test/post?id=42');
    });

    test('strips tracking params but keeps real ones alongside them', () {
      final url =
          Uri.parse('https://a.test/post?id=42&utm_source=newsletter');
      expect(stripTrackingParams(url).toString(), 'https://a.test/post?id=42');
    });

    test('a plain "ref" param is kept — ambiguous, deliberately not '
        'on the curated list', () {
      final url = Uri.parse('https://a.test/post?ref=42');
      expect(stripTrackingParams(url).toString(), 'https://a.test/post?ref=42');
    });

    test('a URL with no query string is returned unchanged', () {
      final url = Uri.parse('https://a.test/post');
      expect(stripTrackingParams(url).toString(), 'https://a.test/post');
    });

    test('a URL with only tracking params loses the query string entirely '
        '(no bare "?")', () {
      final url = Uri.parse('https://a.test/post?utm_source=x&fbclid=y');
      expect(stripTrackingParams(url).toString(), 'https://a.test/post');
    });

    test('matching is case-insensitive on the parameter name', () {
      final url = Uri.parse('https://a.test/post?UTM_Source=newsletter');
      expect(stripTrackingParams(url).toString(), 'https://a.test/post');
    });

    test('path, host, scheme, and fragment are untouched', () {
      final url = Uri.parse(
          'https://a.test/deep/path?utm_source=x&id=1#section');
      expect(stripTrackingParams(url).toString(),
          'https://a.test/deep/path?id=1#section');
    });

    test('a repeated real parameter keeps every value', () {
      final url = Uri.parse('https://a.test/post?tag=a&tag=b&utm_source=x');
      final result = stripTrackingParams(url);
      expect(result.queryParametersAll['tag'], ['a', 'b']);
      expect(result.queryParameters.containsKey('utm_source'), isFalse);
    });
  });

  group('canonicalizeForDedup', () {
    test('strips trackers from a valid URL string', () {
      expect(canonicalizeForDedup('https://a.test/post?utm_source=x'),
          'https://a.test/post');
    });

    test('two links differing only by tracker params canonicalize the same',
        () {
      final a = canonicalizeForDedup(
          'https://a.test/post?utm_source=newsletter&utm_medium=email');
      final b = canonicalizeForDedup('https://a.test/post?fbclid=xyz');
      expect(a, b);
    });

    test('an unparseable string is returned as-is rather than throwing', () {
      expect(canonicalizeForDedup('not a url at all ::::'),
          'not a url at all ::::');
    });
  });
}
