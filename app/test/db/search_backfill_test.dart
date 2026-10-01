import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:trellis/db/database.dart';
import 'package:trellis/db/search_index.dart';
import 'package:trellis/features/search/search_store.dart';

import '../support/schema_strip.dart';

/// The v29 index fills after the first frame (1.5.4 fix round): the hop
/// only builds the tables and triggers, and a resumable backfill indexes
/// the stored rows a batch at a time while search answers by LIKE.
void main() {
  late Directory dir;
  late File file;
  late int p;
  late int feed;
  final works = <int>[];

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('trellis-backfill');
    file = File('${dir.path}/v28.sqlite');
    works.clear();
    final seed = AppDatabase.forTesting(NativeDatabase(file));
    p = await seed.profilesDao.create('Ada');
    feed = await seed.feedsDao
        .insertFeed(profileId: p, url: 'https://c.test/f', title: 'Coastal');
    for (var i = 0; i < 7; i++) {
      final w = await seed.spineDao.insertWork(
          profileId: p,
          kind: 'episode',
          title: 'Machine $i',
          persistence: 'ephemeron',
          firstSeenEpochDay: 100);
      await seed.feedsDao.insertEpisode(
          workId: w,
          feedId: feed,
          guid: 'g$i',
          enclosureUrl: 'https://c.test/$i.mp3',
          publishedAtMs: i);
      works.add(w);
    }
    await seed.spineDao.insertSegments(works[0],
        const [(idx: 0, kind: 'prose', text: 'The lighthouse keeper.')]);
    await seed.spineDao.insertAlignments(
        works[0], const [(segmentIdx: 0, tStartMs: 0, tEndMs: 1)]);
    await seed.close();
    final v28 = raw.sqlite3.open(file.path);
    v28.execute('$stripV29\nPRAGMA user_version = 28;');
    v28.dispose();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<int> count(AppDatabase db, String table) async => (await db
          .customSelect('SELECT count(*) AS n FROM $table')
          .getSingle())
      .read<int>('n');

  test('the hop builds the index but fills none of it, and search still '
      'answers, by LIKE, saying how far the update is', () async {
    final db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    final s = SearchStore(db);
    await db.customSelect('SELECT 1').get(); // runs the hop
    expect(await count(db, 'items_fts'), 0);
    expect(await count(db, 'segments_fts'), 0);
    expect(await s.indexProgress, 0);
    expect(await s.usesIndex, isFalse);
    final r = await s.search(p, 'machine 3');
    expect([for (final i in r.items) i.work.id], [works[3]]);
    expect((await s.search(p, 'lighthouse')).said.single.item.work.id,
        works[0]);
    expect((await s.search(p, 'coastal')).shows.single.id, feed);
  });

  test('the backfill fills a batch at a time, resumes after a kill, and '
      'never doubles a row a trigger wrote meanwhile', () async {
    var db = AppDatabase.forTesting(NativeDatabase(file));
    expect(await SearchBackfill(db, batch: 3).step(), isTrue);
    expect(await count(db, 'items_fts'), 3);
    final s = SearchStore(db);
    expect(await s.indexProgress, 42); // 3 of 7
    // Mid-backfill: indexed and unindexed rows alike are found.
    expect({for (final i in (await s.search(p, 'machine')).items) i.work.id},
        works.toSet());
    // A new work, and a new sentence on a work not yet indexed.
    final fresh = await db.spineDao.insertWork(
        profileId: p,
        kind: 'book',
        title: 'Machine diary',
        persistence: 'work',
        firstSeenEpochDay: 100);
    await db.spineDao.insertSegments(works[5],
        const [(idx: 0, kind: 'prose', text: 'The lighthouse again.')]);
    await db.spineDao.insertAlignments(
        works[5], const [(segmentIdx: 0, tStartMs: 0, tEndMs: 1)]);
    await db.close(); // killed

    db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(() => db.close());
    await SearchBackfill(db, batch: 3).run(pause: Duration.zero);
    expect(await SearchStore(db).indexProgress, isNull);
    expect(await SearchStore(db).usesIndex, isTrue);
    expect(await count(db, 'items_fts'), works.length + 1);
    expect(await count(db, 'segments_fts'), 2);
    final r = await SearchStore(db).search(p, 'machines');
    expect({for (final i in r.items) i.work.id}, {...works, fresh});
    expect({for (final h in (await SearchStore(db).search(p, 'lighthouses')).said)
      h.item.work.id}, {works[0], works[5]});
    // Idempotent: running again changes nothing.
    expect(await SearchBackfill(db, batch: 3).step(), isFalse);
    await SearchBackfill(db).run(pause: Duration.zero);
    expect(await count(db, 'items_fts'), works.length + 1);
  });

  test('the fill waits for the hand-over from a background check '
      '(ADR-0018)', () async {
    final db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    final gate = Completer<void>();
    final running =
        SearchBackfill(db, batch: 3).run(after: gate.future, pause: Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(await count(db, 'items_fts'), 0);
    gate.complete();
    await running;
    expect(await count(db, 'items_fts'), works.length);
    expect(await SearchStore(db).indexProgress, isNull);
  });

  test('a fill that loses the lock to another connection backs off and '
      'finishes', () async {
    final db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get(); // the hop
    // As two connections in one process behave (ADR-0018): no waiting.
    await db.customStatement('PRAGMA busy_timeout = 0');
    final other = raw.sqlite3.open(file.path);
    other.execute('BEGIN IMMEDIATE');
    final released = Completer<void>();
    Timer(const Duration(milliseconds: 400), () {
      other.execute('COMMIT');
      released.complete();
    });
    await SearchBackfill(db,
            batch: 3,
            busyBudget: const Duration(milliseconds: 50),
            firstBackoff: const Duration(milliseconds: 20))
        .run(pause: Duration.zero);
    await released.future;
    other.dispose();
    expect(await SearchStore(db).indexProgress, isNull);
    expect(await count(db, 'items_fts'), works.length);
  });

  test('a fill that fails outright says so, and the next launch carries on',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get(); // the hop
    await db.customStatement('DROP TABLE segments_fts');
    await SearchBackfill(db).run(pause: Duration.zero);
    final s = SearchStore(db);
    expect(await s.indexProgress, 0);
    expect(await s.indexStalled, isTrue);
    await db.customStatement('CREATE VIRTUAL TABLE segments_fts USING '
        "fts5(body, tokenize = 'porter unicode61 remove_diacritics 2')");
    await SearchBackfill(db).run(pause: Duration.zero);
    expect(await s.indexProgress, isNull);
    expect(await s.indexStalled, isFalse);
  });

  test('a fresh install needs no backfill', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    expect(await SearchStore(db).indexProgress, isNull);
    expect(await SearchBackfill(db).step(), isFalse);
  });

  test('a restore indexes in full and ends a pending backfill', () async {
    final db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    await db.transaction(() => installSearchIndex(db));
    expect(await SearchStore(db).indexProgress, isNull);
    expect(await count(db, 'items_fts'), works.length);
  });

  test('a backfill whose works were all deleted still ends', () async {
    final db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    await db.customStatement('DELETE FROM episodes');
    for (final w in works) {
      await db.spineDao.deleteWork(w);
    }
    await SearchBackfill(db).run(pause: Duration.zero);
    expect(await SearchStore(db).indexProgress, isNull);
  });
}
