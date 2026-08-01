/// OPML import/export port (donor index.html ~7903): the exact export
/// shape, attribute escaping, xmlUrl extraction, title precedence, and
/// the 8 MB guard.
library;

import 'package:comms_core/comms_core.dart';
import 'package:test/test.dart';

void main() {
  group('exportOpml', () {
    test('produces the donor document shape, escaped', () {
      final out = exportOpml(
        const [
          OpmlOutline(url: 'https://x.com/feed?a=1&b=2', title: 'Ada "A" <3'),
          OpmlOutline(url: 'https://y.com/rss', title: ''),
        ],
        profileName: 'Fam & Co',
        now: DateTime.utc(2026, 8, 5, 12, 0, 0),
      );
      expect(out, '''
<?xml version="1.0" encoding="UTF-8"?>
<opml version="2.0">
  <head>
    <title>Trellis subscriptions — Fam &amp; Co</title>
    <dateCreated>Wed, 05 Aug 2026 12:00:00 GMT</dateCreated>
  </head>
  <body>
    <outline type="rss" text="Ada &quot;A&quot; &lt;3" title="Ada &quot;A&quot; &lt;3" xmlUrl="https://x.com/feed?a=1&amp;b=2" />
    <outline type="rss" text="https://y.com/rss" title="https://y.com/rss" xmlUrl="https://y.com/rss" />
  </body>
</opml>
''');
    });

    test('roundtrips through parseOpml', () {
      const feeds = [
        OpmlOutline(url: 'https://x.com/feed', title: 'X'),
        OpmlOutline(url: 'https://y.com/rss', title: 'Y & Z'),
      ];
      expect(parseOpml(exportOpml(feeds, profileName: 'p')), feeds);
    });
  });

  group('parseOpml', () {
    test('extracts outlines with xmlUrl, ignoring folder outlines', () {
      final feeds = parseOpml('''
<opml version="1.0"><body>
  <outline text="Tech">
    <outline type="rss" text="A" title="A!" xmlUrl="https://a.com/feed"/>
    <outline type="rss" text="B" xmlUrl="https://b.com/feed"/>
  </outline>
  <outline text="EmptyFolder"/>
</body></opml>
''');
      expect(feeds, const [
        OpmlOutline(url: 'https://a.com/feed', title: 'A!'),
        OpmlOutline(url: 'https://b.com/feed', title: 'B'),
      ]);
    });

    test('title precedence: title, then text, then url — JS || skips '
        'empty strings', () {
      final feeds = parseOpml('''
<opml><body>
  <outline title="" text="TextTitle" xmlUrl="https://a.com/f"/>
  <outline xmlUrl="https://b.com/f"/>
</body></opml>
''');
      expect(feeds[0].title, 'TextTitle');
      expect(feeds[1].title, 'https://b.com/f');
    });

    test('xmlUrl attribute matches case-insensitively on read', () {
      // Why: fixed donor bug — its case-sensitive querySelectorAll
      // ("outline[xmlUrl]") silently dropped every feed from OPML files
      // written with xmlurl/XMLURL (real exporters disagree on the casing).
      expect(
          parseOpml('<opml><body>'
              '<outline xmlurl="https://a.com/f"/>'
              '<outline XMLURL="https://b.com/f" text="B"/>'
              '</body></opml>'),
          const [
            OpmlOutline(url: 'https://a.com/f', title: 'https://a.com/f'),
            OpmlOutline(url: 'https://b.com/f', title: 'B'),
          ]);
    });

    test('no feed outlines yields an empty list (caller shows the toast)',
        () {
      expect(parseOpml('<opml><body><outline text="folder"/></body></opml>'),
          isEmpty);
    });

    test('invalid XML throws the donor message', () {
      expect(
          () => parseOpml('<opml><body>'),
          throwsA(isA<OpmlParseException>()
              .having((e) => e.message, 'message', 'Invalid OPML file')));
    });

    test('oversized input refuses to parse', () {
      expect(
          () => parseOpml('x' * (8 * 1024 * 1024 + 1)),
          throwsA(isA<OpmlParseException>()
              .having((e) => e.message, 'message', 'OPML file is too large')));
    });
  });

  group('escapeXml (donor esc)', () {
    test('escapes the five', () {
      expect(escapeXml('&<>"\''), '&amp;&lt;&gt;&quot;&#39;');
      expect(escapeXml('plain'), 'plain');
    });
  });
}
