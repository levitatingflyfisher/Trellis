/// discoverFeedUrl port (donor index.html ~6273): feed-looking URLs pass
/// through, XML sniffing, `<link type="application/rss+xml">` discovery,
/// and the known-host + generic guess ladder (Substack/Medium/YouTube/
/// WordPress-style), deduped and probed in order.
library;

import 'package:comms_core/comms_core.dart';
import 'package:test/test.dart';

import 'scripted_fetcher.dart';

const html = '<html><body>just a page</body></html>';

/// Scripted world: exact-URL → body text. Anything unlisted returns
/// a 200 "nope" page.
CommsClient worldClient(ScriptedFetcher fetcher) =>
    CommsClient(fetcher: fetcher, consent: FakeConsent());

ScriptedFetcher world(Map<String, String> pages) => ScriptedFetcher(
    (url, headers) => textResponse(pages[url.toString()] ?? 'nope'));

void main() {
  test('feed-looking URLs pass through without any fetch', () async {
    final fetcher = world(const {});
    final client = worldClient(fetcher);
    for (final url in [
      'https://x.com/feed',
      'https://x.com/rss',
      'https://x.com/atom',
      'https://x.com/feed.xml',
      'https://x.com/f.rss',
      'https://x.com/f.atom',
      'https://x.com/sitemap.xml',
    ]) {
      expect(await client.discoverFeedUrl(url), url);
    }
    expect(fetcher.calls, isEmpty);
  });

  test('a URL that already serves XML is kept (with leading whitespace)',
      () async {
    final fetcher = world(const {
      'https://x.com/blog': '\n  <?xml version="1.0"?><rss/>',
    });
    expect(await worldClient(fetcher).discoverFeedUrl('https://x.com/blog'),
        'https://x.com/blog');
    expect(fetcher.calls, hasLength(1));
  });

  test('bare <rss and <feed sniff too', () async {
    final f1 = world(const {'https://x.com/a': '<rss version="2.0"/>'});
    expect(await worldClient(f1).discoverFeedUrl('https://x.com/a'),
        'https://x.com/a');
    final f2 = world(const {'https://x.com/b': '<feed xmlns="a"/>'});
    expect(await worldClient(f2).discoverFeedUrl('https://x.com/b'),
        'https://x.com/b');
  });

  test('link-tag discovery resolves relative hrefs against the page URL',
      () async {
    final fetcher = world(const {
      'https://x.com/blog/post':
          '<html><head><link rel="alternate" type="application/rss+xml" '
              'href="/blog/feed.xml"></head></html>',
    });
    expect(
        await worldClient(fetcher).discoverFeedUrl('https://x.com/blog/post'),
        'https://x.com/blog/feed.xml');
  });

  test('link-tag discovery keeps absolute hrefs', () async {
    final fetcher = world(const {
      'https://x.com/p':
          '<link type="application/atom+xml" href="https://cdn.x.com/f.atom">',
    });
    expect(await worldClient(fetcher).discoverFeedUrl('https://x.com/p'),
        'https://cdn.x.com/f.atom');
  });

  test('page fetch failing gives the URL back unchanged', () async {
    final fetcher =
        ScriptedFetcher((url, headers) => textResponse('x', status: 500));
    expect(await worldClient(fetcher).discoverFeedUrl('https://x.com/dead'),
        'https://x.com/dead');
  });

  group('guess ladder', () {
    test('substack host guesses /feed first', () async {
      final fetcher = world(const {
        'https://foo.substack.com/p/post': html,
        'https://foo.substack.com/feed': '<rss/>',
      });
      expect(
          await worldClient(fetcher)
              .discoverFeedUrl('https://foo.substack.com/p/post'),
          'https://foo.substack.com/feed');
      expect(fetcher.calls, hasLength(2));
    });

    test('substack /feed guess is deduped against the generic /feed', () async {
      final fetcher = world(const {'https://foo.substack.com/p/post': html});
      await worldClient(fetcher)
          .discoverFeedUrl('https://foo.substack.com/p/post');
      final feedProbes = fetcher.calls
          .where((c) => c.url.toString() == 'https://foo.substack.com/feed');
      expect(feedProbes, hasLength(1));
    });

    test('medium @user guesses medium.com/feed/@user', () async {
      final fetcher = world(const {
        'https://medium.com/@user/story-1': html,
        'https://medium.com/feed/@user': '<feed/>',
      });
      expect(
          await worldClient(fetcher)
              .discoverFeedUrl('https://medium.com/@user/story-1'),
          'https://medium.com/feed/@user');
    });

    test('youtube channel URL guesses the videos.xml feed', () async {
      final fetcher = world(const {
        'https://www.youtube.com/channel/UCabc_123': html,
        'https://www.youtube.com/feeds/videos.xml?channel_id=UCabc_123':
            '<feed/>',
      });
      expect(
          await worldClient(fetcher)
              .discoverFeedUrl('https://www.youtube.com/channel/UCabc_123'),
          'https://www.youtube.com/feeds/videos.xml?channel_id=UCabc_123');
    });

    test('generic guesses probe in donor order and give up to the input',
        () async {
      final fetcher = world(const {'https://blog.example.com/post': html});
      expect(
          await worldClient(fetcher)
              .discoverFeedUrl('https://blog.example.com/post'),
          'https://blog.example.com/post');
      final probes = fetcher.calls.skip(1).map((c) => c.url.toString());
      expect(probes, [
        'https://blog.example.com/feed',
        'https://blog.example.com/feed/',
        'https://blog.example.com/rss',
        'https://blog.example.com/rss/',
        'https://blog.example.com/atom.xml',
        'https://blog.example.com/rss.xml',
        'https://blog.example.com/index.xml',
      ]);
    });

    test('lookalike host notmedium.com never probes medium.com', () async {
      // Why: fixed donor bug — its unanchored /medium\.com$/ matched
      // notmedium.com and sent the path to medium.com proper.
      final fetcher = world(const {'https://notmedium.com/@user/story-1': html});
      await worldClient(fetcher)
          .discoverFeedUrl('https://notmedium.com/@user/story-1');
      expect(fetcher.calls.map((c) => c.url.host),
          everyElement('notmedium.com'));
    });

    test('host matching is anchored: notsubstack.com is not substack.com', () {
      // Why: fixed donor bug — unanchored host regexes matched any host
      // that merely ENDS in the known domain. (Behaviorally invisible for
      // Substack — its /feed guess dedupes against the generic ladder — so
      // the anchored matcher is asserted directly.)
      expect(hostIsOrUnder('notsubstack.com', 'substack.com'), isFalse);
      expect(hostIsOrUnder('substack.com', 'substack.com'), isTrue);
      expect(hostIsOrUnder('foo.substack.com', 'substack.com'), isTrue);
      expect(hostIsOrUnder('notmedium.com', 'medium.com'), isFalse);
    });

    test('a later guess can win', () async {
      final fetcher = world(const {
        'https://blog.example.com/post': html,
        'https://blog.example.com/index.xml': '<?xml version="1.0"?><rss/>',
      });
      expect(
          await worldClient(fetcher)
              .discoverFeedUrl('https://blog.example.com/post'),
          'https://blog.example.com/index.xml');
    });
  });
}
