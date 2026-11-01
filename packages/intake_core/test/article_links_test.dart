// Frozen references (owner ask, 21 and 24 Oct 2026): an extracted article
// keeps where its links are, so the reader can make the cited words
// tappable and keep copies of the pages they point to.
import 'package:intake_core/intake_core.dart';
import 'package:test/test.dart';

const _filler = 'and enough further words that the paragraph is long';

String _page(String body) =>
    '<html><head><title>T</title></head><body><article>$body'
    '<p>${'A second paragraph with plenty of plain words in it. ' * 6}</p>'
    '</article></body></html>';

TextBlock _first(ArticleResult r) => r.blocks.first as TextBlock;

void main() {
  test('a link keeps its words and its place in the text', () {
    final r = extractArticle(
        _page('<p>See <a href="https://example.org/a">the first study</a> '
            '$_filler.</p>'),
        baseUrl: 'https://blog.test/post');
    final b = _first(r);
    expect(b.links, hasLength(1));
    final l = b.links.single;
    expect(b.text.substring(l.start, l.end), 'the first study');
    expect(l.href, 'https://example.org/a');
  });

  test('offsets survive collapsed and trimmed whitespace', () {
    final r = extractArticle(
        _page('<p>\n   Read   <a href="/b">\n  this \n page </a>  now '
            '$_filler.</p>'),
        baseUrl: 'https://blog.test/x/post');
    final b = _first(r);
    final l = b.links.single;
    expect(b.text.substring(l.start, l.end), 'this page');
    expect(l.href, 'https://blog.test/b', reason: 'resolved against the page');
  });

  test('links inside nested inline tags are found', () {
    final r = extractArticle(
        _page('<p>One <em><a href="https://a.test/1">alpha</a></em> and '
            '<a href="https://b.test/2"><strong>beta</strong> two</a> '
            '$_filler.</p>'),
        baseUrl: 'https://blog.test/');
    final b = _first(r);
    expect([for (final l in b.links) b.text.substring(l.start, l.end)],
        ['alpha', 'beta two']);
    expect([for (final l in b.links) l.href],
        ['https://a.test/1', 'https://b.test/2']);
  });

  test('only web links are kept: no mailto, javascript, bare fragments, '
      'or empty words', () {
    final r = extractArticle(
        _page('<p><a href="mailto:x@y.test">mail</a> '
            '<a href="javascript:alert(1)">js</a> '
            '<a href="#note1">note</a> '
            '<a href="https://ok.test/">  </a> '
            '<a>no href</a> '
            '<a href="https://ok.test/k">kept</a> $_filler.</p>'),
        baseUrl: 'https://blog.test/');
    final b = _first(r);
    expect([for (final l in b.links) l.href], ['https://ok.test/k']);
  });

  test('a fragment on another page is kept whole', () {
    final r = extractArticle(
        _page('<p><a href="other#sec">there</a> $_filler.</p>'),
        baseUrl: 'https://blog.test/dir/post');
    expect(_first(r).links.single.href, 'https://blog.test/dir/other#sec');
  });

  test('without a base address, relative links are dropped', () {
    final r = extractArticle(
        _page('<p><a href="/rel">rel</a> <a href="https://abs.test/">abs</a> '
            '$_filler.</p>'));
    expect([for (final l in _first(r).links) l.href], ['https://abs.test/']);
  });

  test('a paragraph without links has none, and the text is unchanged', () {
    final html = _page('<p>Plain words here $_filler.</p>');
    final r = extractArticle(html, baseUrl: 'https://blog.test/');
    expect(_first(r).links, isEmpty);
    expect(_first(r).text, 'Plain words here $_filler.');
  });
}
