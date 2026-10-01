import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart' as dio;
import 'package:domovoi/domovoi.dart' show TransferOutcome;

import 'package:comms_core/comms_core.dart';
import 'package:drift/drift.dart' show ApplyInterceptor;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/feeds/feed_ingest.dart';
import 'package:trellis/features/feeds/feed_parse.dart';
import 'package:trellis/features/feeds/feed_rules.dart';
import 'package:trellis/features/feeds/feeds_repository.dart';
import 'package:trellis/features/transcribe/audio_fetcher.dart';
import 'package:trellis/services/device_services.dart';

import '../support/fake_services.dart';
import '../support/scripted_fetcher.dart';
import '../support/statement_counter.dart';

const _rssBlog = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel>
  <title>Field Notes</title>
  <item>
    <title>On hedges</title>
    <link>https://notes.test/hedges</link>
    <pubDate>Wed, 05 Aug 2026 12:00:00 GMT</pubDate>
    <description>Laid, not trimmed.</description>
  </item>
</channel></rss>
''';

const _rssEmpty = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel><title>Quiet</title></channel></rss>
''';

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
        nextAttemptMs: 777,
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
      expect(back.nextAttemptMs, 777);
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

    test('an item\'s own artwork and length are kept with its episode',
        () async {
      await ingestFeedItems(
          db: db,
          profileId: profileId,
          feedId: feedId,
          items: const [
            FeedItem(
                title: 'Aurora season',
                link: 'https://cast.test/aurora',
                date: 'Wed, 05 Aug 2026 12:00:00 GMT',
                desc: '',
                enclosure: Enclosure(url: 'https://cast.test/aurora.mp3'),
                imageUrl: 'https://cast.test/aurora.jpg',
                durationMs: 1800000),
          ],
          nowMs: nowMs);
      final work = (await db.spineDao.worksOf(profileId)).single;
      final episode = (await db.feedsDao.episodeOf(work.id))!;
      expect(episode.imageUrl, 'https://cast.test/aurora.jpg');
      expect(episode.durationMs, 1800000);
    });

    test('an episode seen before this release gains its length and artwork '
        'the next time the feed lists it', () async {
      const plain = FeedItem(
          title: 'Aurora season',
          link: 'https://cast.test/aurora',
          date: 'Wed, 05 Aug 2026 12:00:00 GMT',
          desc: '',
          enclosure: Enclosure(url: 'https://cast.test/aurora.mp3'));
      await ingestFeedItems(
          db: db,
          profileId: profileId,
          feedId: feedId,
          items: const [plain],
          nowMs: nowMs);
      final work = (await db.spineDao.worksOf(profileId)).single;
      await db.feedsDao.setDuration(work.id, 1234000);

      final added = await ingestFeedItems(
          db: db,
          profileId: profileId,
          feedId: feedId,
          items: const [
            FeedItem(
                title: 'Aurora season',
                link: 'https://cast.test/aurora',
                date: 'Wed, 05 Aug 2026 12:00:00 GMT',
                desc: '',
                enclosure: Enclosure(url: 'https://cast.test/aurora.mp3'),
                imageUrl: 'https://cast.test/aurora.jpg',
                durationMs: 1800000),
          ],
          nowMs: nowMs);

      expect(added, 0);
      final episode = (await db.feedsDao.episodeOf(work.id))!;
      expect(episode.imageUrl, 'https://cast.test/aurora.jpg');
      expect(episode.durationMs, 1234000,
          reason: 'a length the player measured beats what the feed says');
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

    group('full-content feeds (Campaign 9 Phase 4, "the feed becomes '
        'honest reading")', () {
      test('a text item whose contentHtml is meaningfully longer than its '
          'desc becomes a MULTI-paragraph work, not a 300-char stub',
          () async {
        final longBody = List.generate(
                5, (i) => '<p>Paragraph number $i, plenty of words here.</p>')
            .join();
        await ingestFeedItems(
            db: db,
            profileId: profileId,
            feedId: feedId,
            items: [
              FeedItem(
                  title: 'The whole post',
                  link: 'https://cast.test/post',
                  date: '',
                  desc: 'A short excerpt for the list.',
                  contentHtml: longBody),
            ],
            nowMs: nowMs);
        final work = (await db.spineDao.worksOf(profileId)).single;
        final segs = await db.spineDao.segmentsOf(work.id);
        expect(segs.length, 5,
            reason: 'one segment per extracted paragraph, not one stub');
        expect(segs.first.body, contains('Paragraph number 0'));
        expect(segs.first.body, isNot(contains('A short excerpt')),
            reason: 'the full content replaces the excerpt, not append to it');
      });

      test('a text item whose contentHtml is NOT meaningfully longer than '
          'its desc (a feed that just repeats the excerpt) falls back to '
          'the plain desc segment', () async {
        await ingestFeedItems(
            db: db,
            profileId: profileId,
            feedId: feedId,
            items: [
              FeedItem(
                  title: 'Short post',
                  link: 'https://cast.test/short',
                  date: '',
                  desc: 'The whole short post, all of it.',
                  contentHtml: '<p>The whole short post, all of it.</p>'),
            ],
            nowMs: nowMs);
        final work = (await db.spineDao.worksOf(profileId)).single;
        final segs = await db.spineDao.segmentsOf(work.id);
        expect(segs.single.body, 'The whole short post, all of it.');
      });

      test('a podcast episode (enclosure present) keeps show-notes as its '
          'body even when contentHtml is present — that is what '
          'show-notes are', () async {
        final longBody = List.generate(
                5, (i) => '<p>Paragraph number $i, plenty of words here.</p>')
            .join();
        await ingestFeedItems(
            db: db,
            profileId: profileId,
            feedId: feedId,
            items: [
              FeedItem(
                  title: 'Episode with notes',
                  link: 'https://cast.test/ep',
                  date: '',
                  desc: 'Show notes for this episode.',
                  enclosure:
                      const Enclosure(url: 'https://cast.test/ep.mp3'),
                  contentHtml: longBody),
            ],
            nowMs: nowMs);
        final work = (await db.spineDao.worksOf(profileId)).single;
        final segs = await db.spineDao.segmentsOf(work.id);
        expect(segs.single.body, 'Show notes for this episode.');
      });
    });

    group('full show notes (1.5.4)', () {
      FeedItem ep({String? notes, String guidSuffix = ''}) => FeedItem(
          title: 'Aurora season',
          link: 'https://cast.test/aurora$guidSuffix',
          date: 'Wed, 05 Aug 2026 12:00:00 GMT',
          desc: 'Lights in the north.',
          enclosure: Enclosure(url: 'https://cast.test/aurora$guidSuffix.mp3'),
          notesHtml: notes);

      test('an audio item stores its full notes, sanitized, beside the '
          'capped preview', () async {
        final long = 'Plenty of words about the aurora. ' * 30;
        await ingestFeedItems(
            db: db,
            profileId: profileId,
            feedId: feedId,
            items: [
              ep(
                  notes: '<p>$long</p><script>track()</script>'
                      '<p><a href="https://cast.test/map" onclick="x()">Map'
                      '</a><img src="https://t.test/p.gif" width="1" '
                      'height="1"></p>'),
            ],
            nowMs: nowMs);
        final work = (await db.spineDao.worksOf(profileId)).single;
        final notes = (await db.feedsDao.notesOf(work.id))!;
        expect(notes.html, contains(long.trim()));
        expect(notes.html, contains('<a href="https://cast.test/map">Map</a>'));
        expect(notes.html, isNot(contains('script')));
        expect(notes.html, isNot(contains('onclick')));
        expect(notes.html, isNot(contains('img')));
        expect(notes.plain, startsWith('Plenty of words'));
        // The row preview is still the capped desc.
        final segs = await db.spineDao.segmentsOf(work.id);
        expect(segs.single.body, 'Lights in the north.');
      });

      test('a text item stores no notes: its body is its segments', () async {
        await ingestFeedItems(
            db: db,
            profileId: profileId,
            feedId: feedId,
            items: const [
              FeedItem(
                  title: 'On hedges',
                  link: 'https://notes.test/hedges',
                  date: '',
                  desc: 'Laid, not trimmed.',
                  notesHtml: '<p>Laid, not trimmed.</p>'),
            ],
            nowMs: nowMs);
        final work = (await db.spineDao.worksOf(profileId)).single;
        expect(await db.feedsDao.notesOf(work.id), isNull);
      });

      test('notes that clean down to nothing are not cleaned again on every '
          'refresh', () async {
        await ingestFeedItems(
            db: db,
            profileId: profileId,
            feedId: feedId,
            items: [ep(notes: '<script>track()</script><img width="1" '
                'height="1" src="https://t.test/p.gif">')],
            nowMs: nowMs);
        expect(await db.feedsDao.notesGapsOf(feedId), isEmpty);
        final work = (await db.spineDao.worksOf(profileId)).single;
        expect(await db.feedsDao.notesOf(work.id), isNull,
            reason: 'nothing readable reads as no notes');
      });

      test('the first refresh after v29 fills a whole back catalogue, '
          'cleaned off the UI isolate', () async {
        List<FeedItem> listing({required bool notes}) => [
              for (var i = 0; i < offThreadPrepareCount + 10; i++)
                FeedItem(
                    title: 'Episode $i',
                    link: 'https://cast.test/e$i',
                    date: '',
                    desc: 'Preview $i.',
                    enclosure: Enclosure(url: 'https://cast.test/e$i.mp3'),
                    notesHtml: notes ? '<p>Notes for $i</p><script>x</script>' : null),
            ];
        await ingestFeedItems(
            db: db,
            profileId: profileId,
            feedId: feedId,
            items: listing(notes: false),
            nowMs: nowMs);
        expect(await db.feedsDao.notesGapsOf(feedId),
            hasLength(offThreadPrepareCount + 10));
        await ingestFeedItems(
            db: db,
            profileId: profileId,
            feedId: feedId,
            items: listing(notes: true),
            nowMs: nowMs);
        expect(await db.feedsDao.notesGapsOf(feedId), isEmpty);
        final works = await db.spineDao.worksOf(profileId);
        final some = await db.feedsDao.notesOf(works.first.id);
        expect(some!.html, startsWith('<p>Notes for '));
        expect(some.html, isNot(contains('script')));
      });

      test('a refresh fills notes a stored item lacks, never replaces them, '
          'and a listing that drops the item deletes nothing', () async {
        Future<void> ingest(List<FeedItem> items) => ingestFeedItems(
            db: db,
            profileId: profileId,
            feedId: feedId,
            items: items,
            nowMs: nowMs);
        // Stored before this release: no notes.
        await ingest([ep()]);
        final work = (await db.spineDao.worksOf(profileId)).single;
        expect(await db.feedsDao.notesOf(work.id), isNull);

        await ingest([ep(notes: '<p>First notes</p>')]);
        expect((await db.feedsDao.notesOf(work.id))!.html, '<p>First notes</p>');

        await ingest([ep(notes: '<p>Edited later</p>')]);
        expect((await db.feedsDao.notesOf(work.id))!.html, '<p>First notes</p>');

        await ingest([ep(notes: '<p>Other</p>', guidSuffix: '-2')]);
        final works = await db.spineDao.worksOf(profileId);
        expect(works, hasLength(2));
        expect((await db.feedsDao.notesOf(work.id))!.html, '<p>First notes</p>');
      });
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

  group('ingest cost (the Subscriptions lag)', () {
    late StatementCounter counter;
    late AppDatabase db;
    late int profileId;
    late int feedId;
    final nowMs = DateTime.utc(2026, 8, 6).millisecondsSinceEpoch;
    setUp(() async {
      counter = StatementCounter();
      db = AppDatabase.forTesting(
          NativeDatabase.memory().interceptWith(counter));
      profileId = await db.profilesDao.create('Ada');
      feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://cast.test/feed');
    });
    tearDown(() => db.close());

    String longPost(int i) => [
          for (var p = 0; p < 40; p++)
            '<p>Paragraph $p of post $i, long enough to read as prose and '
                'not as an excerpt of anything shorter.</p>',
        ].join();

    List<FeedItem> mixed(int n) => [
          for (var i = 0; i < n; i++)
            i.isEven
                ? FeedItem(
                    title: 'Episode $i',
                    link: 'https://cast.test/e$i',
                    date: 'Wed, 05 Aug 2026 12:00:00 GMT',
                    desc: 'Preview $i.',
                    enclosure: Enclosure(url: 'https://cast.test/e$i.mp3'),
                    notesHtml: '<p>Notes for $i</p><script>x</script>')
                : FeedItem(
                    title: 'Post $i',
                    link: 'https://cast.test/p$i',
                    date: 'Wed, 05 Aug 2026 12:00:00 GMT',
                    desc: 'Excerpt $i.',
                    contentHtml: longPost(i)),
        ];

    test('500 new items cost a fixed number of statements per table, '
        'not one per item', () async {
      final items = mixed(500);
      counter.calls.clear();
      final added = await ingestFeedItems(
          db: db,
          profileId: profileId,
          feedId: feedId,
          items: items,
          nowMs: nowMs,
          rules: const [
            FeedRule(
                field: FeedRuleField.title,
                match: FeedRuleMatch.contains,
                text: 'Episode 2',
                action: FeedRuleAction.autoKeep),
          ],
          offload: (batch) async => prepareFeedItems(batch));
      expect(added, 500);
      final perTable = counter.writesPerTable();
      for (final table in ['works', 'segments', 'episodes', 'work_notes']) {
        expect(perTable[table], inInclusiveRange(1, 2), reason: table);
      }
      expect(counter.calls.length, lessThan(25),
          reason: 'round trips: ${counter.calls.length}');
      // Everything still landed as before.
      expect(await db.select(db.episodes).get(), hasLength(500));
      expect(await db.feedsDao.notesGapsOf(feedId), isEmpty);
      final post = (await db.spineDao.worksOf(profileId))
          .firstWhere((w) => w.title == 'Post 1');
      expect(await db.spineDao.segmentsOf(post.id), hasLength(40));
      final kept = (await db.spineDao.worksOf(profileId))
          .where((w) => w.persistence == 'work')
          .map((w) => w.title);
      expect(kept, contains('Episode 2'));
      for (final w in await db.spineDao.worksOf(profileId)) {
        if (w.persistence == 'work') {
          expect((await db.feedsDao.episodeOf(w.id))!.readAtMs, nowMs);
        }
      }
    });

    test('a refresh of the same 500 items writes nothing', () async {
      final items = mixed(500);
      await ingestFeedItems(
          db: db,
          profileId: profileId,
          feedId: feedId,
          items: items,
          nowMs: nowMs,
          offload: (batch) async => prepareFeedItems(batch));
      counter.calls.clear();
      var hops = 0;
      final again = await ingestFeedItems(
          db: db,
          profileId: profileId,
          feedId: feedId,
          items: items,
          nowMs: nowMs,
          offload: (batch) async {
            hops++;
            return prepareFeedItems(batch);
          });
      expect(again, 0);
      expect(hops, 0, reason: 'nothing new to extract or clean');
      expect(counter.writesPerTable().keys,
          isNot(anyOf(contains('works'), contains('segments'),
              contains('episodes'), contains('work_notes'))));
    });

    test('a text feed of long posts is extracted off the UI isolate, in '
        'one hop before the transaction', () async {
      final batches = <int>[];
      await ingestFeedItems(
          db: db,
          profileId: profileId,
          feedId: feedId,
          items: [
            for (var i = 0; i < 15; i++)
              FeedItem(
                  title: 'Post $i',
                  link: 'https://news.test/p$i',
                  date: '',
                  desc: 'Excerpt.',
                  contentHtml: longPost(i)),
          ],
          nowMs: nowMs,
          offload: (batch) async {
            batches.add(batch.length);
            return prepareFeedItems(batch);
          });
      expect(batches, [15]);
      final works = await db.spineDao.worksOf(profileId);
      expect(works, hasLength(15));
      expect(await db.spineDao.segmentsOf(works.first.id), hasLength(40));
    });

    test('long posts extract the same through a real isolate', () async {
      await ingestFeedItems(
          db: db,
          profileId: profileId,
          feedId: feedId,
          items: [
            for (var i = 0; i < 15; i++)
              FeedItem(
                  title: 'Post $i',
                  link: 'https://news.test/p$i',
                  date: '',
                  desc: 'Excerpt.',
                  contentHtml: longPost(i)),
          ],
          nowMs: nowMs);
      final works = await db.spineDao.worksOf(profileId);
      expect(works, hasLength(15));
      final first = await db.spineDao.segmentsOf(works.first.id);
      expect(first, hasLength(40));
      expect(first.first.body, startsWith('Paragraph 0 of post'));
    });

    test('one short item is prepared in place: an isolate costs more',
        () async {
      var hops = 0;
      await ingestFeedItems(
          db: db,
          profileId: profileId,
          feedId: feedId,
          items: const [
            FeedItem(
                title: 'Short', link: 'https://news.test/s', date: '',
                desc: 'A line.'),
          ],
          nowMs: nowMs,
          offload: (batch) async {
            hops++;
            return prepareFeedItems(batch);
          });
      expect(hops, 0);
      expect(await db.spineDao.worksOf(profileId), hasLength(1));
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

    test('a pasted Mastodon profile follows its .rss, with no discovery '
        'fetch of the page', () async {
      final fetcher = ScriptedFetcher((url, headers) => textResponse(_rssBlog));
      final result = await repo(fetcher)
          .subscribe(profileId: profileId, rawUrl: 'mastodon.social/@alice');
      expect(result, isA<SubscribeSuccess>());
      expect(fetcher.calls.map((c) => c.url.toString()),
          ['https://mastodon.social/@alice.rss']);
      expect((await db.feedsDao.feedsOf(profileId)).single.url,
          'https://mastodon.social/@alice.rss');
    });

    test('a /@user page that is not Mastodon falls back to discovery when '
        'the .rss guess fails', () async {
      final fetcher = ScriptedFetcher((url, headers) => switch (url.toString()) {
            'https://blog.example/@bob.rss' =>
              textResponse('not here', status: 404),
            'https://blog.example/@bob' => textResponse(
                '<html><head><link rel="alternate" '
                'type="application/rss+xml" href="/rss.xml"></head></html>',
                headers: {'content-type': 'text/html'}),
            'https://blog.example/rss.xml' => textResponse(_rssBlog),
            _ => textResponse('nope', status: 404),
          });
      final result = await repo(fetcher)
          .subscribe(profileId: profileId, rawUrl: 'https://blog.example/@bob');
      expect(result, isA<SubscribeSuccess>());
      expect((await db.feedsDao.feedsOf(profileId)).single.url,
          'https://blog.example/rss.xml');
    });

    test('a fresh fetch keeps the declared language, which transcription '
        'finds from the episode', () async {
      var body = _rssTwo.replaceFirst(
          '<title>The Night Sky Cast</title>',
          '<title>The Night Sky Cast</title><language>ru-RU</language>');
      final fetcher = ScriptedFetcher((url, headers) => textResponse(body));
      final feed = await seedFeed();
      final r = repo(fetcher);
      await r.refreshFeed(feed);
      final stored = (await db.feedsDao.feedsOf(profileId)).single;
      expect(stored.language, 'ru-RU');
      final episode = (await db.feedsDao.riverItems(profileId))
          .firstWhere((e) => e.episode.enclosureUrl != null);
      expect(await db.feedsDao.languageOfWorkFeed(episode.work.id), 'ru-RU');

      // A listing that stops declaring one clears it.
      body = _rssTwo;
      await r.refreshFeed(stored);
      expect((await db.feedsDao.feedsOf(profileId)).single.language, isNull);
    });

    test('the same body again is not parsed again (ADR-0017)', () async {
      final fetcher =
          ScriptedFetcher((url, headers) => textResponse(_rssTwo));
      final feed = await seedFeed();
      final r = repo(fetcher);
      expect((await r.refreshFeed(feed)).status, RefreshStatus.fresh);
      final stored = (await db.feedsDao.feedsOf(profileId)).single;
      expect(stored.bodyHash, feedBodyHash(_rssTwo));

      final again = await r.refreshFeed(stored);
      expect(again.status, RefreshStatus.notModified);
      expect(again.newItems, 0);
      expect(await db.feedsDao.riverItems(profileId), hasLength(2));
    });

    test('changing the rules forgets the hash, so the same body ingests '
        'under them', () async {
      final fetcher =
          ScriptedFetcher((url, headers) => textResponse(_rssTwo));
      final feed = await seedFeed();
      await repo(fetcher).refreshFeed(feed);
      await db.feedsDao.setRules(feed.id, '[]');
      final stored = (await db.feedsDao.feedsOf(profileId)).single;
      expect(stored.bodyHash, isNull);
      expect((await repo(fetcher).refreshFeed(stored)).status,
          RefreshStatus.fresh);
    });

    test('a big body goes off the UI isolate and parses the same; a parse '
        'failure still lands as one after the hop', () async {
      final notes = 'x' * 1000;
      final extra = List.generate(300,
          (i) => '<item><title>t$i</title><link>https://l/$i/$notes</link></item>');
      final big = _rssTwo.replaceFirst('<item>', '${extra.join()}<item>');
      expect(parsesOffThread(big), isTrue);
      expect(parsesOffThread(_rssTwo), isFalse);
      // 36 of one listener's 112 feeds were under 256 KB, and a 200 KB
      // body is a multi-frame parse on a mid-range phone.
      expect(parsesOffThread('x' * 200 * 1024), isTrue);
      final parsed = await parseFeedBody(big, 'https://x.test/f');
      expect(parsed.feed!.items.length, parseRssFeed(big, 'u').items.length);
      expect(parsed.hash, feedBodyHash(big));
      await expectLater(
          parseFeedBody('<${'not xml ' * 40000}', 'https://x.test/f'),
          throwsA(isA<FeedParseException>()));
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
        nowMs += const Duration(days: 1).inMilliseconds; // past the backoff
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
      // A week on, the broken feed gets its automatic retry.
      nowMs += const Duration(days: 7).inMilliseconds;
      expect((await r.refreshFeed(broken)).status, RefreshStatus.error);
      expect(fetcher.calls, hasLength(6));
    });

    test('a failure backs off automatic refreshes; Try again does not wait '
        '(ADR-0017)', () async {
      var fail = true;
      final fetcher = ScriptedFetcher((url, headers) =>
          fail ? throw Exception('reset') : textResponse(_rssTwo));
      final r = repo(fetcher);
      await seedFeed();
      Future<Feed> row() async => (await db.feedsDao.feedsOf(profileId)).single;

      expect((await r.refreshFeed(await row())).status, RefreshStatus.error);
      nowMs += const Duration(minutes: 10).inMilliseconds;
      expect((await r.refreshFeed(await row())).status, RefreshStatus.skipped);
      expect(fetcher.calls, hasLength(1));
      fail = false;
      expect((await r.refreshFeed(await row(), force: true)).status,
          RefreshStatus.fresh);
      expect(stateOfFeed(await row()).nextAttemptMs, isNull);
    });

    test('a permanent move to something that is not a feed is not '
        'believed', () async {
      final fetcher = ScriptedFetcher((url, headers) => FetchResponse(
          statusCode: 200,
          headers: const {},
          body: Stream.value('this is not xml, a parked page'.codeUnits),
          permanentUrl: Uri.parse('https://parked.test/')));
      final feed = await seedFeed();
      expect((await repo(fetcher).refreshFeed(feed)).status,
          RefreshStatus.parseFailed);
      expect((await db.feedsDao.feedById(feed.id))!.url, feed.url);
    });

    test('a failed ingest keeps the old validators and hash, so the next '
        'refresh fetches the body again', () async {
      final fetcher = ScriptedFetcher((url, headers) =>
          textResponse(_rssTwo, headers: {'etag': '"new"'}));
      final feed = await seedFeed(etag: '"old"');
      await db.customStatement(
          'CREATE TRIGGER boom BEFORE INSERT ON episodes '
          "BEGIN SELECT RAISE(ABORT, 'disk trouble'); END");
      await expectLater(repo(fetcher).refreshFeed(feed), throwsA(anything));
      final after = (await db.feedsDao.feedsOf(profileId)).single;
      expect(after.etag, '"old"');
      expect(after.bodyHash, isNull);
      await db.customStatement('DROP TRIGGER boom');
      expect((await repo(fetcher).refreshFeed(after)).newItems, 2);
    });

    test('two ingests of the same listing at once store each item once and '
        'never throw', () async {
      final feed = await seedFeed();
      final items = parseRssFeed(_rssTwo, feed.url).items;
      final both = await Future.wait([
        for (var i = 0; i < 2; i++)
          ingestFeedItems(
              db: db,
              profileId: profileId,
              feedId: feed.id,
              items: items,
              nowMs: nowMs),
      ]);
      expect(both.fold<int>(0, (a, b) => a + b), 2);
      expect(await db.select(db.episodes).get(), hasLength(2));
      expect(await db.select(db.works).get(), hasLength(2),
          reason: 'no surplus work left behind');
    });

    test('a stored item already holding its (feed, guid) is yielded to, '
        'not thrown on', () async {
      final feed = await seedFeed();
      Future<int> work() => db.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: 't',
          persistence: 'ephemeron',
          firstSeenEpochDay: 1);
      expect(
          await db.feedsDao.insertEpisodeIfNew(
              workId: await work(), feedId: feed.id, guid: 'g',
              publishedAtMs: 1),
          isTrue);
      expect(
          await db.feedsDao.insertEpisodeIfNew(
              workId: await work(), feedId: feed.id, guid: 'g',
              publishedAtMs: 1),
          isFalse);
    });

    test('the same body ingests again once its rows are gone', () async {
      final fetcher =
          ScriptedFetcher((url, headers) => textResponse(_rssTwo));
      final feed = await seedFeed();
      await repo(fetcher).refreshFeed(feed);
      final ids = [
        for (final e in await db.select(db.episodes).get()) e.workId
      ];
      await db.spineDao.deleteWorks(ids);
      final stored = (await db.feedsDao.feedsOf(profileId)).single;
      final again = await repo(fetcher).refreshFeed(stored);
      expect(again.status, RefreshStatus.fresh);
      expect(again.newItems, 2);
    });

    test('a feed moved for good is followed to its new address; a temporary '
        'or colliding move changes nothing', () async {
      final fetcher = ScriptedFetcher((url, headers) => FetchResponse(
          statusCode: 200,
          headers: const {},
          body: Stream.value(_rssTwo.codeUnits),
          permanentUrl: Uri.parse('https://cast.test/new-feed')));
      final feed = await seedFeed();
      await repo(fetcher).refreshFeed(feed);
      expect((await db.feedsDao.feedById(feed.id))!.url,
          'https://cast.test/new-feed');

      // A second follow of the old address that the host also moved there:
      // the profile already has the new one, so this row keeps its own.
      final dupe = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://cast.test/old2');
      await repo(fetcher).refreshFeed((await db.feedsDao.feedById(dupe))!);
      expect((await db.feedsDao.feedById(dupe))!.url, 'https://cast.test/old2');
    });

    test('a show followed at an address that later moved is still matched '
        'by that address, so re-importing the old list adds no twin',
        () async {
      // Synthetic stand-ins for a newsletter that moved hosts for good.
      const old = 'https://old-host.test/archive/rss/';
      const moved = 'https://www.new-host.test/archive/rss/';
      final fetcher = ScriptedFetcher((url, headers) => FetchResponse(
          statusCode: 200,
          headers: const {},
          body: Stream.value(_rssBlog.codeUnits),
          permanentUrl: Uri.parse(moved)));
      final r = repo(fetcher);
      final (:added, existing: _) = await r.followOutlines(
          profileId, const [OpmlOutline(url: old, title: 'Old name')]);
      await r.refreshFeed(added.single);
      final row = (await db.feedsDao.feedById(added.single.id))!;
      expect(row.url, moved);
      expect(row.subscribedUrl, old);

      final again = await r.followOutlines(
          profileId, const [OpmlOutline(url: old, title: 'Old name')]);
      expect(again.added, isEmpty);
      expect(again.existing.map((f) => f.id), [row.id]);
      expect(await db.feedsDao.feedsOf(profileId), hasLength(1));

      // A second move keeps the first address, the one that was followed.
      await db.feedsDao.adoptUrl(row.id, 'https://third.test/rss');
      expect((await db.feedsDao.feedById(row.id))!.subscribedUrl, old);
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

    test('a fresh body that fails to parse records why, and keeps the old '
        'validators', () async {
      // Why: the donor skipped all bookkeeping here, so a feed that kept
      // serving junk looked healthy forever and its row never said why.
      final fetcher = ScriptedFetcher((url, headers) =>
          textResponse('this is not xml', headers: {'etag': '"new"'}));
      final feed = await seedFeed(etag: '"old"');

      final outcome = await repo(fetcher).refreshFeed(feed);
      expect(outcome.status, RefreshStatus.parseFailed);

      final after = (await db.feedsDao.feedsOf(profileId)).single;
      expect(after.etag, '"old"',
          reason: 'validators of an unparsed body must not be adopted');
      final state = stateOfFeed(after);
      expect(state.consecutiveFailures, 1);
      expect(state.lastError, contains('Not valid XML'));
    });

    group('origin (ADR-0016 section 3)', () {
      Future<String> originAfter(String body, {String? before}) async {
        final feed = await seedFeed();
        if (before != null) {
          await db.feedsDao.setOrigin(feed.id, before);
        }
        final fresh = (await db.feedsDao.feedsOf(profileId)).single;
        await repo(ScriptedFetcher((url, headers) => textResponse(body)))
            .refreshFeed(fresh);
        return (await db.feedsDao.feedsOf(profileId)).single.origin;
      }

      test('any item with audio makes it a podcast', () async {
        expect(await originAfter(_rssTwo, before: 'blog'), 'podcast');
      });

      test('a Ghost newsletter lands on the newsletter shelf, its posts '
          'read in full', () async {
        // comms_core's hand-written fixture, read from the package.
        final ghost = File(
                '../packages/comms_core/test/fixtures/ghost_newsletter.xml')
            .readAsStringSync();
        expect(originOf(parseRssFeed(ghost, 'https://hedgerow.test/rss/')),
            'blog');
        expect(await originAfter(ghost), 'blog');
        final works = await db.spineDao.worksOf(profileId);
        expect(works, hasLength(3));
        final well =
            works.firstWhere((w) => w.title == 'Who pays for the village well');
        expect(await db.spineDao.segmentsOf(well.id), hasLength(greaterThan(3)));
      });

      test('items with no audio make it a blog', () async {
        expect(await originAfter(_rssBlog), 'blog');
      });

      test('one text-only listing does not move a podcast with stored audio',
          () async {
        var body = _rssTwo;
        final r = repo(ScriptedFetcher((url, headers) => textResponse(body)));
        await seedFeed();
        await r.refreshFeed((await db.feedsDao.feedsOf(profileId)).single);
        body = _rssBlog;
        await r.refreshFeed((await db.feedsDao.feedsOf(profileId)).single,
            force: true);
        expect((await db.feedsDao.feedsOf(profileId)).single.origin,
            'podcast');
      });

      test('a parse with no items leaves the shelf alone', () async {
        expect(await originAfter(_rssEmpty, before: 'blog'), 'blog');
      });

      test('a body that will not parse leaves the shelf alone', () async {
        expect(await originAfter('not xml', before: 'blog'), 'blog');
      });

      test('origin is judged before rules, which may skip every item',
          () async {
        final feed = await seedFeed();
        await db.feedsDao.setRules(feed.id,
            encodeFeedRules(const [FeedRule(
                field: FeedRuleField.title, match: FeedRuleMatch.notContains,
                text: 'zzz', action: FeedRuleAction.skip)]));
        final fresh = (await db.feedsDao.feedsOf(profileId)).single;
        await repo(ScriptedFetcher((url, headers) => textResponse(_rssTwo)))
            .refreshFeed(fresh);
        expect((await db.feedsDao.feedsOf(profileId)).single.origin,
            'podcast');
      });
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

    test('a refresh whose channel artwork changed re-downloads once and '
        'updates the stored URL', () async {
      final dir = Directory.systemTemp.createTempSync('trellis-refresh-art');
      addTearDown(() => dir.deleteSync(recursive: true));
      final services = testServices(dir);
      final feed = await seedFeed();
      await db.feedsDao.updateRefreshState(feed.id,
          title: feed.title,
          etag: null,
          lastModified: null,
          breakerJson: '{}',
          imageUrl: 'https://cast.test/old.jpg',
          updateImageUrl: true);
      final seeded = (await db.feedsDao.feedsOf(profileId)).single;

      final fetcher = ScriptedFetcher((url, headers) => textResponse('''
<rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
<channel><title>The Night Sky Cast</title>
  <itunes:image href="https://cast.test/new.jpg"/>
</channel></rss>
'''));
      final repository = FeedsRepository(
          db: db,
          fetcher: fetcher,
          services: services,
          now: () => DateTime.fromMillisecondsSinceEpoch(nowMs));
      await repository.refreshFeed(seeded);

      final updated = (await db.feedsDao.feedsOf(profileId)).single;
      expect(updated.imageUrl, 'https://cast.test/new.jpg');
      expect(services.artworkFileFor(feed.id).existsSync(), isTrue);
      expect((services.audioFetcher as FakeAudioFetcher).fetched,
          ['https://cast.test/new.jpg']);
    });

    test('a refresh whose channel artwork is unchanged never re-fetches it '
        '(fetch-once, offline-first)', () async {
      final dir =
          Directory.systemTemp.createTempSync('trellis-refresh-art-same');
      addTearDown(() => dir.deleteSync(recursive: true));
      final services = testServices(dir);
      final feed = await seedFeed();
      await db.feedsDao.updateRefreshState(feed.id,
          title: feed.title,
          etag: null,
          lastModified: null,
          breakerJson: '{}',
          imageUrl: 'https://cast.test/art.jpg',
          updateImageUrl: true);
      final seeded = (await db.feedsDao.feedsOf(profileId)).single;

      final fetcher = ScriptedFetcher((url, headers) => textResponse('''
<rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
<channel><title>The Night Sky Cast</title>
  <itunes:image href="https://cast.test/art.jpg"/>
</channel></rss>
'''));
      final repository = FeedsRepository(
          db: db,
          fetcher: fetcher,
          services: services,
          now: () => DateTime.fromMillisecondsSinceEpoch(nowMs));
      await repository.refreshFeed(seeded);

      expect((services.audioFetcher as FakeAudioFetcher).fetched, isEmpty);
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

    test('subscribing records where the source came from', () async {
      final r = repo(ScriptedFetcher((url, headers) =>
          textResponse(url.path == '/blog' ? _rssBlog : _rssTwo)));
      await r.subscribe(profileId: profileId, rawUrl: 'https://cast.test/feed');
      await r.subscribe(
          profileId: profileId, rawUrl: 'https://notes.test/blog');
      final byUrl = {
        for (final f in await db.feedsDao.feedsOf(profileId)) f.url: f.origin
      };
      expect(byUrl, {
        'https://cast.test/feed': 'podcast',
        'https://notes.test/blog': 'blog',
      });
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

    test('subscribing downloads channel artwork once, to a deterministic '
        'local file (P6 "the river gets faces")', () async {
      final dir =
          Directory.systemTemp.createTempSync('trellis-subscribe-art');
      addTearDown(() => dir.deleteSync(recursive: true));
      final services = testServices(dir);
      final fetcher = ScriptedFetcher((url, headers) => textResponse('''
<rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
<channel><title>The Night Sky Cast</title>
  <itunes:image href="https://cast.test/art.jpg"/>
  <item><title>Aurora season</title><link>https://cast.test/aurora</link></item>
</channel></rss>
'''));
      final repository =
          FeedsRepository(db: db, fetcher: fetcher, services: services);
      final result = await repository.subscribe(
          profileId: profileId, rawUrl: 'https://cast.test/feed');
      expect(result, isA<SubscribeSuccess>());
      await repository.artworkSettled;
      final feed = (await db.feedsDao.feedsOf(profileId)).single;
      expect(feed.imageUrl, 'https://cast.test/art.jpg');
      expect(services.artworkFileFor(feed.id).existsSync(), isTrue);
      expect((services.audioFetcher as FakeAudioFetcher).fetched,
          ['https://cast.test/art.jpg']);
    });

    test('subscribing to a feed with no channel artwork downloads nothing',
        () async {
      final dir =
          Directory.systemTemp.createTempSync('trellis-subscribe-noart');
      addTearDown(() => dir.deleteSync(recursive: true));
      final services = testServices(dir);
      final fetcher = ScriptedFetcher((url, headers) => textResponse(_rssTwo));
      final repository =
          FeedsRepository(db: db, fetcher: fetcher, services: services);
      await repository.subscribe(
          profileId: profileId, rawUrl: 'https://cast.test/feed');
      await repository.artworkSettled;
      expect((services.audioFetcher as FakeAudioFetcher).fetched, isEmpty);
    });
  });

  group('episode artwork (ADR-0016)', () {
    late AppDatabase db;
    late int profileId;
    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      profileId = await db.profilesDao.create('Ada');
    });
    tearDown(() => db.close());

    String feedWith(List<String?> itemImages) => '''
<rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
<channel><title>The Night Sky Cast</title>
  <itunes:image href="https://cast.test/show.jpg"/>
  ${[
          for (var i = 0; i < itemImages.length; i++)
            '<item><title>Ep $i</title><link>https://cast.test/$i</link>'
                '<pubDate>${(i + 1).toString().padLeft(2, '0')} Jul 2026 12:00:00 GMT</pubDate>'
                '${itemImages[i] == null ? '' : '<itunes:image href="${itemImages[i]}"/>'}'
                '<enclosure url="https://cast.test/$i.mp3" type="audio/mpeg"/>'
                '</item>'
        ].join()}
</channel></rss>
''';

    Future<(DeviceServices, FakeAudioFetcher)> subscribe(String body,
        {bool localMl = true}) async {
      final dir = Directory.systemTemp.createTempSync('trellis-ep-art');
      addTearDown(() => dir.deleteSync(recursive: true));
      final services = testServices(dir, localMlAvailable: localMl);
      final repository = FeedsRepository(
          db: db,
          fetcher: ScriptedFetcher((u, h) => textResponse(body)),
          services: services);
      await repository.subscribe(
          profileId: profileId, rawUrl: 'https://cast.test/feed');
      await repository.artworkSettled;
      return (services, services.audioFetcher as FakeAudioFetcher);
    }

    test('an episode with its own artwork gets it on disk, once per image',
        () async {
      final (services, fetcher) = await subscribe(feedWith([
        'https://cast.test/a.jpg',
        'https://cast.test/a.jpg',
        'https://cast.test/b.jpg',
      ]));
      expect(fetcher.fetched.toSet(), {
        'https://cast.test/show.jpg',
        'https://cast.test/a.jpg',
        'https://cast.test/b.jpg',
      });
      expect(fetcher.fetched, hasLength(3), reason: 'a shared image once');
      expect(
          services.episodeArtworkFileFor('https://cast.test/a.jpg')
              .existsSync(),
          isTrue);
    });

    test('artwork that is just the show\'s own is never fetched twice',
        () async {
      final (_, fetcher) =
          await subscribe(feedWith(['https://cast.test/show.jpg', null]));
      expect(fetcher.fetched, ['https://cast.test/show.jpg']);
    });

    test('only the newest episodes\' artwork is fetched up front', () async {
      final (_, fetcher) = await subscribe(feedWith([
        for (var i = 0; i < 30; i++) 'https://cast.test/ep$i.jpg',
      ]));
      expect(fetcher.fetched.length - 1, episodeArtworkFetchLimit);
    });

    test('a refresh with nothing new still fetches artwork that is missing '
        '(a failed fetch, or a URL filled in later)', () async {
      final dir = Directory.systemTemp.createTempSync('trellis-ep-art-retry');
      addTearDown(() => dir.deleteSync(recursive: true));
      final fetcher = _ScriptedAudioFetcher()
        ..failing.add('https://cast.test/a.jpg');
      final services = testServices(dir, audioFetcher: fetcher);
      var body = feedWith(['https://cast.test/a.jpg', null]);
      final repository = FeedsRepository(
          db: db,
          fetcher: ScriptedFetcher((u, h) => textResponse(body)),
          services: services);
      await repository.subscribe(
          profileId: profileId, rawUrl: 'https://cast.test/feed');
      await repository.artworkSettled;
      expect(
          services.episodeArtworkFileFor('https://cast.test/a.jpg')
              .existsSync(),
          isFalse);

      fetcher.failing.clear();
      body = feedWith(['https://cast.test/a.jpg', 'https://cast.test/b.jpg']);
      final feed = (await db.feedsDao.feedsOf(profileId)).single;
      final outcome = await repository.refreshFeed(feed, force: true);
      await repository.artworkSettled;

      expect(outcome.newItems, 0);
      for (final url in ['https://cast.test/a.jpg', 'https://cast.test/b.jpg']) {
        expect(services.episodeArtworkFileFor(url).existsSync(), isTrue,
            reason: url);
      }
    });

    test('draining the artwork queue stops episode images not yet '
        'fetched, and keeps the show\'s own', () async {
      final dir = Directory.systemTemp.createTempSync('trellis-ep-art-drain');
      addTearDown(() => dir.deleteSync(recursive: true));
      final gate = Completer<void>();
      final fetcher = _ScriptedAudioFetcher()..gate = gate.future;
      final repository = FeedsRepository(
          db: db,
          fetcher: ScriptedFetcher((u, h) => textResponse(feedWith([
                'https://cast.test/a.jpg',
                'https://cast.test/b.jpg',
                'https://cast.test/c.jpg',
              ]))),
          services: testServices(dir, audioFetcher: fetcher));
      await repository.subscribe(
          profileId: profileId, rawUrl: 'https://cast.test/feed');
      await pumpEventQueue();
      // The show's artwork is in flight, held by the slow host.
      expect(fetcher.fetched, ['https://cast.test/show.jpg']);
      repository.drainArtwork();
      gate.complete();
      await repository.artworkSettled;
      expect(fetcher.fetched, ['https://cast.test/show.jpg'],
          reason: 'no episode image was started after the drain');
      // A later refresh fetches them as before: the files are still missing.
      final feed = (await db.feedsDao.feedsOf(profileId)).single;
      await repository.refreshFeed(feed, force: true);
      await repository.artworkSettled;
      expect(fetcher.fetched, hasLength(4));
    });

    test('following a show returns before a slow image host answers',
        () async {
      final dir = Directory.systemTemp.createTempSync('trellis-ep-art-slow');
      addTearDown(() => dir.deleteSync(recursive: true));
      final gate = Completer<void>();
      final fetcher = _ScriptedAudioFetcher()..gate = gate.future;
      final repository = FeedsRepository(
          db: db,
          fetcher: ScriptedFetcher(
              (u, h) => textResponse(feedWith(['https://cast.test/a.jpg']))),
          services: testServices(dir, audioFetcher: fetcher));

      final result = await repository
          .subscribe(profileId: profileId, rawUrl: 'https://cast.test/feed')
          .timeout(const Duration(seconds: 5));

      expect(result, isA<SubscribeSuccess>());
      await pumpEventQueue();
      expect(fetcher.fetched, isNotEmpty,
          reason: 'artwork is under way, held by the slow host');
      gate.complete();
      await repository.artworkSettled;
      expect(fetcher.fetched, contains('https://cast.test/a.jpg'));
    });

    test('the web tier fetches no episode artwork', () async {
      final (_, fetcher) = await subscribe(
          feedWith(['https://cast.test/a.jpg']),
          localMl: false);
      expect(fetcher.fetched, isNot(contains('https://cast.test/a.jpg')));
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
          'The publisher’s feed offers only these episodes. Older ones '
          'aren’t published in it.');
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
          'No older episodes were published in the feed’s archive.');
    });

    test('a failed hop surfaces the honest technical sentence instead of a '
        'false "no older episodes" claim', () async {
      final feed = await seedFeedWithNextPage('https://cast.test/feed?page=2');
      final fetcher =
          ScriptedFetcher((url, headers) => throw Exception('reset'));

      final outcome = await repo(fetcher).fetchOlderEpisodes(feed);

      expect(outcome.newItems, 0);
      expect(outcome.message, isNot(contains('No older episodes')));
      expect(outcome.message, contains("couldn’t be reached"));
    });
  });
}

/// Writes the target like [FakeAudioFetcher], but can hold every fetch
/// behind [gate] and throw for URLs in [failing].
class _ScriptedAudioFetcher implements AudioFetcher {
  final fetched = <String>[];
  final failing = <String>{};
  Future<void>? gate;

  @override
  Future<TransferOutcome> fetch(String url, File target,
      {dio.CancelToken? cancelToken,
      void Function(int received, int? total)? onProgress}) async {
    fetched.add(url);
    await gate;
    if (failing.contains(url)) throw const SocketException('unreachable');
    target.parent.createSync(recursive: true);
    target.writeAsStringSync('image for $url');
    return TransferOutcome.completed;
  }
}

