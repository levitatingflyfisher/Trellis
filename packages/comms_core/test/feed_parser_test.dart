/// parseRssFeed port (donor index.html ~5734): RSS 2.0 / Atom / Media-RSS
/// to typed models, entity handling (M21), enclosure selection, chapters,
/// and the 8 MB parse ceiling (M19).
library;

import 'package:comms_core/comms_core.dart';
import 'package:test/test.dart';

void main() {
  group('RSS 2.0', () {
    test('basic item fields and channel title', () {
      final feed = parseRssFeed('''
<rss version="2.0"><channel>
  <title>My Feed</title>
  <item>
    <title>  Ep 1  </title>
    <link>https://x.com/1</link>
    <pubDate>Mon, 01 Jan 2024 00:00:00 GMT</pubDate>
    <description>Hello world</description>
  </item>
</channel></rss>
''', 'https://x.com/feed');
      expect(feed.title, 'My Feed');
      expect(feed.items, hasLength(1));
      final it = feed.items.single;
      expect(it.title, 'Ep 1', reason: 'donor trims item titles');
      expect(it.link, 'https://x.com/1');
      expect(it.date, 'Mon, 01 Jan 2024 00:00:00 GMT');
      expect(it.desc, 'Hello world');
      expect(it.audio, '');
      expect(it.enclosure, isNull);
      expect(it.chapters, isNull);
      expect(it.chaptersUrl, isNull);
    });

    test('entity-encoded markup is decoded then stripped (M21)', () {
      final feed = parseRssFeed('''
<rss><channel><title>t</title><item>
  <title>e</title>
  <description>&amp;lt;script&amp;gt;evil()&amp;lt;/script&amp;gt;Safe &amp;amp; sound</description>
</item></channel></rss>
''', 'u');
      expect(feed.items.single.desc, 'evil()Safe & sound');
    });

    test('description is capped at 300 chars', () {
      final feed = parseRssFeed(
          '<rss><channel><item><description>${'x' * 400}</description>'
          '</item></channel></rss>',
          'u');
      expect(feed.items.single.desc.length, 300);
    });

    test('CDATA description with markup is stripped', () {
      final feed = parseRssFeed(
          '<rss><channel><item><description>'
          '<![CDATA[<p>Hi <b>there</b></p>]]>'
          '</description></item></channel></rss>',
          'u');
      expect(feed.items.single.desc, 'Hi there');
    });

    test('content:encoded fallback when description is missing', () {
      final feed = parseRssFeed('''
<rss xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><item>
  <content:encoded><![CDATA[Body text]]></content:encoded>
</item></channel></rss>
''', 'u');
      expect(feed.items.single.desc, 'Body text');
    });

    test('itunes:summary fallback', () {
      final feed = parseRssFeed('''
<rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><item>
  <itunes:summary>Sum</itunes:summary>
</item></channel></rss>
''', 'u');
      expect(feed.items.single.desc, 'Sum');
    });

    test('HTML-only entities in titles are decoded on top of XML decoding '
        '(donor double-decode via textarea)', () {
      final feed = parseRssFeed(
          '<rss><channel><title>A &amp;mdash; B</title><item>'
          '<title>Tom &amp; Jerry &#8212; go</title>'
          '</item></channel></rss>',
          'u');
      expect(feed.title, 'A — B');
      expect(feed.items.single.title, 'Tom & Jerry — go');
    });

    test('feed title falls back to the feed URL', () {
      final feed = parseRssFeed(
          '<rss><channel><item><title>e</title></item></channel></rss>',
          'https://x.com/feed');
      expect(feed.title, 'https://x.com/feed');
    });
  });

  group('enclosure selection (donor findAudio)', () {
    test('standard RSS enclosure with audio type', () {
      final feed = parseRssFeed(
          '<rss><channel><item>'
          '<enclosure url="https://x/e.mp3" type="audio/mpeg" length="1"/>'
          '</item></channel></rss>',
          'u');
      expect(feed.items.single.audio, 'https://x/e.mp3');
      expect(feed.items.single.enclosure!.type, 'audio/mpeg');
    });

    test('non-audio enclosure accepted when the URL looks like audio', () {
      final feed = parseRssFeed(
          '<rss><channel><item>'
          '<enclosure url="https://x/e.mp3?tk=1"/>'
          '</item></channel></rss>',
          'u');
      expect(feed.items.single.audio, 'https://x/e.mp3?tk=1');
    });

    test('image enclosure is skipped, Media-RSS content found instead', () {
      final feed = parseRssFeed('''
<rss xmlns:media="http://search.yahoo.com/mrss/"><channel><item>
  <enclosure url="https://x/cover.jpg" type="image/jpeg"/>
  <media:group><media:content url="https://x/e.m4a" type="audio/mp4"/></media:group>
</item></channel></rss>
''', 'u');
      expect(feed.items.single.audio, 'https://x/e.m4a');
    });

    test('Media-RSS medium="audio" without a MIME type', () {
      final feed = parseRssFeed('''
<rss xmlns:media="http://search.yahoo.com/mrss/"><channel><item>
  <media:content url="https://x/sound" medium="audio"/>
</item></channel></rss>
''', 'u');
      expect(feed.items.single.audio, 'https://x/sound');
    });
  });

  group('Atom', () {
    const atom = '''
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>AF</title>
  <entry>
    <title>E1</title>
    <link rel="alternate" href="https://x/1"/>
    <link rel="enclosure" type="audio/mpeg" href="https://x/1.mp3"/>
    <published>2024-01-01T00:00:00Z</published>
    <summary>S</summary>
  </entry>
  <entry>
    <title>E2</title>
    <link href="https://x/2"/>
    <updated>2024-02-02T00:00:00Z</updated>
    <content>Full body here</content>
  </entry>
</feed>
''';

    test('entries parsed when there are no RSS items', () {
      final feed = parseRssFeed(atom, 'u');
      expect(feed.title, 'AF');
      expect(feed.items, hasLength(2));
      final e1 = feed.items[0];
      expect(e1.title, 'E1');
      expect(e1.link, 'https://x/1', reason: 'rel=alternate preferred');
      expect(e1.date, '2024-01-01T00:00:00Z');
      expect(e1.desc, 'S');
      expect(e1.audio, 'https://x/1.mp3');
      final e2 = feed.items[1];
      expect(e2.link, 'https://x/2', reason: 'first link as fallback');
      expect(e2.date, '2024-02-02T00:00:00Z', reason: 'updated fallback');
      expect(e2.desc, 'Full body here', reason: 'content fallback');
      expect(e2.audio, '');
    });

    test('RSS items win over Atom entries (donor: entries only when no items)',
        () {
      final feed = parseRssFeed(
          '<rss><channel><item><title>R</title></item>'
          '<entry><title>A</title></entry></channel></rss>',
          'u');
      expect(feed.items, hasLength(1));
      expect(feed.items.single.title, 'R');
    });
  });

  group('chapters (donor findChapters)', () {
    test('inline psc:chapters with timestamp parsing', () {
      final feed = parseRssFeed('''
<rss xmlns:psc="http://podlove.org/simple-chapters"><channel><item>
  <title>C</title>
  <psc:chapters>
    <psc:chapter start="1:02:03.5" title="Intro" href="h" image="i"/>
    <psc:chapter start="02:30" title="Two"/>
    <psc:chapter start="90" title="Sec"/>
    <psc:chapter start="abc" title="Bad"/>
  </psc:chapters>
</item></channel></rss>
''', 'u');
      final chs = feed.items.single.chapters!;
      expect(chs, hasLength(4));
      expect(chs[0].start, 3723.5);
      expect(chs[0].title, 'Intro');
      expect(chs[0].href, 'h');
      expect(chs[0].image, 'i');
      expect(chs[1].start, 150.0);
      expect(chs[2].start, 90.0);
      expect(chs[3].start, 0.0,
          reason: 'donor: Number("abc")||0 for single-part timestamps');
      expect(feed.items.single.chaptersUrl, isNull);
    });

    test('multi-part unparseable timestamp propagates NaN (donor quirk)', () {
      final feed = parseRssFeed('''
<rss xmlns:psc="http://podlove.org/simple-chapters"><channel><item>
  <psc:chapters><psc:chapter start="ab:cd" title="N"/></psc:chapters>
</item></channel></rss>
''', 'u');
      expect(feed.items.single.chapters!.single.start.isNaN, isTrue);
    });

    test('podcast:chapters url form yields chaptersUrl', () {
      final feed = parseRssFeed('''
<rss xmlns:podcast="https://podcastindex.org/namespace/1.0"><channel><item>
  <podcast:chapters url="https://x/ch.json" type="application/json+chapters"/>
</item></channel></rss>
''', 'u');
      expect(feed.items.single.chapters, isNull);
      expect(feed.items.single.chaptersUrl, 'https://x/ch.json');
    });

    test('non-direct-child chapters wrappers are ignored', () {
      final feed = parseRssFeed('''
<rss xmlns:psc="http://podlove.org/simple-chapters"><channel><item>
  <extra><psc:chapters><psc:chapter start="5" title="X"/></psc:chapters></extra>
</item></channel></rss>
''', 'u');
      expect(feed.items.single.chapters, isNull);
      expect(feed.items.single.chaptersUrl, isNull);
    });
  });

  group('RFC 5005 paged-feed links', () {
    test('rel=next at channel level is captured', () {
      final feed = parseRssFeed('''
<rss><channel>
  <title>t</title>
  <atom:link rel="next" href="https://x.test/feed?page=2"/>
  <item><title>e</title></item>
</channel></rss>
''', 'https://x.test/feed');
      expect(feed.nextPageUrl, 'https://x.test/feed?page=2');
      expect(feed.nextPageRel, 'next');
    });

    test('rel=prev-archive is used when rel=next is absent', () {
      final feed = parseRssFeed('''
<rss><channel>
  <title>t</title>
  <atom:link rel="prev-archive" href="https://x.test/feed?page=old"/>
</channel></rss>
''', 'https://x.test/feed');
      expect(feed.nextPageUrl, 'https://x.test/feed?page=old');
      expect(feed.nextPageRel, 'prev-archive');
    });

    test('rel=next wins over a rel=prev-archive on the same channel', () {
      final feed = parseRssFeed('''
<rss><channel>
  <title>t</title>
  <atom:link rel="prev-archive" href="https://x.test/feed?page=old"/>
  <atom:link rel="next" href="https://x.test/feed?page=2"/>
</channel></rss>
''', 'https://x.test/feed');
      expect(feed.nextPageUrl, 'https://x.test/feed?page=2');
      expect(feed.nextPageRel, 'next');
    });

    test('neither link present yields null/null', () {
      final feed =
          parseRssFeed('<rss><channel><title>t</title></channel></rss>', 'u');
      expect(feed.nextPageUrl, isNull);
      expect(feed.nextPageRel, isNull);
    });

    test('multiple unrelated link rels ignored (self/alternate), next found '
        'among them', () {
      final feed = parseRssFeed('''
<rss><channel>
  <title>t</title>
  <atom:link rel="self" href="https://x.test/feed"/>
  <atom:link rel="alternate" href="https://x.test/"/>
  <atom:link rel="next" href="https://x.test/feed?page=2"/>
</channel></rss>
''', 'u');
      expect(feed.nextPageUrl, 'https://x.test/feed?page=2');
    });

    test('garbage: rel=next with no href is ignored, not a crash', () {
      final feed = parseRssFeed('''
<rss><channel>
  <title>t</title>
  <atom:link rel="next"/>
</channel></rss>
''', 'u');
      expect(feed.nextPageUrl, isNull);
    });

    test('garbage: rel=next with an empty href falls through to '
        'prev-archive', () {
      final feed = parseRssFeed('''
<rss><channel>
  <title>t</title>
  <atom:link rel="next" href=""/>
  <atom:link rel="prev-archive" href="https://x.test/feed?page=old"/>
</channel></rss>
''', 'u');
      expect(feed.nextPageUrl, 'https://x.test/feed?page=old');
      expect(feed.nextPageRel, 'prev-archive');
    });

    test('an item-level rel=next link does not leak to the feed level', () {
      final feed = parseRssFeed('''
<rss><channel>
  <title>t</title>
  <item>
    <title>e</title>
    <atom:link rel="next" href="https://x.test/not-a-feed-page"/>
  </item>
</channel></rss>
''', 'u');
      expect(feed.nextPageUrl, isNull);
    });

    test('Atom feed root (no separate channel element) is supported', () {
      final feed = parseRssFeed('''
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>AF</title>
  <link rel="next" href="https://x.test/feed?page=2"/>
  <entry><title>E1</title></entry>
</feed>
''', 'u');
      expect(feed.nextPageUrl, 'https://x.test/feed?page=2');
      expect(feed.nextPageRel, 'next');
    });

    test('a relative href is resolved against the feed URL', () {
      final feed = parseRssFeed('''
<rss><channel>
  <title>t</title>
  <atom:link rel="next" href="/feed?page=2"/>
</channel></rss>
''', 'https://x.test/podcast/feed');
      expect(feed.nextPageUrl, 'https://x.test/feed?page=2');
    });

    test('a query-only relative href resolves against the feed URL', () {
      final feed = parseRssFeed('''
<rss><channel>
  <title>t</title>
  <atom:link rel="next" href="?paged=2"/>
</channel></rss>
''', 'https://x.test/feed');
      expect(feed.nextPageUrl, 'https://x.test/feed?paged=2');
    });
  });

  group('guards', () {
    test('invalid XML throws the donor message', () {
      expect(
          () => parseRssFeed('this is not xml <', 'u'),
          throwsA(isA<FeedParseException>().having((e) => e.message, 'message',
              contains('Not valid XML'))));
    });

    test('oversized input refuses to parse (M19)', () {
      final big = 'x' * (8 * 1024 * 1024 + 1);
      expect(
          () => parseRssFeed(big, 'u'),
          throwsA(isA<FeedParseException>().having((e) => e.message, 'message',
              contains('too large to parse safely'))));
    });
  });

  group('decodeHtmlEntities', () {
    test('named, numeric and hex references', () {
      expect(decodeHtmlEntities('&amp;'), '&');
      expect(decodeHtmlEntities('&lt;b&gt;'), '<b>');
      expect(decodeHtmlEntities('&#233;'), 'é');
      expect(decodeHtmlEntities('&#x1F600;'), '😀');
      expect(decodeHtmlEntities('&mdash;&nbsp;&rsquo;'), '— ’');
    });

    test('unknown references stay literal', () {
      expect(decodeHtmlEntities('&notarealentity;'), '&notarealentity;');
    });

    test('references without a trailing semicolon stay literal '
        '(deviation: the donor textarea decoded a legacy subset)', () {
      expect(decodeHtmlEntities('&amp x'), '&amp x');
    });

    test('empty and null-ish input', () {
      expect(decodeHtmlEntities(''), '');
      expect(decodeHtmlEntities('no entities'), 'no entities');
    });
  });
}
