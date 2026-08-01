import 'package:comms_core/comms_core.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/feeds/feed_ingest.dart';
import 'package:trellis/features/feeds/feeds_repository.dart';

import '../support/scripted_fetcher.dart';

const _rssTwo = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel>
  <title>The Night Sky Cast</title>
  <item>
    <title>Aurora season</title>
    <link>https://cast.test/aurora</link>
    <pubDate>Wed, 05 Aug 2026 12:00:00 GMT</pubDate>
    <description>Lights in the north.</description>
    <enclosure url="https://cast.test/aurora.mp3" type="audio/mpeg"/>
  </item>
  <item>
    <title>Meteor showers</title>
    <link>https://cast.test/meteors</link>
    <pubDate>Tue, 04 Aug 2026 12:00:00 GMT</pubDate>
    <description>Dust trails burn.</description>
  </item>
</channel></rss>
''';

void main() {
  group('parsePublishedMs', () {
    test('RFC-1123 GMT dates parse to the exact instant', () {
      expect(parsePublishedMs('Wed, 05 Aug 2026 12:00:00 GMT'),
          DateTime.utc(2026, 8, 5, 12).millisecondsSinceEpoch);
    });

    test('RFC-822 numeric zone offsets shift the instant', () {
      expect(parsePublishedMs('Wed, 05 Aug 2026 14:00:00 +0200'),
          DateTime.utc(2026, 8, 5, 12).millisecondsSinceEpoch);
      expect(parsePublishedMs('Wed, 05 Aug 2026 07:30:00 -0430'),
          DateTime.utc(2026, 8, 5, 12).millisecondsSinceEpoch);
    });

    test('RFC-822 named zones (EST/PDT/UT) are honoured', () {
      expect(parsePublishedMs('Wed, 05 Aug 2026 07:00:00 EST'),
          DateTime.utc(2026, 8, 5, 12).millisecondsSinceEpoch);
      expect(parsePublishedMs('Wed, 05 Aug 2026 05:00:00 PDT'),
          DateTime.utc(2026, 8, 5, 12).millisecondsSinceEpoch);
      expect(parsePublishedMs('Wed, 05 Aug 2026 12:00:00 UT'),
          DateTime.utc(2026, 8, 5, 12).millisecondsSinceEpoch);
    });

    test('seconds are optional (some feeds emit HH:MM)', () {
      expect(parsePublishedMs('Wed, 05 Aug 2026 12:00 GMT'),
          DateTime.utc(2026, 8, 5, 12).millisecondsSinceEpoch);
    });

    test('ISO-8601 (Atom) dates parse, offsets included', () {
      expect(parsePublishedMs('2026-08-05T12:00:00Z'),
          DateTime.utc(2026, 8, 5, 12).millisecondsSinceEpoch);
      expect(parsePublishedMs('2026-08-05T14:00:00+02:00'),
          DateTime.utc(2026, 8, 5, 12).millisecondsSinceEpoch);
    });

    test('garbage and empty dates return null', () {
      expect(parsePublishedMs('yesterday-ish'), isNull);
      expect(parsePublishedMs(''), isNull);
    });
  });

  group('breaker state json', () {
    test('round-trips through encode/decode', () {
      const s = FeedRefreshState(
        url: 'https://a.test/feed',
        title: 'A',
        etag: '"e"',
        lastModified: 'lm',
        consecutiveFailures: 3,
        broken: false,
        lastError: 'Fetch failed',
        throttledUntilMs: 12345,
        lastCheckedMs: 99,
      );
      final back = decodeBreakerState(
          url: s.url,
          title: s.title,
          etag: s.etag,
          lastModified: s.lastModified,
          json: encodeBreakerState(s));
      expect(back.consecutiveFailures, 3);
      expect(back.broken, isFalse);
      expect(back.lastError, 'Fetch failed');
      expect(back.throttledUntilMs, 12345);
      expect(back.lastCheckedMs, 99);
    });

    test('an empty json object decodes to a clean state', () {
      final s = decodeBreakerState(
          url: 'u', title: '', etag: null, lastModified: null, json: '{}');
      expect(s.consecutiveFailures, 0);
      expect(s.broken, isFalse);
      expect(s.throttledUntilMs, isNull);
    });
  });

  group('ingestFeedItems', () {
    late AppDatabase db;
    late int profileId;
    late int feedId;
    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      profileId = await db.profilesDao.create('Ada');
      feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://cast.test/feed');
    });
    tearDown(() => db.close());

    final nowMs = DateTime.utc(2026, 8, 6).millisecondsSinceEpoch;

    test('an audio item becomes an ephemeron episode work whose sourceUrl '
        'IS the enclosure', () async {
      final added = await ingestFeedItems(
          db: db,
          profileId: profileId,
          feedId: feedId,
          items: const [
            FeedItem(
                title: 'Aurora season',
                link: 'https://cast.test/aurora',
                date: 'Wed, 05 Aug 2026 12:00:00 GMT',
                desc: 'Lights in the north.',
                enclosure:
                    Enclosure(url: 'https://cast.test/aurora.mp3')),
          ],
          nowMs: nowMs);
      expect(added, 1);

      final work = (await db.spineDao.worksOf(profileId)).single;
      expect(work.kind, 'episode');
      expect(work.persistence, 'ephemeron');
      expect(work.sourceUrl, 'https://cast.test/aurora.mp3');
      expect(work.firstSeenEpochDay,
          nowMs ~/ Duration.millisecondsPerDay);

      final episode = (await db.feedsDao.episodeOf(work.id))!;
      expect(episode.enclosureUrl, 'https://cast.test/aurora.mp3');
      expect(episode.publishedAtMs,
          DateTime.utc(2026, 8, 5, 12).millisecondsSinceEpoch);
      expect(episode.readAtMs, isNull);

      // The shownotes are readable: desc became a prose segment.
      final segs = await db.spineDao.segmentsOf(work.id);
      expect(segs.single.body, 'Lights in the north.');
    });

    test('a text item becomes an ephemeron article work with the link as '
        'source', () async {
      await ingestFeedItems(
          db: db,
          profileId: profileId,
          feedId: feedId,
          items: const [
            FeedItem(
                title: 'Meteor showers',
                link: 'https://cast.test/meteors',
                date: 'bad date',
                desc: ''),
          ],
          nowMs: nowMs);
      final work = (await db.spineDao.worksOf(profileId)).single;
      expect(work.kind, 'article');
      expect(work.sourceUrl, 'https://cast.test/meteors');
      final episode = (await db.feedsDao.episodeOf(work.id))!;
      expect(episode.enclosureUrl, isNull);
      expect(episode.publishedAtMs, nowMs,
          reason: 'unparseable dates fall back to arrival time');
      expect(await db.spineDao.segmentsOf(work.id), isEmpty);
    });

    test('re-ingesting the same items adds nothing (guid dedupe)', () async {
      final items = const [
        FeedItem(
            title: 'One',
            link: 'https://cast.test/one',
            date: '',
            desc: 'x'),
        FeedItem(
            title: 'Two',
            link: '',
            date: '',
            desc: '',
            enclosure: Enclosure(url: 'https://cast.test/two.mp3')),
      ];
      expect(
          await ingestFeedItems(
              db: db,
              profileId: profileId,
              feedId: feedId,
              items: items,
              nowMs: nowMs),
          2);
      expect(
          await ingestFeedItems(
              db: db,
              profileId: profileId,
              feedId: feedId,
              items: items,
              nowMs: nowMs),
          0);
      // The link-less audio item's guid fell back to the enclosure URL.
      expect(await db.feedsDao.guidsOf(feedId),
          contains('https://cast.test/two.mp3'));
    });

    test('an untitled item gets a calm placeholder title', () async {
      await ingestFeedItems(
          db: db,
          profileId: profileId,
          feedId: feedId,
          items: const [
            FeedItem(title: '', link: 'https://c/1', date: '', desc: ''),
          ],
          nowMs: nowMs);
      expect((await db.spineDao.worksOf(profileId)).single.title, 'Untitled');
    });
  });

  group('FeedsRepository refresh', () {
    late AppDatabase db;
    late int profileId;
    late int nowMs;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      profileId = await db.profilesDao.create('Ada');
      nowMs = DateTime.utc(2026, 8, 6).millisecondsSinceEpoch;
    });
    tearDown(() => db.close());

    FeedsRepository repo(ScriptedFetcher fetcher) => FeedsRepository(
        db: db,
        fetcher: fetcher,
        now: () => DateTime.fromMillisecondsSinceEpoch(nowMs));

    Future<Feed> seedFeed({String? etag, String? lastModified}) async {
      final id = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://cast.test/feed');
      if (etag != null || lastModified != null) {
        await db.feedsDao.updateRefreshState(id,
            title: '',
            etag: etag,
            lastModified: lastModified,
            breakerJson: '{}');
      }
      return (await db.feedsDao.feedsOf(profileId)).single;
    }

    test('a fresh fetch ingests items and adopts title + validators',
        () async {
      final fetcher = ScriptedFetcher((url, headers) => textResponse(_rssTwo,
          headers: {
            'etag': '"v1"',
            'last-modified': 'Wed, 05 Aug 2026 12:00:00 GMT'
          }));
      final feed = await seedFeed();

      final outcome = await repo(fetcher).refreshFeed(feed);
      expect(outcome.status, RefreshStatus.fresh);
      expect(outcome.newItems, 2);

      final after = (await db.feedsDao.feedsOf(profileId)).single;
      expect(after.title, 'The Night Sky Cast');
      expect(after.etag, '"v1"');
      expect(after.lastModified, 'Wed, 05 Aug 2026 12:00:00 GMT');
      expect(await db.feedsDao.riverItems(profileId), hasLength(2));
    });

    test('stored validators ride the next request as conditional headers',
        () async {
      final fetcher = ScriptedFetcher(
          (url, headers) => textResponse('', status: 304));
      final feed = await seedFeed(etag: '"v1"', lastModified: 'lm');

      final outcome = await repo(fetcher).refreshFeed(feed);
      expect(outcome.status, RefreshStatus.notModified);
      expect(fetcher.calls.single.headers?['If-None-Match'], '"v1"');
      expect(fetcher.calls.single.headers?['If-Modified-Since'], 'lm');
      expect(await db.feedsDao.riverItems(profileId), isEmpty);
    });

    test('429 with Retry-After throttles the feed; the window skips, '
        'force pierces it', () async {
      var status = 429;
      final fetcher = ScriptedFetcher((url, headers) => status == 429
          ? textResponse('', status: 429, headers: {'retry-after': '120'})
          : textResponse(_rssTwo));
      final feed = await seedFeed();
      final r = repo(fetcher);

      expect((await r.refreshFeed(feed)).status, RefreshStatus.throttled);

      // Inside the window: skipped without a network call.
      status = 200;
      final during = (await db.feedsDao.feedsOf(profileId)).single;
      expect((await r.refreshFeed(during)).status, RefreshStatus.skipped);
      expect(fetcher.calls, hasLength(1));

      // Forced: fetches anyway.
      expect((await r.refreshFeed(during, force: true)).status,
          RefreshStatus.fresh);
    });

    test('five consecutive failures trip the breaker; broken skips',
        () async {
      final fetcher =
          ScriptedFetcher((url, headers) => throw Exception('reset'));
      final r = repo(fetcher);
      await seedFeed();

      for (var i = 0; i < 5; i++) {
        final feed = (await db.feedsDao.feedsOf(profileId)).single;
        expect((await r.refreshFeed(feed)).status, RefreshStatus.error);
      }
      final broken = (await db.feedsDao.feedsOf(profileId)).single;
      expect(decodeBreakerState(
              url: broken.url,
              title: broken.title,
              etag: broken.etag,
              lastModified: broken.lastModified,
              json: broken.breakerJson)
          .broken, isTrue);
      expect((await r.refreshFeed(broken)).status, RefreshStatus.skipped);
      expect(fetcher.calls, hasLength(5));
    });

    test('404 marks the feed broken immediately', () async {
      final fetcher =
          ScriptedFetcher((url, headers) => textResponse('', status: 404));
      final feed = await seedFeed();
      expect((await repo(fetcher).refreshFeed(feed)).status,
          RefreshStatus.notFound);
      final after = (await db.feedsDao.feedsOf(profileId)).single;
      expect(after.breakerJson, contains('"broken":true'));
    });

    test('a fresh body that fails to parse leaves ALL bookkeeping '
        'untouched (donor parity)', () async {
      final fetcher = ScriptedFetcher((url, headers) =>
          textResponse('this is not xml', headers: {'etag': '"new"'}));
      final feed = await seedFeed(etag: '"old"');

      final outcome = await repo(fetcher).refreshFeed(feed);
      expect(outcome.status, RefreshStatus.parseFailed);

      final after = (await db.feedsDao.feedsOf(profileId)).single;
      expect(after.etag, '"old"',
          reason: 'the donor skipped bookkeeping when parse threw');
      expect(after.breakerJson, feed.breakerJson);
    });

    test('refreshAll walks every feed of the profile', () async {
      final fetcher = ScriptedFetcher((url, headers) => textResponse(_rssTwo));
      await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://a.test/feed');
      await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://b.test/feed');

      await repo(fetcher).refreshAll(profileId);
      expect(fetcher.calls.map((c) => c.url.host).toSet(),
          {'a.test', 'b.test'});
    });
  });

  group('FeedsRepository subscribe', () {
    late AppDatabase db;
    late int profileId;
    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      profileId = await db.profilesDao.create('Ada');
    });
    tearDown(() => db.close());

    FeedsRepository repo(ScriptedFetcher fetcher) =>
        FeedsRepository(db: db, fetcher: fetcher);

    test('a feed URL subscribes directly and ingests its items', () async {
      final fetcher = ScriptedFetcher((url, headers) => textResponse(_rssTwo));
      final result = await repo(fetcher)
          .subscribe(profileId: profileId, rawUrl: 'https://cast.test/feed');

      expect(result, isA<SubscribeSuccess>());
      final ok = result as SubscribeSuccess;
      expect(ok.title, 'The Night Sky Cast');
      expect(ok.newItems, 2);
      expect((await db.feedsDao.feedsOf(profileId)).single.title,
          'The Night Sky Cast');
      expect(await db.feedsDao.riverItems(profileId), hasLength(2));
    });

    test('an HTML page is sniffed for its <link> feed discovery', () async {
      const html = '<html><head>'
          '<link rel="alternate" type="application/rss+xml" href="/feed">'
          '</head><body>hi</body></html>';
      final fetcher = ScriptedFetcher((url, headers) =>
          url.path == '/feed' ? textResponse(_rssTwo) : textResponse(html));

      final result = await repo(fetcher)
          .subscribe(profileId: profileId, rawUrl: 'https://cast.test/blog');
      expect(result, isA<SubscribeSuccess>());
      expect((await db.feedsDao.feedsOf(profileId)).single.url,
          'https://cast.test/feed');
    });

    test('a scheme-less address gets https', () async {
      final fetcher = ScriptedFetcher((url, headers) => textResponse(_rssTwo));
      final result = await repo(fetcher)
          .subscribe(profileId: profileId, rawUrl: 'cast.test/feed');
      expect(result, isA<SubscribeSuccess>());
      expect((await db.feedsDao.feedsOf(profileId)).single.url,
          'https://cast.test/feed');
    });

    test('subscribing twice reports the existing subscription', () async {
      final fetcher = ScriptedFetcher((url, headers) => textResponse(_rssTwo));
      final r = repo(fetcher);
      await r.subscribe(profileId: profileId, rawUrl: 'https://cast.test/feed');
      final again = await r.subscribe(
          profileId: profileId, rawUrl: 'https://cast.test/feed');
      expect(again, isA<AlreadySubscribed>());
      expect(await db.feedsDao.feedsOf(profileId), hasLength(1));
    });

    test('a private-network URL is refused by the SSRF guard, no fetch runs',
        () async {
      final fetcher = ScriptedFetcher((url, headers) => textResponse(_rssTwo));
      final result = await repo(fetcher)
          .subscribe(profileId: profileId, rawUrl: 'http://192.168.1.10/feed');
      expect(result, isA<SubscribeFailure>());
      expect((result as SubscribeFailure).message,
          contains("Local and private-network addresses"));
      expect(fetcher.calls, isEmpty);
    });

    test('a page with no discoverable feed fails calmly', () async {
      // Real-world HTML: not well-formed XML (unclosed tags), no feed link.
      final fetcher = ScriptedFetcher((url, headers) =>
          textResponse('<!doctype html><html><body><p>no feeds<br></html>'));
      final result = await repo(fetcher)
          .subscribe(profileId: profileId, rawUrl: 'https://cast.test/blog');
      expect(result, isA<SubscribeFailure>());
      expect(await db.feedsDao.feedsOf(profileId), isEmpty);
    });
  });
}
