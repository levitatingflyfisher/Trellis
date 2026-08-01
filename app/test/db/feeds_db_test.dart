import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:trellis/db/database.dart';

/// The P2 feeds slice storage contract: feeds carry their refresh
/// bookkeeping, every feed item IS a spine work (ADR-0002) with a small
/// episodes row for river metadata, the river has exactly ONE ordering
/// (newest first, ADR-0003 law 1), and deleting a feed takes its unpromoted
/// ephemera with it — never a promoted work.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<int> seedProfile() => db.profilesDao.create('Ada');

  Future<int> seedEpisode({
    required int profileId,
    required int feedId,
    required String title,
    required int publishedAtMs,
    String? enclosureUrl,
    String persistence = 'ephemeron',
  }) async {
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: enclosureUrl != null ? 'episode' : 'article',
        title: title,
        persistence: persistence,
        firstSeenEpochDay: 100,
        sourceUrl: enclosureUrl);
    await db.feedsDao.insertEpisode(
        workId: workId,
        feedId: feedId,
        guid: 'guid-$title',
        enclosureUrl: enclosureUrl,
        publishedAtMs: publishedAtMs);
    return workId;
  }

  group('feeds table', () {
    test('a feed row round-trips url, title, validators and breaker json',
        () async {
      final profileId = await seedProfile();
      final feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://x.test/feed');

      await db.feedsDao.updateRefreshState(feedId,
          title: 'The X Cast',
          etag: '"e1"',
          lastModified: 'Wed, 05 Aug 2026 12:00:00 GMT',
          breakerJson: '{"consecutiveFailures":2}');

      final feed = (await db.feedsDao.feedsOf(profileId)).single;
      expect(feed.url, 'https://x.test/feed');
      expect(feed.title, 'The X Cast');
      expect(feed.etag, '"e1"');
      expect(feed.lastModified, 'Wed, 05 Aug 2026 12:00:00 GMT');
      expect(feed.breakerJson, '{"consecutiveFailures":2}');
      expect(feed.autoDownload, isFalse, reason: 'off by default');
    });

    test('feedByUrl finds the subscription; autoDownload flips', () async {
      final profileId = await seedProfile();
      final feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://x.test/feed');

      expect(
          (await db.feedsDao.feedByUrl(profileId, 'https://x.test/feed'))?.id,
          feedId);
      expect(await db.feedsDao.feedByUrl(profileId, 'https://y.test/feed'),
          isNull);

      await db.feedsDao.setAutoDownload(feedId, true);
      expect((await db.feedsDao.feedsOf(profileId)).single.autoDownload,
          isTrue);
    });
  });

  group('the river', () {
    test(
        'one reverse-chronological list across feeds — newest first, '
        'the only ordering', () async {
      final profileId = await seedProfile();
      final feedA = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://a.test/feed');
      final feedB = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://b.test/feed');

      // Insertion order deliberately scrambled relative to publish time.
      await seedEpisode(
          profileId: profileId,
          feedId: feedA,
          title: 'middle',
          publishedAtMs: 2000);
      await seedEpisode(
          profileId: profileId,
          feedId: feedB,
          title: 'newest',
          publishedAtMs: 3000,
          enclosureUrl: 'https://b.test/1.mp3');
      await seedEpisode(
          profileId: profileId,
          feedId: feedA,
          title: 'oldest',
          publishedAtMs: 1000);

      final river = await db.feedsDao.riverItems(profileId);
      expect(river.map((e) => e.work.title), ['newest', 'middle', 'oldest']);
    });

    test('river rows carry the feed title and unread state', () async {
      final profileId = await seedProfile();
      final feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://a.test/feed');
      await db.feedsDao.updateRefreshState(feedId,
          title: 'The A Cast', etag: null, lastModified: null,
          breakerJson: '{}');
      final workId = await seedEpisode(
          profileId: profileId,
          feedId: feedId,
          title: 'ep',
          publishedAtMs: 1000);

      var entry = (await db.feedsDao.riverItems(profileId)).single;
      expect(entry.feedTitle, 'The A Cast');
      expect(entry.episode.readAtMs, isNull, reason: 'arrives unread');

      await db.feedsDao.markRead(workId, 999);
      entry = (await db.feedsDao.riverItems(profileId)).single;
      expect(entry.episode.readAtMs, 999);
    });

    test('the river is per-profile', () async {
      final ada = await seedProfile();
      final blaise = await db.profilesDao.create('Blaise');
      final feedId =
          await db.feedsDao.insertFeed(profileId: ada, url: 'https://a/f');
      await seedEpisode(
          profileId: ada, feedId: feedId, title: 'ep', publishedAtMs: 1);

      expect(await db.feedsDao.riverItems(ada), hasLength(1));
      expect(await db.feedsDao.riverItems(blaise), isEmpty);
    });
  });

  group('episode metadata', () {
    test('the player writes back a learned duration', () async {
      final profileId = await seedProfile();
      final feedId =
          await db.feedsDao.insertFeed(profileId: profileId, url: 'https://a/f');
      final workId = await seedEpisode(
          profileId: profileId,
          feedId: feedId,
          title: 'ep',
          publishedAtMs: 1,
          enclosureUrl: 'https://a/1.mp3');

      await db.feedsDao.setDuration(workId, 1810000);
      expect((await db.feedsDao.episodeOf(workId))?.durationMs, 1810000);
    });

    test('guidsOf returns the feed\'s seen guids for dedupe', () async {
      final profileId = await seedProfile();
      final feedId =
          await db.feedsDao.insertFeed(profileId: profileId, url: 'https://a/f');
      await seedEpisode(
          profileId: profileId, feedId: feedId, title: 'one', publishedAtMs: 1);
      await seedEpisode(
          profileId: profileId, feedId: feedId, title: 'two', publishedAtMs: 2);

      expect(await db.feedsDao.guidsOf(feedId), {'guid-one', 'guid-two'});
    });
  });

  group('player positions (no alignments yet)', () {
    test('savePlayerPosition is a single-row upsert per (profile, work)',
        () async {
      final profileId = await seedProfile();
      final feedId =
          await db.feedsDao.insertFeed(profileId: profileId, url: 'https://a/f');
      final workId = await seedEpisode(
          profileId: profileId,
          feedId: feedId,
          title: 'ep',
          publishedAtMs: 1,
          enclosureUrl: 'https://a/1.mp3');

      await db.feedsDao
          .savePlayerPosition(profileId: profileId, workId: workId, tMs: 5000);
      await db.feedsDao
          .savePlayerPosition(profileId: profileId, workId: workId, tMs: 9000);

      final pos = await db.feedsDao
          .playerPosition(profileId: profileId, workId: workId);
      expect(pos!.tMs, 9000);
      expect(await db.feedsDao.allPlayerPositions(), hasLength(1));
    });
  });

  group('cascades', () {
    test('deleteWork also removes the episode row and player position',
        () async {
      final profileId = await seedProfile();
      final feedId =
          await db.feedsDao.insertFeed(profileId: profileId, url: 'https://a/f');
      final workId = await seedEpisode(
          profileId: profileId,
          feedId: feedId,
          title: 'ep',
          publishedAtMs: 1,
          enclosureUrl: 'https://a/1.mp3');
      await db.feedsDao
          .savePlayerPosition(profileId: profileId, workId: workId, tMs: 5000);

      await db.spineDao.deleteWork(workId);

      expect(await db.feedsDao.episodeOf(workId), isNull);
      expect(await db.feedsDao.allPlayerPositions(), isEmpty);
      expect(await db.feedsDao.riverItems(profileId), isEmpty);
    });

    test(
        'deleting a feed removes its unpromoted works; a promoted work '
        'stays in the library (only its river row goes)', () async {
      final profileId = await seedProfile();
      final feedId =
          await db.feedsDao.insertFeed(profileId: profileId, url: 'https://a/f');
      final ephemeronId = await seedEpisode(
          profileId: profileId,
          feedId: feedId,
          title: 'passing',
          publishedAtMs: 1);
      final keptId = await seedEpisode(
          profileId: profileId,
          feedId: feedId,
          title: 'kept',
          publishedAtMs: 2,
          enclosureUrl: 'https://a/1.mp3');
      await db.spineDao.insertSegments(
          ephemeronId, const [(idx: 0, kind: 'prose', text: 'x')]);
      await db.spineDao.promoteWork(keptId);

      await db.feedsDao.deleteFeedCascade(feedId);

      expect(await db.feedsDao.feedsOf(profileId), isEmpty);
      final titles =
          (await db.spineDao.worksOf(profileId)).map((w) => w.title);
      expect(titles, ['kept'],
          reason: 'the promoted work survives; the ephemeron is gone');
      expect(await db.spineDao.segmentsOf(ephemeronId), isEmpty,
          reason: 'the ephemeron\'s spine rows went with it');
      expect(await db.feedsDao.episodeOf(keptId), isNull,
          reason: 'the river row is unlinked; sourceUrl still plays it');
    });

    test('the ephemera sweep clears episode rows through deleteWork',
        () async {
      final profileId = await seedProfile();
      final feedId =
          await db.feedsDao.insertFeed(profileId: profileId, url: 'https://a/f');
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: 'old',
          persistence: 'ephemeron',
          firstSeenEpochDay: 100);
      await db.feedsDao.insertEpisode(
          workId: workId, feedId: feedId, guid: 'g', publishedAtMs: 1);

      final swept = await db.spineDao.sweepEphemera(todayEpochDay: 131);
      expect(swept, 1);
      expect(await db.feedsDao.episodeOf(workId), isNull);
    });
  });

  group('schema migration v1 → v2', () {
    test('a v1 database gains the feeds tables and keeps its data', () async {
      final dir = Directory.systemTemp.createTempSync('trellis-migration');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/v1.sqlite');

      // Build a real v1 file: drift's v1 DDL (snake_case, autoincrement ids)
      // with one profile, one work, one position — then stamp user_version 1.
      final v1 = raw.sqlite3.open(file.path);
      v1.execute('''
        CREATE TABLE profiles (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL);
        CREATE TABLE works (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          profile_id INTEGER NOT NULL REFERENCES profiles (id),
          kind TEXT NOT NULL,
          title TEXT NOT NULL,
          source_url TEXT NULL,
          lang TEXT NULL,
          persistence TEXT NOT NULL,
          first_seen_epoch_day INTEGER NOT NULL,
          pinned INTEGER NOT NULL DEFAULT 0 CHECK (pinned IN (0, 1)),
          finished_epoch_day INTEGER NULL);
        CREATE TABLE segments (
          work_id INTEGER NOT NULL REFERENCES works (id),
          idx INTEGER NOT NULL,
          kind TEXT NOT NULL,
          body TEXT NOT NULL,
          PRIMARY KEY (work_id, idx));
        CREATE TABLE layers (
          work_id INTEGER NOT NULL REFERENCES works (id),
          segment_idx INTEGER NOT NULL,
          lang TEXT NOT NULL,
          kind TEXT NOT NULL,
          body TEXT NOT NULL,
          PRIMARY KEY (work_id, segment_idx, lang));
        CREATE TABLE alignments (
          work_id INTEGER NOT NULL REFERENCES works (id),
          segment_idx INTEGER NOT NULL,
          t_start_ms INTEGER NOT NULL,
          t_end_ms INTEGER NOT NULL,
          word_timings BLOB NULL,
          PRIMARY KEY (work_id, segment_idx));
        CREATE TABLE positions (
          profile_id INTEGER NOT NULL REFERENCES profiles (id),
          work_id INTEGER NOT NULL REFERENCES works (id),
          segment_idx INTEGER NOT NULL,
          word_idx INTEGER NOT NULL,
          last_modality TEXT NOT NULL,
          updated_at_ms INTEGER NOT NULL,
          PRIMARY KEY (profile_id, work_id));
        INSERT INTO profiles (name) VALUES ('Ada');
        INSERT INTO works (profile_id, kind, title, source_url, lang,
          persistence, first_seen_epoch_day)
          VALUES (1, 'book', 'Kept Book', NULL, NULL, 'work', 100);
        INSERT INTO positions VALUES (1, 1, 4, 2, 'read', 123);
        PRAGMA user_version = 1;
      ''');
      v1.dispose();

      final migrated = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(migrated.close);

      // Old data survives…
      final work = (await migrated.spineDao.worksOf(1)).single;
      expect(work.title, 'Kept Book');
      final pos =
          await migrated.spineDao.position(profileId: 1, workId: work.id);
      expect(pos!.segmentIdx, 4);

      // …and the new tables exist and work.
      final feedId = await migrated.feedsDao
          .insertFeed(profileId: 1, url: 'https://a.test/feed');
      await migrated.feedsDao.insertEpisode(
          workId: work.id, feedId: feedId, guid: 'g', publishedAtMs: 1);
      await migrated.feedsDao
          .savePlayerPosition(profileId: 1, workId: work.id, tMs: 10);
      expect(await migrated.feedsDao.riverItems(1), hasLength(1));
    });
  });
}
