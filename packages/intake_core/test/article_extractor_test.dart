// Port tests for donor `extractArticle` + `scoreNode` (ohPrimer index.html
// ~3722-3761) and the feed sniff in `loadUrl` (~3697-3708). The donor JS is
// the spec, quirks included.
import 'package:intake_core/intake_core.dart';
import 'package:test/test.dart';

const _longA = 'This paragraph is comfortably longer than forty characters '
    'so it counts toward the container score.';
const _longB = 'Another substantial paragraph, also comfortably longer than '
    'forty characters, adding more weight to its container.';

void main() {
  group('feed sniff (donor loadUrl RSS/Atom detection)', () {
    test('flags <?xml, <rss, and <feed documents as feed XML', () {
      for (final s in [
        '<?xml version="1.0"?><rss version="2.0"></rss>',
        '<rss version="2.0"></rss>',
        '<rss></rss>',
        '<feed xmlns="http://www.w3.org/2005/Atom"></feed>',
        '  \n<rss version="2.0"></rss>', // leading whitespace trimmed first
      ]) {
        expect(extractArticle(s).isFeedXml, isTrue, reason: s);
      }
    });

    test('does not flag html or lookalike tags', () {
      expect(extractArticle('<html><body><p>hi</p></body></html>').isFeedXml,
          isFalse);
      expect(extractArticle('<feedback>no</feedback>').isFeedXml, isFalse);
    });

    test('feed result carries no blocks', () {
      final r = extractArticle('<rss version="2.0"></rss>');
      expect(r.blocks, isEmpty);
      expect(r.text, isEmpty);
    });
  });

  group('title (donor og:title || <title> || "Article")', () {
    test('prefers og:title over <title>', () {
      final r = extractArticle('<html><head>'
          '<meta property="og:title" content="OG Title">'
          '<title>Doc Title</title></head>'
          '<body><p>$_longA</p></body></html>');
      expect(r.title, 'OG Title');
    });

    test('falls back to <title>, then to "Article"', () {
      expect(
          extractArticle('<html><head><title>Doc Title</title></head>'
                  '<body><p>$_longA</p></body></html>')
              .title,
          'Doc Title');
      expect(extractArticle('<html><body><p>$_longA</p></body></html>').title,
          'Article');
    });

    test('whitespace-only og:title wins then trims to empty (donor || quirk)',
        () {
      final r = extractArticle('<html><head>'
          '<meta property="og:title" content="   ">'
          '<title>Doc Title</title></head>'
          '<body><p>$_longA</p></body></html>');
      expect(r.title, '');
    });
  });

  group('byline (intake_core addition — donor has none)', () {
    test('reads meta[name=author] when present, else null', () {
      final r = extractArticle('<html><head>'
          '<meta name="author" content="Jane Writer"></head>'
          '<body><p>$_longA</p></body></html>');
      expect(r.byline, 'Jane Writer');
      expect(extractArticle('<html><body><p>$_longA</p></body></html>').byline,
          isNull);
    });
  });

  group('noise stripping (donor querySelectorAll remove)', () {
    test('nav/aside/footer/script/style content is dropped', () {
      final r = extractArticle('<html><body><article>'
          '<nav><p>Navigation links that are quite long indeed here</p></nav>'
          '<p>$_longA</p>'
          '<aside><p>A sidebar paragraph that is also quite long here</p></aside>'
          '<footer><p>Footer boilerplate that is also quite long here</p></footer>'
          '<script>var x = "script text that is long enough";</script>'
          '</article></body></html>');
      expect(r.text, _longA);
    });

    test('[role=navigation] and [aria-hidden=true] elements are dropped', () {
      final r = extractArticle('<html><body><article>'
          '<div role="navigation"><p>Menu items listed here at some length</p></div>'
          '<p>$_longA</p>'
          '<div aria-hidden="true"><p>Hidden decorative text of some length</p></div>'
          '</article></body></html>');
      expect(r.text, _longA);
    });
  });

  group('container choice (donor root + scoreNode)', () {
    test('prefers <article> as the root', () {
      final r = extractArticle('<html><body>'
          '<p>Body-level paragraph outside the article element here.</p>'
          '<article><p>$_longA</p></article>'
          '</body></html>');
      expect(r.text, _longA);
    });

    test('a div with more paragraph text beats a thin <article>', () {
      final r = extractArticle('<html><body>'
          '<article><p>Thin article stub, a bit over forty characters.</p></article>'
          '<div id="real"><p>$_longA</p><p>$_longB</p></div>'
          '</body></html>');
      expect(r.text, '$_longA\n\n$_longB');
    });

    test('without article/main the body root keeps everything (strict >)', () {
      // body's score is the sum over all divs, so no single div beats it.
      final r = extractArticle('<html><body>'
          '<div><p>$_longA</p></div><div><p>$_longB</p></div>'
          '</body></html>');
      expect(r.text, '$_longA\n\n$_longB');
    });

    test('paragraphs of 40 trimmed chars or fewer score nothing', () {
      // The article has one countable paragraph; the div has only short ones,
      // so its score is 0 and the article stays root.
      final r = extractArticle('<html><body>'
          '<article><p>$_longA</p></article>'
          '<div><p>Under forty characters here.</p>'
          '<p>Also short, under forty chars.</p></div>'
          '</body></html>');
      expect(r.text, _longA);
    });
  });

  group('part extraction (donor p,h1..h6,li,blockquote,pre walk)', () {
    test('parts of 20 trimmed chars or fewer are dropped', () {
      final r = extractArticle('<html><body><article>'
          '<p>Short one.</p><p>$_longA</p>'
          '</article></body></html>');
      expect(r.text, _longA);
    });

    test('headings, list items, blockquotes, pre are captured', () {
      final r = extractArticle('<html><body><article>'
          '<h1>A Heading Long Enough To Keep</h1>'
          '<blockquote>A quotation that is long enough to keep.</blockquote>'
          '<pre>preformatted text long enough to keep</pre>'
          '</article></body></html>');
      expect(r.text, [
        'A Heading Long Enough To Keep',
        'A quotation that is long enough to keep.',
        'preformatted text long enough to keep',
      ].join('\n\n'));
    });

    test('nested matches duplicate text (donor quirk: li AND its child p)', () {
      final r = extractArticle('<html><body><article>'
          '<ul><li><p>$_longA</p></li></ul>'
          '</article></body></html>');
      expect(r.text, '$_longA\n\n$_longA');
    });

    test('whitespace is collapsed inside a part', () {
      final r = extractArticle('<html><body><article>'
          '<p>Spread   over\n   lines, yet still one paragraph of text.</p>'
          '</article></body></html>');
      expect(r.text, 'Spread over lines, yet still one paragraph of text.');
    });

    test('falls back to the root text when nothing matches', () {
      final r = extractArticle(
          '<html><body>Bare body text with no paragraph markup at all.'
          '</body></html>');
      expect(r.text, 'Bare body text with no paragraph markup at all.');
    });

    test('blocks mirror the parts as TextBlocks', () {
      final r = extractArticle('<html><body><article>'
          '<p>$_longA</p><p>$_longB</p>'
          '</article></body></html>');
      expect(r.blocks, hasLength(2));
      expect(r.blocks.whereType<TextBlock>().map((b) => b.text),
          [_longA, _longB]);
    });
  });

  test('baseUrl is echoed on the result', () {
    final r = extractArticle('<html><body><p>$_longA</p></body></html>',
        baseUrl: 'https://example.org/post');
    expect(r.url, 'https://example.org/post');
    expect(extractArticle('<html></html>').url, isNull);
  });

  group('tracking pixels (Campaign 5 Phase 4, the Miniflux lesson)', () {
    // This pins an invariant that already holds by construction, not one
    // this test file fixes: extractArticle's part tags are text-only
    // (p/h1-h6/li/blockquote/pre — see the top-level `_partTags` const),
    // so no <img> — 1x1 tracker or otherwise — has ever been able to
    // reach a block or the joined text. Confirmed with a genuine RED:
    // temporarily adding 'img' to `_partTags` plus a src-emitting branch
    // made this test fail with the tracker's URL showing up in `text`;
    // reverting that restored the invariant. No code change was needed
    // here — only this regression pin.
    test('a 1x1 tracking pixel never appears in extracted text or blocks',
        () {
      final r = extractArticle('<html><body><article>'
          '<img src="https://tracker.test/pixel.gif?id=1" width="1" '
          'height="1">'
          '<p>$_longA</p>'
          '<img src="https://cdn.test/hero.jpg" alt="A real photo">'
          '<p>$_longB</p>'
          '</article></body></html>');

      expect(r.text, isNot(contains('tracker.test')));
      expect(r.text, isNot(contains('cdn.test')));
      expect(r.blocks, hasLength(2),
          reason: 'exactly the two prose paragraphs — neither image, '
              'tracker or real, becomes a block');
      expect(r.blocks.whereType<TextBlock>().map((b) => b.text),
          [_longA, _longB]);
    });
  });
}
