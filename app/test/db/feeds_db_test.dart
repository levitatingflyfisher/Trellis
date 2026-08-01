import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_prefs.dart';

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

    test('nextPageUrl defaults to null and round-trips when set', () async {
      final profileId = await seedProfile();
      final feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://x.test/feed');
      expect((await db.feedsDao.feedsOf(profileId)).single.nextPageUrl,
          isNull);

      await db.feedsDao.updateRefreshState(feedId,
          title: 'The X Cast',
          etag: null,
          lastModified: null,
          breakerJson: '{}',
          nextPageUrl: 'https://x.test/feed?page=2',
          updateNextPageUrl: true);

      expect((await db.feedsDao.feedsOf(profileId)).single.nextPageUrl,
          'https://x.test/feed?page=2');
    });

    test('updateRefreshState without updateNextPageUrl leaves the column '
        'untouched', () async {
      final profileId = await seedProfile();
      final feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://x.test/feed');
      await db.feedsDao.updateRefreshState(feedId,
          title: 'The X Cast',
          etag: null,
          lastModified: null,
          breakerJson: '{}',
          nextPageUrl: 'https://x.test/feed?page=2',
          updateNextPageUrl: true);

      // A later call that doesn't pass updateNextPageUrl (the non-fresh
      // refresh path — no new body means nothing new to say about the
      // archive) must not clear what was already known.
      await db.feedsDao.updateRefreshState(feedId,
          title: 'The X Cast',
          etag: null,
          lastModified: null,
          breakerJson: '{"consecutiveFailures":1}');

      expect((await db.feedsDao.feedsOf(profileId)).single.nextPageUrl,
          'https://x.test/feed?page=2');
    });

    test('updateNextPageUrl:true with a null value clears it — the host '
        'stopped advertising an archive', () async {
      final profileId = await seedProfile();
      final feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://x.test/feed');
      await db.feedsDao.updateRefreshState(feedId,
          title: 'The X Cast',
          etag: null,
          lastModified: null,
          breakerJson: '{}',
          nextPageUrl: 'https://x.test/feed?page=2',
          updateNextPageUrl: true);

      await db.feedsDao.updateRefreshState(feedId,
          title: 'The X Cast',
          etag: null,
          lastModified: null,
          breakerJson: '{}',
          updateNextPageUrl: true);

      expect((await db.feedsDao.feedsOf(profileId)).single.nextPageUrl,
          isNull);
    });

    test('imageUrl defaults to null and round-trips when set (P6 "the '
        'river gets faces")', () async {
      final profileId = await seedProfile();
      final feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://x.test/feed');
      expect(
          (await db.feedsDao.feedsOf(profileId)).single.imageUrl, isNull);

      await db.feedsDao.updateRefreshState(feedId,
          title: 'The X Cast',
          etag: null,
          lastModified: null,
          breakerJson: '{}',
          imageUrl: 'https://x.test/art.jpg',
          updateImageUrl: true);

      expect((await db.feedsDao.feedsOf(profileId)).single.imageUrl,
          'https://x.test/art.jpg');
    });

    test('updateRefreshState without updateImageUrl leaves the column '
        'untouched (a non-fresh refresh has nothing new to say)', () async {
      final profileId = await seedProfile();
      final feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://x.test/feed');
      await db.feedsDao.updateRefreshState(feedId,
          title: 'The X Cast',
          etag: null,
          lastModified: null,
          breakerJson: '{}',
          imageUrl: 'https://x.test/art.jpg',
          updateImageUrl: true);

      await db.feedsDao.updateRefreshState(feedId,
          title: 'The X Cast',
          etag: null,
          lastModified: null,
          breakerJson: '{"consecutiveFailures":1}');

      expect((await db.feedsDao.feedsOf(profileId)).single.imageUrl,
          'https://x.test/art.jpg');
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

    test('per-podcast playback settings default to null (defer to the '
        'app) and round-trip once set', () async {
      final profileId = await seedProfile();
      final feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://x.test/feed');

      final fresh = await db.feedsDao.feedById(feedId);
      expect(fresh!.speedOverride, isNull);
      expect(fresh.skipIntroSeconds, isNull);
      expect(fresh.skipOutroSeconds, isNull);

      await db.feedsDao.updatePlaybackSettings(feedId,
          speedOverride: 1.5, skipIntroSeconds: 12, skipOutroSeconds: 30);

      final updated = await db.feedsDao.feedById(feedId);
      expect(updated!.speedOverride, 1.5);
      expect(updated.skipIntroSeconds, 12);
      expect(updated.skipOutroSeconds, 30);
    });

    test('keepLatestAudio defaults to null (keep all) and round-trips',
        () async {
      final profileId = await seedProfile();
      final feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://x.test/feed');
      expect((await db.feedsDao.feedById(feedId))!.keepLatestAudio, isNull);

      await db.feedsDao.updatePlaybackSettings(feedId, keepLatestAudio: 3);

      expect((await db.feedsDao.feedById(feedId))!.keepLatestAudio, 3);
    });

    test('dspEnabled defaults to null (defer to the household default) and '
        'round-trips both ways', () async {
      final profileId = await seedProfile();
      final feedId = await db.feedsDao.insertFeed(
        profileId: profileId,
        url: 'https://x.test/feed',
      );
      expect((await db.feedsDao.feedById(feedId))!.dspEnabled, isNull);

      await db.feedsDao.updatePlaybackSettings(feedId, dspEnabled: true);
      expect((await db.feedsDao.feedById(feedId))!.dspEnabled, isTrue);

      await db.feedsDao.updatePlaybackSettings(feedId, dspEnabled: false);
      expect((await db.feedsDao.feedById(feedId))!.dspEnabled, isFalse);
    });

    test('per-podcast playback settings can be cleared back to null',
        () async {
      final profileId = await seedProfile();
      final feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://x.test/feed');
      await db.feedsDao.updatePlaybackSettings(feedId,
          speedOverride: 1.5, skipIntroSeconds: 12, skipOutroSeconds: 30);

      await db.feedsDao.updatePlaybackSettings(feedId,
          speedOverride: null, skipIntroSeconds: null, skipOutroSeconds: null);

      final cleared = await db.feedsDao.feedById(feedId);
      expect(cleared!.speedOverride, isNull);
      expect(cleared.skipIntroSeconds, isNull);
      expect(cleared.skipOutroSeconds, isNull);
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

    test('a dedup-suppressed episode is hidden from the river, but its row '
        'survives (hidden, not gone)', () async {
      final profileId = await seedProfile();
      final feedId =
          await db.feedsDao.insertFeed(profileId: profileId, url: 'https://a/f');
      final canonical = await seedEpisode(
          profileId: profileId, feedId: feedId, title: 'kept',
          publishedAtMs: 1000);
      final duplicate = await seedEpisode(
          profileId: profileId, feedId: feedId, title: 'dup',
          publishedAtMs: 2000);

      expect(await db.feedsDao.riverItems(profileId), hasLength(2));

      await db.feedsDao.setDedup(duplicate,
          reason: 'url', canonicalWorkId: canonical);

      final river = await db.feedsDao.riverItems(profileId);
      expect(river.map((e) => e.work.id), [canonical]);
      // The row itself is untouched — only hidden from this query.
      expect((await db.feedsDao.episodeOf(duplicate))!.dedupReason, 'url');
    });
  });

  group('feed rules (Campaign 5 Phase 3)', () {
    test('a fresh feed has no rules', () async {
      final profileId = await seedProfile();
      final feedId =
          await db.feedsDao.insertFeed(profileId: profileId, url: 'https://a/f');
      final feed = (await db.feedsDao.feedsOf(profileId)).single;
      expect(feed.rulesJson, '[]');
      expect(feedId, feed.id);
    });

    test('setRules persists and round-trips', () async {
      final profileId = await seedProfile();
      final feedId =
          await db.feedsDao.insertFeed(profileId: profileId, url: 'https://a/f');

      await db.feedsDao.setRules(feedId, '[{"field":"title"}]');

      final feed = (await db.feedsDao.feedsOf(profileId)).single;
      expect(feed.rulesJson, '[{"field":"title"}]');
    });
  });

  group('dedup candidates + setDedup (Campaign 5 Phase 3)', () {
    test('dedupCandidatesOf excludes already-suppressed episodes', () async {
      final profileId = await seedProfile();
      final feedId =
          await db.feedsDao.insertFeed(profileId: profileId, url: 'https://a/f');
      final a = await seedEpisode(
          profileId: profileId, feedId: feedId, title: 'a', publishedAtMs: 1);
      final b = await seedEpisode(
          profileId: profileId, feedId: feedId, title: 'b', publishedAtMs: 2);
      await db.feedsDao.setDedup(b, reason: 'title', canonicalWorkId: a);

      final candidates = await db.feedsDao.dedupCandidatesOf(profileId);
      expect(candidates.map((c) => c.workId), [a]);
    });

    test('setDedup then clearDedup round-trips both fields', () async {
      final profileId = await seedProfile();
      final feedId =
          await db.feedsDao.insertFeed(profileId: profileId, url: 'https://a/f');
      final a = await seedEpisode(
          profileId: profileId, feedId: feedId, title: 'a', publishedAtMs: 1);
      final b = await seedEpisode(
          profileId: profileId, feedId: feedId, title: 'b', publishedAtMs: 2);

      await db.feedsDao.setDedup(b, reason: 'url', canonicalWorkId: a);
      var episode = await db.feedsDao.episodeOf(b);
      expect(episode!.dedupReason, 'url');
      expect(episode.duplicateOfWorkId, a);

      await db.feedsDao.clearDedup(b);
      episode = await db.feedsDao.episodeOf(b);
      expect(episode!.dedupReason, isNull);
      expect(episode.duplicateOfWorkId, isNull);
    });
  });

  group('episodesOfFeed (the feed detail screen\'s query)', () {
    test('newest first, scoped to one feed', () async {
      final profileId = await seedProfile();
      final feedA = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://a.test/feed');
      final feedB = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://b.test/feed');
      await seedEpisode(
          profileId: profileId,
          feedId: feedA,
          title: 'older',
          publishedAtMs: 1000);
      await seedEpisode(
          profileId: profileId,
          feedId: feedA,
          title: 'newer',
          publishedAtMs: 2000);
      await seedEpisode(
          profileId: profileId,
          feedId: feedB,
          title: 'other feed',
          publishedAtMs: 3000);

      final rows = await db.feedsDao.episodesOfFeed(feedA);
      expect(rows.map((r) => r.work.title), ['newer', 'older']);
    });

    test('an empty feed yields an empty list', () async {
      final profileId = await seedProfile();
      final feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://a.test/feed');
      expect(await db.feedsDao.episodesOfFeed(feedId), isEmpty);
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

    test('setDspResult stores the original/processed durations the time '
        'saved counter sums, both null until a DSP pass has run', () async {
      final profileId = await seedProfile();
      final feedId = await db.feedsDao.insertFeed(
        profileId: profileId,
        url: 'https://a/f',
      );
      final workId = await seedEpisode(
        profileId: profileId,
        feedId: feedId,
        title: 'ep',
        publishedAtMs: 1,
        enclosureUrl: 'https://a/1.mp3',
      );
      final before = await db.feedsDao.episodeOf(workId);
      expect(before?.dspOriginalDurationMs, isNull);
      expect(before?.dspProcessedDurationMs, isNull);

      await db.feedsDao.setDspResult(
        workId,
        originalDurationMs: 600000,
        processedDurationMs: 540000,
      );

      final after = await db.feedsDao.episodeOf(workId);
      expect(after?.dspOriginalDurationMs, 600000);
      expect(after?.dspProcessedDurationMs, 540000);
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

    test('deleting the canonical side of a dedup pair un-suppresses the '
        'duplicate rather than leaving it hidden forever — "hidden" must '
        'never quietly become "lost"', () async {
      final profileId = await seedProfile();
      final feedId =
          await db.feedsDao.insertFeed(profileId: profileId, url: 'https://a/f');
      final canonical = await seedEpisode(
          profileId: profileId, feedId: feedId, title: 'kept',
          publishedAtMs: 1000);
      final duplicate = await seedEpisode(
          profileId: profileId, feedId: feedId, title: 'dup',
          publishedAtMs: 2000);
      await db.feedsDao
          .setDedup(duplicate, reason: 'url', canonicalWorkId: canonical);
      expect(await db.feedsDao.riverItems(profileId), hasLength(1));

      await db.spineDao.deleteWork(canonical);

      final episode = await db.feedsDao.episodeOf(duplicate);
      expect(episode != null, isTrue,
          reason: 'the duplicate row itself survives');
      expect(episode!.dedupReason, isNull);
      expect(episode.duplicateOfWorkId, isNull);
      expect(await db.feedsDao.riverItems(profileId),
          hasLength(1)); // now the FORMER duplicate is visible
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

      // Campaign 4 (v18): profiles.readerPrefsJson and readingDays must
      // reach a from=1 database too. This is the suite's ONLY from=1
      // fixture, so it is the only place a wrongly `from >= 2`-guarded
      // addColumn onto profiles (profiles predates v2 and is never
      // created inside onUpgrade, unlike feeds/episodes/playerPositions
      // above) can be caught — a guard with that lower bound reproduces
      // "Null check operator used on a null value" in $ProfilesTable.map
      // the instant something reads the column, which is exactly what
      // ReaderScreen._load() does on every reader open.
      expect((await migrated.profilesDao.readerPrefs(1)).typography,
          const ReaderTypography());
      await migrated
          .into(migrated.readingDays)
          .insertOnConflictUpdate(
              ReadingDaysCompanion.insert(profileId: 1, epochDay: 1));

      // Phase 5: HouseholdDao.lifetimeBuiltOf now COUNTs readingDays too —
      // a from=1 upgrader opening the parent dashboard exercises this
      // exact path, so it gets the same real-migration proof as the
      // reader's own readerPrefs call above.
      final built = await migrated.householdDao.lifetimeBuiltOf(1);
      expect(built.activeReadingDays, 1);
    });
  });

  group('schema migration v11 → v12', () {
    test('a v11 database gains the player-love campaign columns and the '
        'queue table, and keeps its data', () async {
      final dir =
          Directory.systemTemp.createTempSync('trellis-migration-v12');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/v11.sqlite');

      // Build a real v11 file from drift's own DDL: create at the current
      // version, drop exactly what v12 added, stamp user_version 11. Every
      // earlier version's own additions (v8's `nextPageUrl`, v9's
      // `scheduler`, v10's `captures`, v11's `daily_review_cards`) predate
      // this hop, so they all stay — only v12's own additions are
      // stripped. v13 (ADR-0008's Babel translation toggle) arrived AFTER
      // this test was written, landing on `works` — that column is
      // stripped here too, or a database claiming to be v11 would
      // silently already carry it and v13's own `addColumn` would fail as
      // a duplicate.
      final seed = AppDatabase.forTesting(NativeDatabase(file));
      final profileId = await seed.profilesDao.create('Ada');
      final feedId = await seed.feedsDao
          .insertFeed(profileId: profileId, url: 'https://a.test/f');
      final workId = await seed.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: 'Kept',
          persistence: 'work',
          firstSeenEpochDay: 100);
      await seed.feedsDao.insertEpisode(
          workId: workId, feedId: feedId, guid: 'g', publishedAtMs: 1);
      await seed.close();
      final v11 = raw.sqlite3.open(file.path);
      v11.execute('''
        ALTER TABLE feeds DROP COLUMN image_url;
        ALTER TABLE feeds DROP COLUMN speed_override;
        ALTER TABLE feeds DROP COLUMN skip_intro_seconds;
        ALTER TABLE feeds DROP COLUMN skip_outro_seconds;
        ALTER TABLE feeds DROP COLUMN keep_latest_audio;
        ALTER TABLE episodes DROP COLUMN archived_at_ms;
        ALTER TABLE profiles DROP COLUMN keep_finished_in_queue;
        DROP TABLE queue;
        ALTER TABLE works DROP COLUMN show_translation_layer;
        ALTER TABLE works DROP COLUMN active_translation_lang;
        ALTER TABLE feeds DROP COLUMN rules_json;
        ALTER TABLE episodes DROP COLUMN dedup_reason;
        ALTER TABLE episodes DROP COLUMN duplicate_of_work_id;
        ALTER TABLE feeds DROP COLUMN dsp_enabled;
        ALTER TABLE episodes DROP COLUMN dsp_original_duration_ms;
        ALTER TABLE episodes DROP COLUMN dsp_processed_duration_ms;
        ALTER TABLE profiles DROP COLUMN dsp_global_default;
        ALTER TABLE player_positions DROP COLUMN file_idx;
        ALTER TABLE captures DROP COLUMN file_idx;
        ALTER TABLE profiles DROP COLUMN reader_prefs_json;
        DROP TABLE reading_days;
        PRAGMA user_version = 11;
      ''');
      v11.dispose();

      final migrated = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(migrated.close);

      // Old data survives…
      final feed = (await migrated.feedsDao.feedsOf(profileId)).single;
      expect(feed.url, 'https://a.test/f');
      expect((await migrated.feedsDao.episodeOf(workId))!.guid, 'g');

      // …and every new column/table exists and works.
      await migrated.update(migrated.feeds).write(const FeedsCompanion(
          speedOverride: Value(1.25),
          skipIntroSeconds: Value(15),
          skipOutroSeconds: Value(20),
          keepLatestAudio: Value(5)));
      final updatedFeed = (await migrated.feedsDao.feedsOf(profileId)).single;
      expect(updatedFeed.speedOverride, 1.25);
      expect(updatedFeed.skipIntroSeconds, 15);
      expect(updatedFeed.skipOutroSeconds, 20);
      expect(updatedFeed.keepLatestAudio, 5);

      await migrated
          .update(migrated.episodes)
          .write(const EpisodesCompanion(archivedAtMs: Value(999)));
      expect((await migrated.feedsDao.episodeOf(workId))!.archivedAtMs, 999);

      await migrated
          .update(migrated.profiles)
          .write(const ProfilesCompanion(keepFinishedInQueue: Value(true)));
      expect((await migrated.profilesDao.all()).single.keepFinishedInQueue,
          isTrue);

      await migrated.into(migrated.queueTable).insert(QueueTableCompanion
          .insert(
              profileId: profileId,
              workId: workId,
              position: 0,
              addedAtMs: 1));
      expect(await migrated.select(migrated.queueTable).get(), hasLength(1));
    });
  });

  group('schema migration v12 -> v16', () {
    test(
      'a v12 database gains Campaign 6\'s DSP columns and keeps its data',
      () async {
        final dir = Directory.systemTemp.createTempSync(
          'trellis-migration-v16',
        );
        addTearDown(() => dir.deleteSync(recursive: true));
        final file = File('${dir.path}/v12.sqlite');

        // Seed at the CURRENT schema, then strip everything later than
        // v12 and stamp user_version 12 — that means v16's own additions
        // AND the sibling campaigns' v13/v15 hops (Babel's translation
        // layer, triage's rules/dedup/saved views), which a database
        // claiming to be v12 must not silently carry. Earlier versions'
        // additions (v8 through v12) predate this hop, so they all stay.
        final seed = AppDatabase.forTesting(NativeDatabase(file));
        final profileId = await seed.profilesDao.create('Ada');
        final feedId = await seed.feedsDao.insertFeed(
          profileId: profileId,
          url: 'https://a.test/f',
        );
        final workId = await seed.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: 'Kept',
          persistence: 'work',
          firstSeenEpochDay: 100,
        );
        await seed.feedsDao.insertEpisode(
          workId: workId,
          feedId: feedId,
          guid: 'g',
          publishedAtMs: 1,
        );
        await seed.close();
        final v12 = raw.sqlite3.open(file.path);
        v12.execute('''
        ALTER TABLE feeds DROP COLUMN image_url;
        DROP TABLE translation_sentences;
        DROP TABLE saved_views;
        ALTER TABLE works DROP COLUMN show_translation_layer;
        ALTER TABLE works DROP COLUMN active_translation_lang;
        ALTER TABLE feeds DROP COLUMN rules_json;
        ALTER TABLE episodes DROP COLUMN dedup_reason;
        ALTER TABLE episodes DROP COLUMN duplicate_of_work_id;
        ALTER TABLE feeds DROP COLUMN dsp_enabled;
        ALTER TABLE episodes DROP COLUMN dsp_original_duration_ms;
        ALTER TABLE episodes DROP COLUMN dsp_processed_duration_ms;
        ALTER TABLE profiles DROP COLUMN dsp_global_default;
        ALTER TABLE player_positions DROP COLUMN file_idx;
        ALTER TABLE captures DROP COLUMN file_idx;
        ALTER TABLE profiles DROP COLUMN reader_prefs_json;
        DROP TABLE reading_days;
        PRAGMA user_version = 12;
      ''');
        v12.dispose();

        final migrated = AppDatabase.forTesting(NativeDatabase(file));
        addTearDown(migrated.close);

        // Old data survives…
        final feed = (await migrated.feedsDao.feedsOf(profileId)).single;
        expect(feed.url, 'https://a.test/f');
        expect((await migrated.feedsDao.episodeOf(workId))!.guid, 'g');

        // …and every new column exists and works.
        await migrated
            .update(migrated.feeds)
            .write(const FeedsCompanion(dspEnabled: Value(true)));
        final updatedFeed = (await migrated.feedsDao.feedsOf(profileId)).single;
        expect(updatedFeed.dspEnabled, isTrue);

        await migrated
            .update(migrated.episodes)
            .write(
              const EpisodesCompanion(
                dspOriginalDurationMs: Value(600000),
                dspProcessedDurationMs: Value(540000),
              ),
            );
        final ep = (await migrated.feedsDao.episodeOf(workId))!;
        expect(ep.dspOriginalDurationMs, 600000);
        expect(ep.dspProcessedDurationMs, 540000);

        await migrated
            .update(migrated.profiles)
            .write(const ProfilesCompanion(dspGlobalDefault: Value(true)));
        expect(
          (await migrated.profilesDao.all()).single.dspGlobalDefault,
          isTrue,
        );
      },
    );
  });

  group('schema migration v18 -> v20', () {
    test(
      'a v18 database gains feeds.imageUrl and keeps its data '
      '(P6 "the river gets faces"; strips both v19 columns too, so this '
      'exercises the full v18->v19->v20 hop in one pass)',
      () async {
        final dir = Directory.systemTemp.createTempSync(
          'trellis-migration-v20',
        );
        addTearDown(() => dir.deleteSync(recursive: true));
        final file = File('${dir.path}/v18.sqlite');

        // Seed at the CURRENT schema, then strip everything later than
        // v18 and stamp user_version 18 — v20's own imageUrl column plus
        // Campaign 8's v19 additions (works.activeTranslationLang,
        // translation_sentences.engine), which a database claiming to be
        // v18 must not silently carry.
        final seed = AppDatabase.forTesting(NativeDatabase(file));
        final profileId = await seed.profilesDao.create('Ada');
        final feedId = await seed.feedsDao.insertFeed(
          profileId: profileId,
          url: 'https://a.test/f',
        );
        final workId = await seed.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: 'Kept',
          persistence: 'work',
          firstSeenEpochDay: 100,
        );
        await seed.feedsDao.insertEpisode(
          workId: workId,
          feedId: feedId,
          guid: 'g',
          publishedAtMs: 1,
        );
        await seed.close();
        final v18 = raw.sqlite3.open(file.path);
        v18.execute('''
        ALTER TABLE feeds DROP COLUMN image_url;
        ALTER TABLE translation_sentences DROP COLUMN engine;
        ALTER TABLE works DROP COLUMN active_translation_lang;
        PRAGMA user_version = 18;
      ''');
        v18.dispose();

        final migrated = AppDatabase.forTesting(NativeDatabase(file));
        addTearDown(migrated.close);

        // Old data survives…
        final feed = (await migrated.feedsDao.feedsOf(profileId)).single;
        expect(feed.url, 'https://a.test/f');
        expect((await migrated.feedsDao.episodeOf(workId))!.guid, 'g');
        expect(feed.imageUrl, isNull, reason: 'a fresh column starts null');

        // …and the new column exists and works.
        await migrated
            .update(migrated.feeds)
            .write(const FeedsCompanion(
                imageUrl: Value('https://a.test/art.jpg')));
        final updatedFeed = (await migrated.feedsDao.feedsOf(profileId)).single;
        expect(updatedFeed.imageUrl, 'https://a.test/art.jpg');
      },
    );
  });

  group('schema migration v19 -> v20 (Campaign 9 Phase 5, on a Babel-only '
      'build)', () {
    test(
      'a v19 database (Campaign 8 already merged, Campaign 9 not yet) '
      'gains feeds.imageUrl and keeps its v19 data',
      () async {
        final dir = Directory.systemTemp.createTempSync(
          'trellis-migration-v19-to-v20',
        );
        addTearDown(() => dir.deleteSync(recursive: true));
        final file = File('${dir.path}/v19.sqlite');

        // Seed at the CURRENT schema, use the v19 columns Babel shipped
        // (a real upgrader on that build has this data), then strip only
        // v20's own addition and stamp user_version 19 — the path a user
        // who already upgraded through Babel, but not yet through this
        // campaign, actually takes.
        final seed = AppDatabase.forTesting(NativeDatabase(file));
        final profileId = await seed.profilesDao.create('Ada');
        final feedId = await seed.feedsDao.insertFeed(
          profileId: profileId,
          url: 'https://a.test/f',
        );
        final workId = await seed.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: 'Kept',
          persistence: 'work',
          firstSeenEpochDay: 100,
        );
        await seed.feedsDao.insertEpisode(
          workId: workId,
          feedId: feedId,
          guid: 'g',
          publishedAtMs: 1,
        );
        await seed.spineDao.setActiveTranslationLang(workId, 'es');
        await seed.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: 'es',
          sourceText: 'Hi.',
          body: 'Hola.',
          engine: 'marian',
        );
        await seed.close();
        final v19 = raw.sqlite3.open(file.path);
        v19.execute('''
        ALTER TABLE feeds DROP COLUMN image_url;
        PRAGMA user_version = 19;
      ''');
        v19.dispose();

        final migrated = AppDatabase.forTesting(NativeDatabase(file));
        addTearDown(migrated.close);

        // v19 data survives the v20 hop…
        final feed = (await migrated.feedsDao.feedsOf(profileId)).single;
        expect(feed.url, 'https://a.test/f');
        expect(await migrated.spineDao.activeTranslationLang(workId), 'es');
        final sentences =
            await migrated.spineDao.translationSentencesOf(workId, lang: 'es');
        expect(sentences[(0, 0)]!.engine, 'marian');
        expect(feed.imageUrl, isNull, reason: 'a fresh column starts null');

        // …and the new column exists and works.
        await migrated
            .update(migrated.feeds)
            .write(const FeedsCompanion(
                imageUrl: Value('https://a.test/art.jpg')));
        final updatedFeed = (await migrated.feedsDao.feedsOf(profileId)).single;
        expect(updatedFeed.imageUrl, 'https://a.test/art.jpg');
      },
    );
  });
}
