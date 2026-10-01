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
}
