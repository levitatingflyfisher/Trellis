import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/intake/article_fetch.dart';

import '../support/scripted_fetcher.dart';

void main() {
  test('a feed address is sent to Subscriptions, where feeds are followed',
      () async {
    final outcome = await fetchArticle(
        fetcher: ScriptedFetcher((u, h) => textResponse(
            '<?xml version="1.0"?><rss version="2.0"><channel>'
            '<title>Show</title></channel></rss>')),
        url: Uri.parse('https://cast.test/feed'));

    expect(outcome, isA<ArticleRefused>());
    final message = (outcome as ArticleRefused).message;
    expect(message, contains('Subscriptions'));
    expect(message, isNot(contains('Latest')));
  });

  test('the links of an article come with its rows, by row and place', () {
    final words = 'plain words to make the paragraph long enough ' * 5;
    final outcome = articleFromHtml(
        '<html><body><article><p>First <a href="https://a.test/x">cited</a> '
        '$words</p><p>Second $words <a href="/y">there</a></p>'
        '</article></body></html>',
        Uri.parse('https://blog.test/p'));
    final fetched = outcome as ArticleFetched;
    expect(fetched.rows, hasLength(2));
    expect([for (final l in fetched.links) (l.segIdx, l.href)],
        [(0, 'https://a.test/x'), (1, 'https://blog.test/y')]);
    final l = fetched.links.last;
    expect(fetched.rows[1].text.substring(l.start, l.end), 'there');
  });
}
