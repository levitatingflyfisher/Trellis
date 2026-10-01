/// A Ghost-shaped newsletter feed (hand-written fixture, no third-party
/// text): text posts with no enclosures and their full body in
/// content:encoded, plus a media:content image that must not read as audio.
library;

import 'dart:io';

import 'package:comms_core/comms_core.dart';
import 'package:test/test.dart';

void main() {
  final body = File('test/fixtures/ghost_newsletter.xml').readAsStringSync();
  final feed = parseRssFeed(body, 'https://hedgerow.test/archive/rss/');

  test('the channel title comes through its CDATA', () {
    expect(feed.title, 'Hedgerow Ledger');
  });

  test('every post is an item, newest first as the feed lists them', () {
    expect(feed.items.map((i) => i.title), [
      'Who pays for the village well',
      'The footbridge fails all at once',
      'A note on this newsletter',
    ]);
    expect(feed.items.first.link, 'https://hedgerow.test/village-well/');
  });

  test('no post has audio, the header image included', () {
    for (final item in feed.items) {
      expect(item.enclosure, isNull, reason: item.title);
      expect(item.audio, isEmpty, reason: item.title);
    }
  });

  test('each post carries its full body, far longer than its excerpt', () {
    for (final item in feed.items) {
      final html = item.contentHtml;
      expect(html, isNotNull, reason: item.title);
      expect(html!.length, greaterThan(item.desc.length * 4),
          reason: item.title);
      expect(html, contains('<p>'));
    }
  });
}
