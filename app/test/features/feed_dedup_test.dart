import 'dart:math';

import 'package:comms_core/comms_core.dart';
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

  group('at the size of a real OPML import', () {
    // 117 feeds with back catalogues came to about 20,000 river items; the
    // all-pairs pass took minutes on the UI isolate and Android killed
    // the app as not responding.
    test('20,000 items resolve in well under a second', () {
      final items = [
        for (var i = 0; i < 20000; i++)
          c(
              workId: i,
              feedId: i % 117,
              sourceUrl: 'https://host${i % 117}.test/ep/$i?utm_source=x',
              title: 'Episode $i',
              publishedAtMs: i * hour),
        c(workId: 90001, feedId: 500, sourceUrl: 'https://host3.test/ep/3',
            publishedAtMs: 10 * day),
        c(workId: 90002, feedId: 501, title: 'episode  7',
            publishedAtMs: 7 * hour + hour),
      ];
      final clock = Stopwatch()..start();
      final result = findDuplicates(items);
      expect(clock.elapsedMilliseconds, lessThan(1000));
      expect(result.keys.toSet(), {90001, 90002});
      expect(result[90001]!.canonicalWorkId, 3);
      expect(result[90002]!.canonicalWorkId, 7);
    });

    test('agrees with the all-pairs definition on mixed, colliding input',
        () {
      final rng = Random(7);
      for (var round = 0; round < 30; round++) {
        final items = [
          for (var i = 0; i < 120; i++)
            c(
                workId: rng.nextInt(1000),
                feedId: rng.nextInt(4),
                sourceUrl: switch (rng.nextInt(4)) {
                  0 => null,
                  1 => '',
                  _ => 'https://h.test/${rng.nextInt(15)}'
                      '${rng.nextBool() ? '?utm_medium=a' : ''}',
                },
                title: '${rng.nextBool() ? 'T' : 't'}itle '
                    '${rng.nextInt(10)}${rng.nextBool() ? '  ' : ''}',
                publishedAtMs: rng.nextInt(6) * day),
        ];
        expect(findDuplicates(items), _allPairs(items), reason: 'round $round');
      }
    });
  });

  group('off the UI isolate', () {
    test('a big river is compared on another isolate, with the same verdicts',
        () async {
      final river = [
        for (var i = 0; i < offThreadDedupCount + 10; i++)
          c(
              workId: i,
              feedId: i % 3,
              sourceUrl: 'https://news.test/story/${i ~/ 3}',
              title: 'Story ${i ~/ 3}',
              publishedAtMs: i * hour),
      ];
      var hops = 0;
      final verdicts = await findDuplicatesOffThread(river,
          offload: (candidates) async {
        hops++;
        return findDuplicates(candidates);
      });
      expect(hops, 1);
      expect(verdicts, findDuplicates(river));
      // And through the real hop.
      expect(await findDuplicatesOffThread(river), findDuplicates(river));
    });

    test('a small river is compared in place', () async {
      var hops = 0;
      await findDuplicatesOffThread(
          [c(workId: 1, feedId: 1, publishedAtMs: 1)],
          offload: (candidates) async {
        hops++;
        return findDuplicates(candidates);
      });
      expect(hops, 0);
    });
  });
}

/// The definition, written as the obvious all-pairs loop: for each
/// younger item, the verdict of the first matching pair in (i, j) order.
Map<int, DedupVerdict> _allPairs(List<DedupCandidate> cs) {
  String norm(String t) => t.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  final out = <int, DedupVerdict>{};
  for (var i = 0; i < cs.length; i++) {
    for (var j = i + 1; j < cs.length; j++) {
      final a = cs[i], b = cs[j];
      if (a.feedId == b.feedId) continue;
      String? reason;
      final au = a.sourceUrl, bu = b.sourceUrl;
      if (au != null && au.isNotEmpty && bu != null && bu.isNotEmpty &&
          canonicalizeForDedup(au) == canonicalizeForDedup(bu)) {
        reason = 'url';
      } else if (norm(a.title).isNotEmpty && norm(a.title) == norm(b.title) &&
          (a.publishedAtMs - b.publishedAtMs).abs() <= 48 * 60 * 60 * 1000) {
        reason = 'title';
      }
      if (reason == null) continue;
      final aYounger = a.publishedAtMs != b.publishedAtMs
          ? a.publishedAtMs > b.publishedAtMs
          : a.workId > b.workId;
      out.putIfAbsent((aYounger ? a : b).workId,
          () => (reason: reason!, canonicalWorkId: (aYounger ? b : a).workId));
    }
  }
  return out;
}
