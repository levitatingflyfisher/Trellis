import 'dart:io';

import 'package:comms_core/comms_core.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/feeds/feed_ingest.dart';
import 'package:trellis/features/feeds/feed_rules.dart';
import 'package:trellis/features/feeds/feeds_repository.dart';

import '../support/fake_services.dart';
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

    group('tracker stripping on outbound article links (Campaign 5 Phase 4, '
        'the Miniflux lesson)', () {
      test('an article link with tracking params is stored clean', () async {
        await ingestFeedItems(
            db: db,
            profileId: profileId,
            feedId: feedId,
            items: const [
              FeedItem(
                  title: 'Meteor showers',
                  link: 'https://cast.test/meteors?utm_source=newsletter'
                      '&fbclid=xyz',
                  date: '',
                  desc: ''),
            ],
            nowMs: nowMs);
        final work = (await db.spineDao.worksOf(profileId)).single;
        expect(work.sourceUrl, 'https://cast.test/meteors');
      });

      test('an enclosure (audio) URL is NEVER stripped — signed CDN params '
          'can be load-bearing there, unlike a plain article link',
          () async {
        await ingestFeedItems(
            db: db,
            profileId: profileId,
            feedId: feedId,
            items: const [
              FeedItem(
                  title: 'Episode',
                  link: '',
                  date: '',
                  desc: '',
                  enclosure: Enclosure(
                      url: 'https://cast.test/ep.mp3?utm_source=feed&sig=abc')),
            ],
            nowMs: nowMs);
        final work = (await db.spineDao.worksOf(profileId)).single;
        expect(work.sourceUrl,
            'https://cast.test/ep.mp3?utm_source=feed&sig=abc');
      });

      test('stripping the stored sourceUrl never changes item identity: '
          're-ingesting the same tracked link is still deduped by its RAW '
          'guid, not the cleaned URL', () async {
        final items = const [
          FeedItem(
              title: 'Meteor showers',
              link: 'https://cast.test/meteors?utm_source=newsletter',
              date: '',
              desc: ''),
        ];
        expect(
            await ingestFeedItems(
                db: db,
                profileId: profileId,
                feedId: feedId,
                items: items,
                nowMs: nowMs),
            1);
        expect(
            await ingestFeedItems(
                db: db,
                profileId: profileId,
                feedId: feedId,
                items: items,
                nowMs: nowMs),
            0,
            reason: 'guidOf hashes the raw link — stripping sourceUrl at '
                'storage time must never make an already-seen item look new');
      });
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

    group('per-feed rules (Campaign 5 Phase 3, before an item enters at all)',
        () {
      const skipSponsored = FeedRule(
          field: FeedRuleField.title,
          match: FeedRuleMatch.contains,
          text: 'sponsored',
          action: FeedRuleAction.skip);

      test('skip: the item never becomes a row at all', () async {
        final added = await ingestFeedItems(
            db: db,
            profileId: profileId,
            feedId: feedId,
            items: const [
              FeedItem(
                  title: 'A Sponsored segment',
                  link: 'https://c/1',
                  date: '',
                  desc: ''),
            ],
            nowMs: nowMs,
            rules: const [skipSponsored]);
        expect(added, 0);
        expect(await db.spineDao.worksOf(profileId), isEmpty);
      });

      test('skip only applies to items that match; others enter normally',
          () async {
        final added = await ingestFeedItems(
            db: db,
            profileId: profileId,
            feedId: feedId,
            items: const [
              FeedItem(
                  title: 'A Sponsored segment',
                  link: 'https://c/1',
                  date: '',
                  desc: ''),
              FeedItem(title: 'A real episode', link: 'https://c/2',
                  date: '', desc: ''),
            ],
            nowMs: nowMs,
            rules: const [skipSponsored]);
        expect(added, 1);
        expect((await db.spineDao.worksOf(profileId)).single.title,
            'A real episode');
      });

      test('markReadOnArrival: enters normally, but with no unread dot',
          () async {
        const rule = FeedRule(
            field: FeedRuleField.title,
            match: FeedRuleMatch.contains,
            text: 'housekeeping',
            action: FeedRuleAction.markReadOnArrival);
        await ingestFeedItems(
            db: db,
            profileId: profileId,
            feedId: feedId,
            items: const [
              FeedItem(
                  title: 'Housekeeping note',
                  link: 'https://c/1',
                  date: '',
                  desc: ''),
            ],
            nowMs: nowMs,
            rules: const [rule]);
        final work = (await db.spineDao.worksOf(profileId)).single;
        expect(work.persistence, 'ephemeron');
        final episode = (await db.feedsDao.episodeOf(work.id))!;
        expect(episode.readAtMs, nowMs);
      });

      test('autoKeep: enters, promoted to the library, marked read',
          () async {
        const rule = FeedRule(
            field: FeedRuleField.description,
            match: FeedRuleMatch.contains,
            text: 'must-listen',
            action: FeedRuleAction.autoKeep);
        await ingestFeedItems(
            db: db,
            profileId: profileId,
            feedId: feedId,
            items: const [
              FeedItem(
                  title: 'Episode 9',
                  link: 'https://c/1',
                  date: '',
                  desc: 'A must-listen episode.'),
            ],
            nowMs: nowMs,
            rules: const [rule]);
        final work = (await db.spineDao.worksOf(profileId)).single;
        expect(work.persistence, 'work',
            reason: 'auto-keep is the same transition Keep performs');
        final episode = (await db.feedsDao.episodeOf(work.id))!;
        expect(episode.readAtMs, nowMs);
      });

      test('no rules (the default) behaves exactly as before this feature',
          () async {
        final added = await ingestFeedItems(
            db: db,
            profileId: profileId,
            feedId: feedId,
            items: const [
              FeedItem(
                  title: 'Anything', link: 'https://c/1', date: '',
                  desc: ''),
            ],
            nowMs: nowMs);
        expect(added, 1);
        final work = (await db.spineDao.worksOf(profileId)).single;
        expect(work.persistence, 'ephemeron');
        expect((await db.feedsDao.episodeOf(work.id))!.readAtMs, isNull);
      });
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

    test('a fresh fetch adopts the archive link the parse found', () async {
      final fetcher = ScriptedFetcher((url, headers) => textResponse('''
<rss><channel><title>t</title>
  <atom:link rel="next" href="https://cast.test/feed?page=2"/>
</channel></rss>
'''));
      final feed = await seedFeed();

      await repo(fetcher).refreshFeed(feed);

      expect((await db.feedsDao.feedsOf(profileId)).single.nextPageUrl,
          'https://cast.test/feed?page=2');
    });

    test('a fresh fetch with no archive link clears a previously known one',
        () async {
      final fetcher = ScriptedFetcher((url, headers) => textResponse(_rssTwo));
      var feed = await seedFeed();
      await db.feedsDao.updateRefreshState(feed.id,
          title: '',
          etag: null,
          lastModified: null,
          breakerJson: '{}',
          nextPageUrl: 'https://cast.test/feed?page=2',
          updateNextPageUrl: true);
      feed = (await db.feedsDao.feedsOf(profileId)).single;

      await repo(fetcher).refreshFeed(feed);

      expect((await db.feedsDao.feedsOf(profileId)).single.nextPageUrl, isNull,
          reason: 'the host stopped advertising an archive on this page');
    });

    test('a non-fresh outcome (304) leaves a known archive link untouched',
        () async {
      final fetcher =
          ScriptedFetcher((url, headers) => textResponse('', status: 304));
      var feed = await seedFeed(etag: '"v1"', lastModified: 'lm');
      await db.feedsDao.updateRefreshState(feed.id,
          title: '',
          etag: '"v1"',
          lastModified: 'lm',
          breakerJson: '{}',
          nextPageUrl: 'https://cast.test/feed?page=2',
          updateNextPageUrl: true);
      feed = (await db.feedsDao.feedsOf(profileId)).single;

      final outcome = await repo(fetcher).refreshFeed(feed);
      expect(outcome.status, RefreshStatus.notModified);
      expect((await db.feedsDao.feedsOf(profileId)).single.nextPageUrl,
          'https://cast.test/feed?page=2');
    });

    test('cross-feed dedup runs after ingest: the same story from two feeds '
        'hides the younger copy from the river (Campaign 5 Phase 3)',
        () async {
      // Feed A already carries the original post.
      final feedA = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://a.test/feed');
      await ingestFeedItems(
          db: db,
          profileId: profileId,
          feedId: feedA,
          items: const [
            FeedItem(
                title: 'Breaking: something happened',
                link: 'https://original.test/post',
                date: 'Tue, 04 Aug 2026 12:00:00 GMT',
                desc: '')
          ],
          nowMs: nowMs);

      // Feed B (a syndicating mirror) republishes the SAME canonical URL,
      // just with tracking params, one day later.
      final feedB = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://b.test/feed');
      final fetcher = ScriptedFetcher((url, headers) => textResponse('''
<rss><channel><title>Mirror</title>
  <item>
    <title>Breaking: something happened</title>
    <link>https://original.test/post?utm_source=mirror</link>
    <pubDate>Wed, 05 Aug 2026 12:00:00 GMT</pubDate>
  </item>
</channel></rss>
'''));
      final feedBRow = (await db.feedsDao.feedsOf(profileId))
          .firstWhere((f) => f.id == feedB);

      await repo(fetcher).refreshFeed(feedBRow);

      // Both rows exist (dedup hides, never deletes)…
      expect(await db.spineDao.worksOf(profileId), hasLength(2));
      // …but only the original shows in the river.
      final river = await db.feedsDao.riverItems(profileId);
      expect(river, hasLength(1));
      expect(river.single.feedTitle, isNot('Mirror'));
    });

    test('a feed URL with tracker-looking query params is fetched '
        'byte-identical — the normalizer never touches feed fetch URLs, '
        'only outbound article links and dedup canonicalization (Campaign '
        '5 Phase 4)', () async {
      final fetcher = ScriptedFetcher((url, headers) => textResponse(_rssTwo));
      final feedId = await db.feedsDao.insertFeed(
          profileId: profileId,
          url: 'https://cast.test/feed?utm_source=directory&fbclid=xyz');
      final feed = (await db.feedsDao.feedsOf(profileId))
          .firstWhere((f) => f.id == feedId);

      await repo(fetcher).refreshFeed(feed);

      expect(fetcher.calls.single.url.toString(),
          'https://cast.test/feed?utm_source=directory&fbclid=xyz',
          reason: "a feed URL's query params can be load-bearing (API "
              'keys, pagination tokens) — never strip them');
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

    test('a fresh refresh evicts stale audio per the feed\'s '
        'keepLatestAudio policy (P4 "archive, never forget")', () async {
      final dir = Directory.systemTemp.createTempSync('trellis-refresh-evict');
      addTearDown(() => dir.deleteSync(recursive: true));
      final services = testServices(dir);
      final fetcher = ScriptedFetcher((url, headers) => textResponse(_rssTwo));
      final feed = await seedFeed();
      await db.feedsDao.updatePlaybackSettings(feed.id, keepLatestAudio: 1);
      // Two episodes already on this feed (distinct guids from the RSS
      // fixture, so refresh doesn't re-touch them), each with real audio
      // already on disk from an earlier transcription.
      Future<int> seedWithAudio(
          {required String title,
          required String guid,
          required int publishedAtMs}) async {
        final url = 'https://cast.test/$guid.mp3';
        final workId = await db.spineDao.insertWork(
            profileId: profileId,
            kind: 'episode',
            title: title,
            persistence: 'ephemeron',
            firstSeenEpochDay: 100,
            sourceUrl: url);
        await db.feedsDao.insertEpisode(
            workId: workId,
            feedId: feed.id,
            guid: guid,
            enclosureUrl: url,
            publishedAtMs: publishedAtMs);
        final file = services.audioFileFor(workId, url);
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('audio for $title');
        return workId;
      }

      final older =
          await seedWithAudio(title: 'Older', guid: 'older', publishedAtMs: 1);
      final newer =
          await seedWithAudio(title: 'Newer', guid: 'newer', publishedAtMs: 2);
      final olderFile =
          services.audioFileFor(older, 'https://cast.test/older.mp3');
      final newerFile =
          services.audioFileFor(newer, 'https://cast.test/newer.mp3');

      final repository = FeedsRepository(
          db: db,
          fetcher: fetcher,
          services: services,
          now: () => DateTime.fromMillisecondsSinceEpoch(nowMs));
      final outcome = await repository.refreshFeed(feed);

      expect(outcome.status, RefreshStatus.fresh);
      expect(olderFile.existsSync(), isFalse,
          reason: 'beyond keepLatestAudio: 1');
      expect(newerFile.existsSync(), isTrue);
      expect((await db.feedsDao.episodeOf(older))!.archivedAtMs, isNotNull);
      expect(await db.spineDao.workById(older), isNotNull,
          reason: 'the row survives — only the file went');
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

    test('subscribing adopts the archive link from the first page', () async {
      final fetcher = ScriptedFetcher((url, headers) => textResponse('''
<rss><channel><title>The Night Sky Cast</title>
  <atom:link rel="next" href="https://cast.test/feed?page=2"/>
  <item><title>Aurora season</title><link>https://cast.test/aurora</link></item>
</channel></rss>
'''));
      await repo(fetcher)
          .subscribe(profileId: profileId, rawUrl: 'https://cast.test/feed');

      expect((await db.feedsDao.feedsOf(profileId)).single.nextPageUrl,
          'https://cast.test/feed?page=2');
    });
  });

  group('FeedsRepository fetchOlderEpisodes', () {
    late AppDatabase db;
    late int profileId;
    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      profileId = await db.profilesDao.create('Ada');
    });
    tearDown(() => db.close());

    FeedsRepository repo(ScriptedFetcher fetcher) =>
        FeedsRepository(db: db, fetcher: fetcher);

    Future<Feed> seedFeedWithNextPage(String? nextPageUrl) async {
      final id = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://cast.test/feed');
      await db.feedsDao.updateRefreshState(id,
          title: 'The Night Sky Cast',
          etag: null,
          lastModified: null,
          breakerJson: '{}',
          nextPageUrl: nextPageUrl,
          updateNextPageUrl: true);
      return (await db.feedsDao.feedsOf(profileId)).single;
    }

    test('no known archive link: reports the calm note, no fetch runs',
        () async {
      final fetcher =
          ScriptedFetcher((url, headers) => throw Exception('must not run'));
      final feed = await seedFeedWithNextPage(null);

      final outcome = await repo(fetcher).fetchOlderEpisodes(feed);

      expect(outcome.newItems, 0);
      expect(outcome.message,
          "The publisher's feed offers only these episodes — older ones "
          "aren't published in it.");
      expect(fetcher.calls, isEmpty);
    });

    test('walks the archive and ingests new older episodes, deduping what '
        'is already stored (the existing repository dedup path)', () async {
      final feed = await seedFeedWithNextPage('https://cast.test/feed?page=2');
      // Already subscribed: "Aurora season" is already in the DB, through
      // the same ingest path a normal refresh uses.
      await ingestFeedItems(db: db, profileId: profileId, feedId: feed.id,
          items: const [
            FeedItem(
                title: 'Aurora season',
                link: 'https://cast.test/aurora',
                date: '',
                desc: '')
          ],
          nowMs: 1000);

      final fetcher = ScriptedFetcher((url, headers) {
        expect(url.toString(), 'https://cast.test/feed?page=2');
        return textResponse('''
<rss><channel><title>t</title>
  <item><title>Aurora season</title><link>https://cast.test/aurora</link></item>
  <item><title>Comet watch</title><link>https://cast.test/comet</link></item>
</channel></rss>
''');
      });

      final outcome = await repo(fetcher).fetchOlderEpisodes(feed);

      expect(outcome.newItems, 1,
          reason: 'Aurora season was already stored; only Comet watch is new');
      expect(outcome.message, 'Found 1 older episode.');
      final titles =
          (await db.feedsDao.episodesOfFeed(feed.id)).map((r) => r.work.title);
      expect(titles, contains('Comet watch'));
    });

    test('an archive with nothing new reports the "no older episodes" '
        'sentence', () async {
      final feed = await seedFeedWithNextPage('https://cast.test/feed?page=2');
      final fetcher = ScriptedFetcher(
          (url, headers) => textResponse('<rss><channel><title>t</title>'
              '</channel></rss>'));

      final outcome = await repo(fetcher).fetchOlderEpisodes(feed);

      expect(outcome.newItems, 0);
      expect(outcome.message,
          "No older episodes were published in the feed's archive.");
    });

    test('a failed hop surfaces the honest technical sentence instead of a '
        'false "no older episodes" claim', () async {
      final feed = await seedFeedWithNextPage('https://cast.test/feed?page=2');
      final fetcher =
          ScriptedFetcher((url, headers) => throw Exception('reset'));

      final outcome = await repo(fetcher).fetchOlderEpisodes(feed);

      expect(outcome.newItems, 0);
      expect(outcome.message, isNot(contains('No older episodes')));
      expect(outcome.message, contains("couldn't be reached"));
    });
  });
}
