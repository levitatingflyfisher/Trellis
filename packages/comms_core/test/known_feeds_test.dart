/// The address-to-feed conversions a person never should have to know:
/// a Bluesky or Mastodon profile, a Substack front page. One pure function,
/// shared by the subscribe screen and the Android share sheet.
library;

import 'package:comms_core/comms_core.dart';
import 'package:test/test.dart';

KnownFeed? known(String url) => knownFeedOf(Uri.parse(url));

void main() {
  group('knownFeedOf', () {
    test('a Bluesky profile becomes its /rss', () {
      final f = known('https://bsky.app/profile/alice.example.com')!;
      expect(f.feedUrl, 'https://bsky.app/profile/alice.example.com/rss');
      expect(f.name, '@alice.example.com');
      expect(f.kind, KnownFeedKind.bluesky);
      // A trailing slash, a www, a DID handle.
      expect(known('https://bsky.app/profile/bob.bsky.social/')!.feedUrl,
          'https://bsky.app/profile/bob.bsky.social/rss');
      expect(known('https://www.bsky.app/profile/bob.bsky.social')!.feedUrl,
          'https://bsky.app/profile/bob.bsky.social/rss');
      expect(known('https://bsky.app/profile/did:plc:abc123')!.feedUrl,
          'https://bsky.app/profile/did:plc:abc123/rss');
    });

    test('a Bluesky post is not a profile', () {
      expect(known('https://bsky.app/profile/bob.bsky.social/post/3k2x'),
          isNull);
      expect(known('https://bsky.app/'), isNull);
      expect(known('https://bsky.app/profile/'), isNull);
    });

    test('a Mastodon profile becomes its .rss, on any host shape', () {
      for (final (url, feed, name) in const [
        ('https://mastodon.social/@alice', 'https://mastodon.social/@alice.rss',
            '@alice@mastodon.social'),
        ('https://hachyderm.io/@Bob_42/', 'https://hachyderm.io/@Bob_42.rss',
            '@Bob_42@hachyderm.io'),
        ('https://social.example.co.uk/@carol',
            'https://social.example.co.uk/@carol.rss',
            '@carol@social.example.co.uk'),
        ('https://fosstodon.org/@dave?ref=x', 'https://fosstodon.org/@dave.rss',
            '@dave@fosstodon.org'),
      ]) {
        final f = known(url)!;
        expect(f.feedUrl, feed, reason: url);
        expect(f.name, name, reason: url);
        expect(f.kind, KnownFeedKind.mastodon);
      }
    });

    test('a Mastodon status, a remote account and an already-feed are not '
        'profiles', () {
      expect(known('https://mastodon.social/@alice/111222333'), isNull);
      expect(known('https://mastodon.social/@alice@other.example'), isNull);
      expect(known('https://mastodon.social/@alice.rss'), isNull);
    });

    test('other sites whose profiles also look like /@user are left alone',
        () {
      for (final url in const [
        'https://medium.com/@writer',
        'https://www.youtube.com/@channel',
        'https://m.youtube.com/@channel',
        'https://substack.com/@writer',
        'https://www.threads.net/@someone',
        'https://www.threads.com/@someone',
        'https://www.tiktok.com/@someone',
        'https://www.instagram.com/@someone',
        'https://x.com/@someone',
      ]) {
        expect(known(url), isNull, reason: url);
      }
    });

    test('a Substack front page becomes its /feed', () {
      final f = known('https://pub.substack.com')!;
      expect(f.feedUrl, 'https://pub.substack.com/feed');
      expect(f.name, 'pub');
      expect(f.kind, KnownFeedKind.substack);
      expect(known('https://pub.substack.com/')!.feedUrl,
          'https://pub.substack.com/feed');
    });

    test('a Substack post, substack.com itself and a lookalike are not', () {
      expect(known('https://pub.substack.com/p/an-essay'), isNull);
      expect(known('https://substack.com/'), isNull);
      expect(known('https://www.substack.com/'), isNull);
      expect(known('https://notsubstack.com/'), isNull);
    });

    test('a plain article, a feed address and junk are not known feeds', () {
      expect(known('https://example.org/2026/10/an-essay'), isNull);
      expect(known('https://example.org/feed.xml'), isNull);
      expect(known('mailto:someone@example.org'), isNull);
      expect(known('not a url at all'), isNull);
      expect(known(''), isNull);
    });
  });

  group('looksLikeFeedUrl', () {
    test('feed paths and extensions', () {
      expect(looksLikeFeedUrl('https://x.com/feed'), isTrue);
      expect(looksLikeFeedUrl('https://x.com/rss.xml'), isTrue);
      expect(looksLikeFeedUrl('https://x.com/f.atom'), isTrue);
      expect(looksLikeFeedUrl('https://x.com/2026/an-essay'), isFalse);
    });
  });

  group('advertisedFeedIn', () {
    test('finds and resolves the page’s alternate feed link', () {
      const page = '<html><head><title>A blog</title>'
          '<link rel="alternate" type="application/rss+xml" '
          'href="/index.xml"></head></html>';
      expect(advertisedFeedIn(page, 'https://blog.example/'),
          'https://blog.example/index.xml');
    });

    test('null when the page advertises none', () {
      expect(advertisedFeedIn('<html><body>hi</body></html>',
          'https://blog.example/'), isNull);
    });
  });

  group('isSiteRoot', () {
    test('only the bare host, with or without a slash', () {
      expect(isSiteRoot(Uri.parse('https://blog.example')), isTrue);
      expect(isSiteRoot(Uri.parse('https://blog.example/')), isTrue);
      expect(isSiteRoot(Uri.parse('https://blog.example/?utm=1')), isTrue);
      expect(isSiteRoot(Uri.parse('https://blog.example/2026/post')), isFalse);
    });
  });
}
