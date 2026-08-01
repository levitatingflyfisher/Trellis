// iTunes podcast directory search (itunes.apple.com/search?media=podcast):
// URL building and result mapping on a real-shaped fixture. Text results
// only — artwork URLs are mapped as strings, never fetched.
import 'dart:convert';

import 'package:comms_core/comms_core.dart';
import 'package:test/test.dart';

/// Real-shaped iTunes Search API response (fields as the live API returns
/// them; values shortened).
final _fixture = jsonEncode({
  'resultCount': 3,
  'results': [
    {
      'wrapperType': 'track',
      'kind': 'podcast',
      'collectionId': 201671138,
      'trackId': 201671138,
      'artistName': 'WNYC Studios',
      'collectionName': 'Radiolab',
      'trackName': 'Radiolab',
      'feedUrl': 'https://feeds.simplecast.com/EmVW7VGp',
      'artworkUrl30': 'https://is1-ssl.mzstatic.com/image/30x30bb.jpg',
      'artworkUrl60': 'https://is1-ssl.mzstatic.com/image/60x60bb.jpg',
      'artworkUrl100': 'https://is1-ssl.mzstatic.com/image/100x100bb.jpg',
      'collectionPrice': 0.0,
      'primaryGenreName': 'Documentary',
      'genres': ['Documentary', 'Podcasts', 'Science'],
    },
    {
      // A directory entry with no feed — nothing to subscribe to; dropped.
      'wrapperType': 'track',
      'kind': 'podcast',
      'collectionId': 999,
      'artistName': 'Feedless Person',
      'collectionName': 'No Feed Here',
      'artworkUrl100': 'https://is1-ssl.mzstatic.com/image/x.jpg',
    },
    {
      // Sparse but subscribable: artist and artwork missing.
      'wrapperType': 'track',
      'kind': 'podcast',
      'collectionId': 42,
      'collectionName': 'Quiet Hours',
      'feedUrl': 'https://quiet.example/feed.xml',
    },
  ],
});

void main() {
  group('buildItunesSearchUrl', () {
    test('targets itunes.apple.com/search with media=podcast and the term',
        () {
      final u = buildItunesSearchUrl('night sky');
      expect(u.scheme, 'https');
      expect(u.host, 'itunes.apple.com');
      expect(u.path, '/search');
      expect(u.queryParameters['media'], 'podcast');
      expect(u.queryParameters['term'], 'night sky');
      expect(int.parse(u.queryParameters['limit']!), inInclusiveRange(1, 50));
    });

    test('term is encoded on the wire (a literal & cannot split params)', () {
      final u = buildItunesSearchUrl('this & that');
      expect(u.query, contains('%26'));
      expect(u.queryParameters['term'], 'this & that');
    });
  });

  group('parseItunesSearchResults', () {
    test('maps collectionName / artistName / feedUrl / artwork string', () {
      final results = parseItunesSearchResults(_fixture);
      final radiolab = results.first;
      expect(radiolab.collectionName, 'Radiolab');
      expect(radiolab.artistName, 'WNYC Studios');
      expect(radiolab.feedUrl, 'https://feeds.simplecast.com/EmVW7VGp');
      expect(radiolab.artworkUrl,
          'https://is1-ssl.mzstatic.com/image/100x100bb.jpg');
    });

    test('entries without a feedUrl are dropped — nothing to subscribe to',
        () {
      final results = parseItunesSearchResults(_fixture);
      expect(results, hasLength(2));
      expect(results.map((r) => r.collectionName),
          isNot(contains('No Feed Here')));
    });

    test('sparse entries survive with calm blanks', () {
      final quiet = parseItunesSearchResults(_fixture).last;
      expect(quiet.collectionName, 'Quiet Hours');
      expect(quiet.artistName, '');
      expect(quiet.feedUrl, 'https://quiet.example/feed.xml');
      expect(quiet.artworkUrl, isNull);
    });

    test('zero results is an empty list, not an error', () {
      expect(
          parseItunesSearchResults(
              jsonEncode({'resultCount': 0, 'results': <Object?>[]})),
          isEmpty);
    });

    test('malformed JSON or a shape without results throws FormatException',
        () {
      expect(() => parseItunesSearchResults('<html>error</html>'),
          throwsA(isA<FormatException>()));
      expect(() => parseItunesSearchResults('{"answer": 42}'),
          throwsA(isA<FormatException>()));
    });
  });
}
