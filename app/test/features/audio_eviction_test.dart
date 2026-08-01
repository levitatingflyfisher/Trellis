import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/feeds/audio_eviction.dart';

import '../support/fake_services.dart';

/// The "keep latest N" selection law (P4 "archive, never forget"): among a
/// feed's episodes that actually HAVE audio on disk, which ones should
/// have it evicted. Pure — no files, no database, just publish times, the
/// keep count, and which work ids are immune.
void main() {
  group('audioEvictionCandidates', () {
    List<({int workId, int publishedAtMs})> eps(List<(int, int)> pairs) =>
        [for (final p in pairs) (workId: p.$1, publishedAtMs: p.$2)];

    test('null keepLatestAudio (keep everything) evicts nothing', () {
      final result = audioEvictionCandidates(
          episodesWithAudio: eps([(1, 100), (2, 200)]),
          keepLatestAudio: null,
          immuneWorkIds: const {});
      expect(result, isEmpty);
    });

    test('fewer episodes than the keep count evicts nothing', () {
      final result = audioEvictionCandidates(
          episodesWithAudio: eps([(1, 100), (2, 200)]),
          keepLatestAudio: 5,
          immuneWorkIds: const {});
      expect(result, isEmpty);
    });

    test('evicts the oldest beyond the keep count, newest N survive', () {
      final result = audioEvictionCandidates(
          episodesWithAudio: eps([(1, 100), (2, 300), (3, 200), (4, 400)]),
          keepLatestAudio: 2,
          immuneWorkIds: const {});
      // Newest two by publishedAtMs are 4 (400) and 2 (300) — kept.
      // Oldest two, 3 (200) and 1 (100), are evicted.
      expect(result.toSet(), {3, 1});
    });

    test('an immune work id (queued, mid-listen, or currently playing) '
        'never evicts even when it would otherwise be beyond the keep '
        'count', () {
      final result = audioEvictionCandidates(
          episodesWithAudio: eps([(1, 100), (2, 200), (3, 300)]),
          keepLatestAudio: 1,
          immuneWorkIds: {1});
      // Without immunity, both 1 and 2 would evict (only 3 survives).
      expect(result, [2]);
    });

    test('keepLatestAudio of 0 evicts everything not immune', () {
      final result = audioEvictionCandidates(
          episodesWithAudio: eps([(1, 100), (2, 200)]),
          keepLatestAudio: 0,
          immuneWorkIds: const {});
      expect(result.toSet(), {1, 2});
    });
  });

  group('evictStaleAudio (real files on disk)', () {
    late Directory dir;
    late AppDatabase db;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('trellis-eviction');
      db = AppDatabase.forTesting(NativeDatabase.memory());
    });
    tearDown(() {
      db.close();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    Future<int> seedEpisode(
        {required int profileId,
        required int feedId,
        required String title,
        required int publishedAtMs,
        required String enclosureUrl}) async {
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: title,
          persistence: 'ephemeron',
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

    File writeAudio(int workId, String url) {
      final file = testServices(dir).audioFileFor(workId, url);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('fake audio bytes');
      return file;
    }

    test('deletes the oldest file beyond keepLatestAudio and marks the '
        'row archived — never deletes the row', () async {
      final profileId = await db.profilesDao.create('Ada');
      final feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://a.test/f');
      await db.feedsDao.updatePlaybackSettings(feedId, keepLatestAudio: 1);
      final older = await seedEpisode(
          profileId: profileId,
          feedId: feedId,
          title: 'Older',
          publishedAtMs: 1000,
          enclosureUrl: 'https://a.test/older.mp3');
      final newer = await seedEpisode(
          profileId: profileId,
          feedId: feedId,
          title: 'Newer',
          publishedAtMs: 2000,
          enclosureUrl: 'https://a.test/newer.mp3');
      final olderFile = writeAudio(older, 'https://a.test/older.mp3');
      final newerFile = writeAudio(newer, 'https://a.test/newer.mp3');

      final evicted = await evictStaleAudio(
          db: db, services: testServices(dir), feedId: feedId, nowMs: 9999);

      expect(evicted, 1);
      expect(olderFile.existsSync(), isFalse);
      expect(newerFile.existsSync(), isTrue);
      expect((await db.feedsDao.episodeOf(older))!.archivedAtMs, 9999);
      expect((await db.feedsDao.episodeOf(newer))!.archivedAtMs, isNull);
      // The row survives — archive, never forget.
      expect(await db.spineDao.workById(older), isNotNull);
    });

    test('a queued episode is immune even if it would otherwise evict',
        () async {
      final profileId = await db.profilesDao.create('Ada');
      final feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://a.test/f');
      await db.feedsDao.updatePlaybackSettings(feedId, keepLatestAudio: 0);
      final queued = await seedEpisode(
          profileId: profileId,
          feedId: feedId,
          title: 'Queued',
          publishedAtMs: 1000,
          enclosureUrl: 'https://a.test/q.mp3');
      final queuedFile = writeAudio(queued, 'https://a.test/q.mp3');
      await db.queueDao
          .playLast(profileId: profileId, workId: queued, nowMs: 1);

      final evicted = await evictStaleAudio(
          db: db, services: testServices(dir), feedId: feedId, nowMs: 1);

      expect(evicted, 0);
      expect(queuedFile.existsSync(), isTrue);
    });

    test('a mid-listen episode (playerPosition tMs > 0) is immune',
        () async {
      final profileId = await db.profilesDao.create('Ada');
      final feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://a.test/f');
      await db.feedsDao.updatePlaybackSettings(feedId, keepLatestAudio: 0);
      final midListen = await seedEpisode(
          profileId: profileId,
          feedId: feedId,
          title: 'Mid-listen',
          publishedAtMs: 1000,
          enclosureUrl: 'https://a.test/m.mp3');
      final file = writeAudio(midListen, 'https://a.test/m.mp3');
      await db.feedsDao.savePlayerPosition(
          profileId: profileId, workId: midListen, tMs: 5000);

      final evicted = await evictStaleAudio(
          db: db, services: testServices(dir), feedId: feedId, nowMs: 1);

      expect(evicted, 0);
      expect(file.existsSync(), isTrue);
    });

    test('the currently-playing work id, when the caller knows it, is '
        'immune', () async {
      final profileId = await db.profilesDao.create('Ada');
      final feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://a.test/f');
      await db.feedsDao.updatePlaybackSettings(feedId, keepLatestAudio: 0);
      final playing = await seedEpisode(
          profileId: profileId,
          feedId: feedId,
          title: 'Playing',
          publishedAtMs: 1000,
          enclosureUrl: 'https://a.test/p.mp3');
      final file = writeAudio(playing, 'https://a.test/p.mp3');

      final evicted = await evictStaleAudio(
          db: db,
          services: testServices(dir),
          feedId: feedId,
          nowMs: 1,
          currentlyPlayingWorkId: playing);

      expect(evicted, 0);
      expect(file.existsSync(), isTrue);
    });

    test('keepLatestAudio null (the default) evicts nothing at all',
        () async {
      final profileId = await db.profilesDao.create('Ada');
      final feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://a.test/f');
      final work = await seedEpisode(
          profileId: profileId,
          feedId: feedId,
          title: 'Kept forever',
          publishedAtMs: 1000,
          enclosureUrl: 'https://a.test/k.mp3');
      final file = writeAudio(work, 'https://a.test/k.mp3');

      final evicted = await evictStaleAudio(
          db: db, services: testServices(dir), feedId: feedId, nowMs: 1);

      expect(evicted, 0);
      expect(file.existsSync(), isTrue);
    });
  });
}
