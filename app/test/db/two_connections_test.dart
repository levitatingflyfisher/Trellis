// The background feed check (ADR-0018) opens its own connection to the
// same file while the app may hold another. These tests run two real
// connections, each on its own isolate as on a phone, against one file.
import 'dart:io';

import 'package:comms_core/comms_core.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/feeds/feed_dedup.dart';
import 'package:trellis/features/feeds/feed_ingest.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    // Two databases on one file is the point here, not a mistake.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    dir = Directory.systemTemp.createTempSync('trellis-two-conns');
    file = File('${dir.path}/t.sqlite');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  AppDatabase open() =>
      AppDatabase.forTesting(NativeDatabase.createInBackground(file));

  List<FeedItem> items(String prefix, int n) => [
        for (var i = 0; i < n; i++)
          FeedItem(
              title: '$prefix $i',
              link: 'https://cast.test/$prefix/$i',
              date: 'Wed, 05 Aug 2026 12:00:00 GMT',
              desc: 'Episode $i.',
              enclosure: Enclosure(url: 'https://cast.test/$prefix/$i.mp3')),
      ];

  test('two connections ingesting the same feeds at once store each item '
      'once and never throw', () async {
    final a = open();
    final b = open();
    addTearDown(a.close);
    addTearDown(b.close);
    final profileId = await a.profilesDao.create('Reader');
    final feedIds = [
      for (var f = 0; f < 6; f++)
        await a.feedsDao
            .insertFeed(profileId: profileId, url: 'https://cast.test/f$f'),
    ];
    final batches = {for (final id in feedIds) id: items('f$id', 40)};

    Future<void> ingestAll(AppDatabase db) => Future.wait([
          for (final id in feedIds)
            ingestFeedItems(
                db: db,
                profileId: profileId,
                feedId: id,
                items: batches[id]!,
                nowMs: 1),
        ]);

    await Future.wait([ingestAll(a), ingestAll(b)]);

    for (final id in feedIds) {
      expect((await a.feedsDao.guidsOf(id)).length, 40, reason: 'feed $id');
    }
    final rows = await a
        .customSelect('SELECT COUNT(*) AS n FROM episodes')
        .getSingle();
    expect(rows.read<int>('n'), 6 * 40);
  });

  test('dedup passes from both connections at once end where one pass over '
      'everything ends', () async {
    final a = open();
    final b = open();
    addTearDown(a.close);
    addTearDown(b.close);
    final profileId = await a.profilesDao.create('Reader');
    // The same 30 stories syndicated by three feeds: one pass hides the
    // younger copies and keeps the oldest of each visible.
    for (var f = 0; f < 3; f++) {
      final feedId = await a.feedsDao
          .insertFeed(profileId: profileId, url: 'https://news.test/f$f');
      await ingestFeedItems(
          db: a,
          profileId: profileId,
          feedId: feedId,
          nowMs: 1,
          items: [
            for (var i = 0; i < 30; i++)
              FeedItem(
                  title: 'Story $i',
                  link: 'https://news.test/story/$i',
                  date: 'Wed, 05 Aug 2026 1$f:00:00 GMT',
                  desc: ''),
          ]);
    }

    Future<void> pass(AppDatabase db) async {
      final verdicts =
          findDuplicates(await db.feedsDao.dedupCandidatesOf(profileId));
      for (final e in verdicts.entries) {
        await db.feedsDao.setDedup(e.key,
            reason: e.value.reason, canonicalWorkId: e.value.canonicalWorkId);
      }
    }

    await Future.wait([pass(a), pass(b), pass(a), pass(b)]);

    final visible = await a.feedsDao.dedupCandidatesOf(profileId);
    expect(visible.length, 30);
    // A second pass finds nothing left to hide.
    expect(findDuplicates(visible), isEmpty);
  });
}
