import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:trellis/db/database.dart';
import 'package:trellis/db/indexes.dart';

import '../support/schema_strip.dart';

/// Records every statement the app sends, so a test can EXPLAIN the DAO's
/// own SQL rather than a hand-copied string that could drift from it.
class _Recorder extends QueryInterceptor {
  final statements = <(String, List<Object?>)>[];

  void _log(String sql, List<Object?> args) => statements.add((sql, args));

  @override
  Future<List<Map<String, Object?>>> runSelect(
      QueryExecutor executor, String statement, List<Object?> args) {
    _log(statement, args);
    return executor.runSelect(statement, args);
  }

  @override
  Future<int> runUpdate(
      QueryExecutor executor, String statement, List<Object?> args) {
    _log(statement, args);
    return executor.runUpdate(statement, args);
  }

  @override
  Future<int> runDelete(
      QueryExecutor executor, String statement, List<Object?> args) {
    _log(statement, args);
    return executor.runDelete(statement, args);
  }

  @override
  Future<int> runInsert(
      QueryExecutor executor, String statement, List<Object?> args) {
    _log(statement, args);
    return executor.runInsert(statement, args);
  }
}

/// ADR-0017's database basics: indexes behind the hot queries, set-based
/// deletes, and the connection pragmas.
void main() {
  late AppDatabase db;
  late _Recorder rec;
  late int profileId;
  late int feedId;

  setUp(() async {
    rec = _Recorder();
    db = AppDatabase.forTesting(NativeDatabase.memory().interceptWith(rec));
    profileId = await db.profilesDao.create('Ada');
    feedId = await db.feedsDao.insertFeed(profileId: profileId, url: 'f');
  });
  tearDown(() => db.close());

  Future<int> episode(String guid,
      {int? feed, String persistence = 'ephemeron', int day = 100}) async {
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: guid,
        persistence: persistence,
        firstSeenEpochDay: day);
    await db.feedsDao.insertEpisode(
        workId: id, feedId: feed ?? feedId, guid: guid, publishedAtMs: id);
    return id;
  }

  Future<List<String>> planOf(Future<void> Function() query,
      {required String containing}) async {
    rec.statements.clear();
    await query();
    final (sql, args) =
        rec.statements.firstWhere((s) => s.$1.contains(containing));
    final plan = await db
        .customSelect('EXPLAIN QUERY PLAN $sql',
            variables: [for (final a in args) Variable(a)])
        .get();
    return [for (final r in plan) r.read<String>('detail')];
  }

  // Any SCAN, even one walking an index, reads the whole table.
  Iterable<String> scansOf(List<String> plan, List<String> tables) =>
      plan.where((d) => tables.any((t) => d.startsWith('SCAN $t')));

  group('the hot queries use an index', () {
    setUp(() async {
      for (var i = 0; i < 20; i++) {
        await episode('g$i');
      }
      // No ANALYZE: nothing runs it on a real file either.
    });

    test('guidsOf', () async {
      final plan = await planOf(() => db.feedsDao.guidsOf(feedId),
          containing: 'guid');
      expect(scansOf(plan, ['episodes']), isEmpty, reason: plan.join('\n'));
    });

    test('episodesOfFeed, both directions', () async {
      for (final oldestFirst in [false, true]) {
        final plan = await planOf(
            () => db.feedsDao.episodesOfFeed(feedId, oldestFirst: oldestFirst),
            containing: 'published_at_ms');
        expect(scansOf(plan, ['episodes', 'works']), isEmpty,
            reason: plan.join('\n'));
      }
    });

    test('riverItems', () async {
      final plan = await planOf(() => db.feedsDao.riverItems(profileId),
          containing: 'published_at_ms');
      expect(scansOf(plan, ['episodes', 'works']), isEmpty,
          reason: plan.join('\n'));
    });
  });

  test('a fresh database carries every index', () async {
    final names = (await db
            .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
            .get())
        .map((r) => r.read<String>('name'))
        .toSet();
    expect(names, containsAll(appIndexes.keys));
  });

  test('one row per item per feed is enforced by the schema', () async {
    await episode('same');
    await expectLater(episode('same'), throwsA(anything));
    final other = await db.feedsDao.insertFeed(profileId: profileId, url: 'o');
    await episode('same', feed: other);
  });

  group('set-based deletes', () {
    // A statement count that grows with the rows is the per-row loop the
    // audit found; chunks of a few hundred keep it flat.
    test('purging a thousand decayed works is a handful of statements, and '
        'takes every child row with it', () async {
      final ids = <int>[];
      await db.transaction(() async {
        for (var i = 0; i < 1200; i++) {
          ids.add(await episode('d$i', persistence: 'decayed'));
        }
      });
      await db.feedsDao.savePlayerPosition(
          profileId: profileId, workId: ids.last, tMs: 5);
      rec.statements.clear();
      await db.spineDao.purgeDecayed(profileId);
      expect(rec.statements.length, lessThan(60));
      expect(await db.spineDao.decayedOf(profileId), isEmpty);
      expect(await db.select(db.episodes).get(), isEmpty);
      expect(await db.feedsDao.allPlayerPositions(), isEmpty);
    });

    test('the sweep decays and expires in bulk, clearing suppressions that '
        'point at what left', () async {
      final ids = <int>[];
      await db.transaction(() async {
        for (var i = 0; i < 700; i++) {
          ids.add(await episode('e$i', day: 1));
        }
      });
      final other = await db.feedsDao.insertFeed(profileId: profileId, url: 'o');
      final dupe = await episode('x', feed: other, day: 1000);
      await db.feedsDao
          .setDedup(dupe, reason: 'url', canonicalWorkId: ids.first);
      rec.statements.clear();
      final n = await db.spineDao.sweepEphemera(todayEpochDay: 1000);
      expect(n, 700);
      expect(rec.statements.length, lessThan(40));
      expect((await db.feedsDao.episodeOf(dupe))!.dedupReason, isNull);

      rec.statements.clear();
      await db.spineDao.sweepEphemera(todayEpochDay: 1100);
      expect(rec.statements.length, lessThan(60));
      // Only the late arrival is left, decayed on this pass.
      expect((await db.spineDao.decayedOf(profileId)).map((w) => w.id),
          [dupe]);
    });

    test('unfollowing a feed with a large back catalogue keeps what was '
        'kept', () async {
      final kept = await episode('k', persistence: 'work');
      await db.transaction(() async {
        for (var i = 0; i < 600; i++) {
          await episode('u$i');
        }
      });
      rec.statements.clear();
      await db.feedsDao.deleteFeedCascade(feedId);
      expect(rec.statements.length, lessThan(40));
      expect(await db.select(db.episodes).get(), isEmpty);
      final works = await db.select(db.works).get();
      expect(works.map((w) => w.id), [kept]);
    });
  });

  test('ingesting a listing does not look each seen item up again',
      () async {
    // The no-op skip already existed; the cost was one SELECT per seen
    // item to discover there was nothing to fill.
    for (var i = 0; i < 50; i++) {
      await episode('s$i');
    }
    await db.feedsDao.fillMissingMetadata(feedId, 's0', durationMs: 9);
    final gaps = await db.feedsDao.metadataGapsOf(feedId);
    expect(gaps.length, 50);
    expect(gaps['s0'], (duration: false, image: true));
    expect(gaps['s1'], (duration: true, image: true));
  });

  group('connection pragmas', () {
    test('a file database runs WAL, NORMAL sync, a busy timeout and '
        'foreign keys', () async {
      final dir = Directory.systemTemp.createTempSync('trellis-pragmas');
      addTearDown(() => dir.deleteSync(recursive: true));
      final fileDb =
          AppDatabase.forTesting(NativeDatabase(File('${dir.path}/p.sqlite')));
      addTearDown(fileDb.close);
      Future<Object?> pragma(String p) async =>
          (await fileDb.customSelect('PRAGMA $p').getSingle()).data.values.first;
      expect(await pragma('journal_mode'), 'wal');
      expect(await pragma('synchronous'), 1);
      expect(await pragma('busy_timeout'), 5000);
      expect(await pragma('foreign_keys'), 1);
    });
  });

  group('schema migration v25 -> v26', () {
    test('duplicate items are folded, then the indexes land', () async {
      final dir = Directory.systemTemp.createTempSync('trellis-migration-v26');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/v25.sqlite');

      final seed = AppDatabase.forTesting(NativeDatabase(file));
      final p = await seed.profilesDao.create('Ada');
      final f = await seed.feedsDao.insertFeed(profileId: p, url: 'f');
      Future<int> work(String persistence) => seed.spineDao.insertWork(
          profileId: p,
          kind: 'episode',
          title: 't',
          persistence: persistence,
          firstSeenEpochDay: 1);
      final first = await work('ephemeron');
      final twin = await work('ephemeron');
      final keptTwin = await work('work');
      await seed.feedsDao.insertEpisode(
          workId: first, feedId: f, guid: 'g', publishedAtMs: 1);
      await seed.close();
      final v25 = raw.sqlite3.open(file.path);
      v25.execute('''
        $stripV26
        INSERT INTO episodes (work_id, feed_id, guid, published_at_ms)
          VALUES ($twin, $f, 'g', 1), ($keptTwin, $f, 'g', 1);
        PRAGMA user_version = 25;
      ''');
      v25.dispose();

      final migrated = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(migrated.close);
      final eps = await migrated.select(migrated.episodes).get();
      expect(eps.map((e) => e.workId), [first]);
      final works = (await migrated.select(migrated.works).get())
          .map((w) => w.id)
          .toSet();
      expect(works, {first, keptTwin},
          reason: 'a kept twin stays in the library; an unkept one goes');
      final names = (await migrated
              .customSelect(
                  "SELECT name FROM sqlite_master WHERE type = 'index'")
              .get())
          .map((r) => r.read<String>('name'))
          .toSet();
      expect(names, containsAll(appIndexes.keys));
    });
  });
}
