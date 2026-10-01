import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:trellis/db/database.dart';
import 'package:trellis/features/feeds/feeds_repository.dart';

import '../support/schema_strip.dart';
import '../support/scripted_fetcher.dart';

/// What is shared into Trellis lands in Latest under one local "Shared"
/// source: a feed row nothing ever fetches, so a shared item is an
/// ordinary row of the one river query.
void main() {
  late AppDatabase db;
  late int profileId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
  });
  tearDown(() => db.close());

  Future<int> sharedText(String title, int atMs, {String? label}) async {
    final feedId = await db.feedsDao.sharedFeedId(profileId);
    final w = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'note',
        title: title,
        persistence: 'ephemeron',
        firstSeenEpochDay: 1);
    await db.feedsDao.insertEpisode(
        workId: w,
        feedId: feedId,
        guid: 'text:$atMs',
        publishedAtMs: atMs,
        sourceLabel: label);
    return w;
  }

  test('the Shared source is made once per profile, named Shared, and is '
      'not a subscription', () async {
    final a = await db.feedsDao.sharedFeedId(profileId);
    expect(await db.feedsDao.sharedFeedId(profileId), a);
    final feed = (await db.feedsDao.feedById(a))!;
    expect(feed.title, 'Shared');
    expect(isSharedFeed(feed), isTrue);
    expect(await db.feedsDao.subscriptionsOf(profileId), isEmpty);
    final other = await db.profilesDao.create('Bo');
    expect(await db.feedsDao.sharedFeedId(other), isNot(a));
  });

  test('shared items sit in Latest newest first beside feed items, named by '
      'the app that shared them', () async {
    final feedId = await db.feedsDao
        .insertFeed(profileId: profileId, url: 'https://f', title: 'Show');
    final ep = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'article',
        title: 'Post',
        persistence: 'ephemeron',
        firstSeenEpochDay: 1);
    await db.feedsDao
        .insertEpisode(workId: ep, feedId: feedId, guid: 'g', publishedAtMs: 20);
    final old = await sharedText('Old note', 10);
    final report = await sharedText('Daily report', 30, label: 'Muse');

    final river = await db.feedsDao.riverItems(profileId);
    expect([for (final e in river) e.work.id], [report, ep, old]);
    expect([for (final e in river) e.feedTitle], ['Muse', 'Show', 'Shared']);
    expect((await db.feedsDao.riverEntryOf(report))!.feedTitle, 'Muse');
  });

  test('the Shared source is never fetched and never deduplicated against '
      'a followed show', () async {
    final w = await sharedText('On hedges', 10);
    final fetcher = ScriptedFetcher((url, headers) => textResponse(''));
    final repo = FeedsRepository(db: db, fetcher: fetcher);
    await repo.refreshAll(profileId);
    expect(fetcher.calls, isEmpty);
    final shared = (await db.feedsDao.feedById(
        await db.feedsDao.sharedFeedId(profileId)))!;
    expect(shared.breakerJson, '{}', reason: 'no failed fetch was recorded');
    expect([for (final c in await db.feedsDao.dedupCandidatesOf(profileId)) c.workId],
        isNot(contains(w)));
  });

  test('a shared work is found again by its address or a recent text',
      () async {
    final feedId = await db.feedsDao.sharedFeedId(profileId);
    final w = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'article',
        title: 'Essay',
        persistence: 'ephemeron',
        firstSeenEpochDay: 1,
        sourceUrl: 'https://example.org/essay-canonical');
    await db.feedsDao.insertEpisode(
        workId: w,
        feedId: feedId,
        guid: 'https://example.org/essay',
        publishedAtMs: 1);
    expect(await db.feedsDao.workBySharedUrl(profileId,
        'https://example.org/essay'), w);
    expect(await db.feedsDao.workBySharedUrl(profileId,
        'https://example.org/essay-canonical'), w);
    expect(await db.feedsDao.workBySharedUrl(profileId,
        'https://example.org/other'), isNull);

    final t = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'note',
        title: 'Note',
        persistence: 'ephemeron',
        firstSeenEpochDay: 1);
    await db.feedsDao.insertEpisode(
        workId: t, feedId: feedId, guid: 'text:abc:1000', publishedAtMs: 1000);
    expect(await db.feedsDao.sharedTextSince(profileId, 'abc', 900), t);
    expect(await db.feedsDao.sharedTextSince(profileId, 'abc', 1001), isNull);
    expect(await db.feedsDao.sharedTextSince(profileId, 'abd', 0), isNull);
  });

  group('schema migration v29 -> v30', () {
    test('adds the per-item source label and keeps every row', () async {
      final dir = Directory.systemTemp.createTempSync('trellis-migration-v30');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/v29.sqlite');
      final seed = AppDatabase.forTesting(NativeDatabase(file));
      final p = await seed.profilesDao.create('Ada');
      final f = await seed.feedsDao
          .insertFeed(profileId: p, url: 'https://f', title: 'Show');
      final w = await seed.spineDao.insertWork(
          profileId: p,
          kind: 'episode',
          title: 'Aurora',
          persistence: 'ephemeron',
          firstSeenEpochDay: 1);
      await seed.feedsDao.insertEpisode(
          workId: w,
          feedId: f,
          guid: 'g',
          enclosureUrl: 'https://f/a.mp3',
          publishedAtMs: 5);
      await seed.close();
      final v29 = raw.sqlite3.open(file.path);
      v29.execute('''
        $stripV30
        PRAGMA user_version = 29;
      ''');
      expect(
          v29
              .select("SELECT name FROM pragma_table_info('episodes') "
                  "WHERE name = 'source_label'")
              .isEmpty,
          isTrue);
      v29.dispose();

      final migrated = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(migrated.close);
      final river = await migrated.feedsDao.riverItems(p);
      expect(river.single.work.title, 'Aurora');
      expect(river.single.episode.sourceLabel, isNull);
      expect(river.single.feedTitle, 'Show');
      // And the new column takes writes.
      final shared = await migrated.feedsDao.sharedFeedId(p);
      final n = await migrated.spineDao.insertWork(
          profileId: p,
          kind: 'note',
          title: 'Note',
          persistence: 'ephemeron',
          firstSeenEpochDay: 1);
      await migrated.feedsDao.insertEpisode(
          workId: n,
          feedId: shared,
          guid: 'text:x:1',
          publishedAtMs: 9,
          sourceLabel: 'Muse');
      expect((await migrated.feedsDao.riverEntryOf(n))!.feedTitle, 'Muse');
    });

    test('a backup row from before v30 reads the label as absent', () {
      final row = Episode(
              workId: 1,
              feedId: 1,
              guid: 'g',
              publishedAtMs: 1)
          .toJson()
        ..remove('sourceLabel');
      expect(Episode.fromJson(row).sourceLabel, isNull);
    });
  });
}
