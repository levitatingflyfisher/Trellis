import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/feeds/feed_dedup.dart';

/// Cross-feed dedup (Campaign 5 Phase 3): two river items are duplicates
/// when their canonical URLs match after tracker-parameter stripping OR
/// their titles are exact-normalized equal AND published within 48h. The
/// YOUNGER duplicate is suppressed. Law: dedup NEVER suppresses items
/// from the SAME feed — reposts are the author's choice.
void main() {
  DedupCandidate c(
          {required int workId,
          required int feedId,
          String? sourceUrl,
          String title = 'A title',
          required int publishedAtMs}) =>
      (
        workId: workId,
        feedId: feedId,
        sourceUrl: sourceUrl,
        title: title,
        publishedAtMs: publishedAtMs,
      );

  const hour = 60 * 60 * 1000;
  const day = 24 * hour;

  group('URL match', () {
    test('identical URLs across feeds — the later one is suppressed', () {
      final candidates = [
        c(workId: 1, feedId: 10, sourceUrl: 'https://a.test/post',
            publishedAtMs: 1000),
        c(workId: 2, feedId: 20, sourceUrl: 'https://a.test/post',
            publishedAtMs: 2000),
      ];
      final result = findDuplicates(candidates);
      expect(result.keys, [2]);
      expect(result[2]!.reason, 'url');
      expect(result[2]!.canonicalWorkId, 1);
    });

    test('URLs differing only by tracker params still match', () {
      final candidates = [
        c(workId: 1, feedId: 10,
            sourceUrl: 'https://a.test/post?utm_source=newsletter',
            publishedAtMs: 1000),
        c(workId: 2, feedId: 20, sourceUrl: 'https://a.test/post?fbclid=xyz',
            publishedAtMs: 2000),
      ];
      final result = findDuplicates(candidates);
      expect(result.keys, [2]);
      expect(result[2]!.reason, 'url');
    });

    test('genuinely different URLs never match', () {
      final candidates = [
        c(workId: 1, feedId: 10, sourceUrl: 'https://a.test/one',
            title: 'First title', publishedAtMs: 1000),
        c(workId: 2, feedId: 20, sourceUrl: 'https://a.test/two',
            title: 'Second title', publishedAtMs: 2000),
      ];
      expect(findDuplicates(candidates), isEmpty);
    });

    test('null/empty sourceUrls never match each other', () {
      final candidates = [
        c(workId: 1, feedId: 10, sourceUrl: null, title: 'One',
            publishedAtMs: 1000),
        c(workId: 2, feedId: 20, sourceUrl: '', title: 'Two',
            publishedAtMs: 2000),
      ];
      expect(findDuplicates(candidates), isEmpty);
    });
  });

  group('title match — exact-normalized, within 48h', () {
    test('same title (case/whitespace-insensitive), published 1h apart',
        () {
      final candidates = [
        c(workId: 1, feedId: 10, title: 'Aurora Season',
            publishedAtMs: 1000),
        c(workId: 2, feedId: 20, title: '  aurora   season  ',
            publishedAtMs: 1000 + hour),
      ];
      final result = findDuplicates(candidates);
      expect(result.keys, [2]);
      expect(result[2]!.reason, 'title');
    });

    test('same title, published exactly 48h apart still matches (inclusive)',
        () {
      final candidates = [
        c(workId: 1, feedId: 10, title: 'Same Title', publishedAtMs: 0),
        c(workId: 2, feedId: 20, title: 'Same Title',
            publishedAtMs: 2 * day),
      ];
      final result = findDuplicates(candidates);
      expect(result.keys, [2]);
    });

    test('same title, published more than 48h apart never matches', () {
      final candidates = [
        c(workId: 1, feedId: 10, title: 'Same Title', publishedAtMs: 0),
        c(workId: 2, feedId: 20, title: 'Same Title',
            publishedAtMs: 2 * day + 1),
      ];
      expect(findDuplicates(candidates), isEmpty);
    });

    test('different titles never match regardless of timing', () {
      final candidates = [
        c(workId: 1, feedId: 10, title: 'One Thing', publishedAtMs: 1000),
        c(workId: 2, feedId: 20, title: 'Another Thing',
            publishedAtMs: 1000),
      ];
      expect(findDuplicates(candidates), isEmpty);
    });
  });

  group('the same-feed exemption — reposts are the author\'s choice', () {
    test('identical URL, SAME feed — never suppressed', () {
      final candidates = [
        c(workId: 1, feedId: 10, sourceUrl: 'https://a.test/post',
            publishedAtMs: 1000),
        c(workId: 2, feedId: 10, sourceUrl: 'https://a.test/post',
            publishedAtMs: 2000),
      ];
      expect(findDuplicates(candidates), isEmpty);
    });

    test('identical title within 48h, SAME feed — never suppressed', () {
      final candidates = [
        c(workId: 1, feedId: 10, title: 'Weekly Update', publishedAtMs: 0),
        c(workId: 2, feedId: 10, title: 'Weekly Update',
            publishedAtMs: hour),
      ];
      expect(findDuplicates(candidates), isEmpty);
    });
  });

  group('younger wins the suppression, tie-broken by workId', () {
    test('the later publishedAtMs is suppressed regardless of list order',
        () {
      final candidates = [
        c(workId: 2, feedId: 20, sourceUrl: 'https://a.test/post',
            publishedAtMs: 2000),
        c(workId: 1, feedId: 10, sourceUrl: 'https://a.test/post',
            publishedAtMs: 1000),
      ];
      final result = findDuplicates(candidates);
      expect(result.keys, [2]);
      expect(result[2]!.canonicalWorkId, 1);
    });

    test('equal publishedAtMs ties break on the higher workId', () {
      final candidates = [
        c(workId: 5, feedId: 10, sourceUrl: 'https://a.test/post',
            publishedAtMs: 1000),
        c(workId: 3, feedId: 20, sourceUrl: 'https://a.test/post',
            publishedAtMs: 1000),
      ];
      final result = findDuplicates(candidates);
      expect(result.keys, [5]);
      expect(result[5]!.canonicalWorkId, 3);
    });
  });

  test('three feeds, one URL — only the youngest is suppressed', () {
    final candidates = [
      c(workId: 1, feedId: 10, sourceUrl: 'https://a.test/post',
          publishedAtMs: 1000),
      c(workId: 2, feedId: 20, sourceUrl: 'https://a.test/post',
          publishedAtMs: 2000),
      c(workId: 3, feedId: 30, sourceUrl: 'https://a.test/post',
          publishedAtMs: 3000),
    ];
    final result = findDuplicates(candidates);
    expect(result.keys.toSet(), {2, 3});
    expect(result[2]!.canonicalWorkId, 1);
    expect(result[3]!.canonicalWorkId, 1);
  });
}
