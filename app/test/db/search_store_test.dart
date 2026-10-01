import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:trellis/db/database.dart';
import 'package:trellis/features/search/history_days.dart';
import 'package:trellis/features/search/search_store.dart';

import '../support/schema_strip.dart';

/// History and search (ADR-0016 section 4): the FTS index follows its
/// rows through insert, rename and delete; transcript hits carry a
/// snippet and the time to seek to; history is most recent first.
void main() {
  late AppDatabase db;
  late SearchStore store;
  late int profileId;
  late int feedId;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = SearchStore(db);
    profileId = await db.profilesDao.create('Ada');
    feedId = await db.feedsDao.insertFeed(
        profileId: profileId,
        url: 'https://cast.test/f',
        title: 'Night Sky Hour');
  });
  tearDown(() => db.close());

  Future<int> episode(String title, {int publishedAtMs = 1, int? feed}) async {
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: title,
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/$title.mp3');
    await db.feedsDao.insertEpisode(
        workId: id,
        feedId: feed ?? feedId,
        guid: title,
        enclosureUrl: 'https://cast.test/$title.mp3',
        publishedAtMs: publishedAtMs);
    return id;
  }

  Future<int> book(String title, {int? profile}) => db.spineDao.insertWork(
      profileId: profile ?? profileId,
      kind: 'book',
      title: title,
      persistence: 'work',
      firstSeenEpochDay: 100);

  Future<void> transcribe(int workId, List<String> sentences) async {
    await db.spineDao.insertSegments(workId, [
      for (final (i, s) in sentences.indexed) (idx: i, kind: 'prose', text: s)
    ]);
    await db.spineDao.insertAlignments(workId, [
      for (var i = 0; i < sentences.length; i++)
        (segmentIdx: i, tStartMs: 60000 * i + 5000, tEndMs: 60000 * (i + 1))
    ]);
  }

  Iterable<String> titles(SearchResults r) => r.items.map((i) => i.work.title);

  group('the query', () {
    test('quotes every term and prefixes the last', () {
      expect(SearchStore.matchQuery('aurora sea'), '"aurora" "sea"*');
    });

    test('hostile input becomes plain terms', () {
      expect(SearchStore.matchQuery('c++ don\'t "x NEAR foo:'),
          '"c" "don" "t" "x" "NEAR" "foo"*');
      expect(SearchStore.matchQuery('  ::  '), isNull);
    });

    test('hostile input never throws from the database', () async {
      await episode('Aurora season');
      for (final q in ['"', 'NEAR(', 'foo:', '*', 'AND OR NOT', '(((']) {
        await store.search(profileId, q);
      }
    });
  });

  group('the index follows its rows', () {
    test('a fresh database carries it', () async {
      final rows = await db
          .customSelect("SELECT name FROM sqlite_master "
              "WHERE name IN ('items_fts', 'segments_fts')")
          .get();
      expect(rows, hasLength(2));
      // Every other test here would pass on the LIKE fallback too.
      expect(await store.usesIndex, isTrue);
    });

    test('a new title is found as it is typed', () async {
      await episode('Aurora season');
      expect(titles(await store.search(profileId, 'auro')), ['Aurora season']);
    });

    test('diacritics and case do not matter', () async {
      await book('Café Society');
      expect(titles(await store.search(profileId, 'cafe')), ['Café Society']);
    });

    test('a renamed work is found by its new name only', () async {
      final id = await episode('Aurora season');
      await (db.update(db.works)..where((w) => w.id.equals(id)))
          .write(const WorksCompanion(title: Value('Comet watch')));
      expect(titles(await store.search(profileId, 'aurora')), isEmpty);
      expect(titles(await store.search(profileId, 'comet')), ['Comet watch']);
    });

    test('a deleted work is gone from the index', () async {
      final id = await episode('Aurora season');
      await transcribe(id, ['The aurora was green tonight.']);
      await db.spineDao.deleteWork(id);
      final r = await store.search(profileId, 'aurora');
      expect(r.items, isEmpty);
      expect(r.said, isEmpty);
    });

    test('a show name finds its episodes, newest first', () async {
      await episode('First light', publishedAtMs: 1000);
      await episode('Second light', publishedAtMs: 2000);
      expect(titles(await store.search(profileId, 'night sky')),
          ['Second light', 'First light']);
    });

    test('a renamed show is found by its new name', () async {
      await episode('First light');
      await (db.update(db.feeds)..where((f) => f.id.equals(feedId)))
          .write(const FeedsCompanion(title: Value('Deep Field')));
      expect(titles(await store.search(profileId, 'night')), isEmpty);
      expect(titles(await store.search(profileId, 'deep field')),
          ['First light']);
    });

    test('words split between the show and the title still find it',
        () async {
      await episode('Episode 5');
      await episode('Episode 6');
      await episode('Episode 5', feed: await db.feedsDao.insertFeed(
          profileId: profileId, url: 'https://b.test/f', title: 'Serial'));
      final r = await store.search(profileId, 'night episode 5');
      expect([for (final i in r.items) (i.work.title, i.showTitle)],
          [('Episode 5', 'Night Sky Hour')]);
    });

    test('an unfollowed show leaves its kept episode findable by title only',
        () async {
      final id = await episode('Kept one');
      await db.spineDao.promoteWork(id);
      await db.feedsDao.deleteFeedCascade(feedId);
      expect(titles(await store.search(profileId, 'night')), isEmpty);
      expect(titles(await store.search(profileId, 'kept')), ['Kept one']);
    });

    test('a work matching by title and show is listed once', () async {
      await episode('Night sky notes');
      expect(titles(await store.search(profileId, 'night')),
          ['Night sky notes']);
    });

    test('another reader’s works never show', () async {
      final other = await db.profilesDao.create('Bo');
      await book('Aurora diary', profile: other);
      expect(titles(await store.search(profileId, 'aurora')), isEmpty);
    });
  });

  group('said in', () {
    test('the transcript query never scans a table', () async {
      final plan = await db.customSelect(
          'EXPLAIN QUERY PLAN ${SearchStore.saidSql}',
          variables: [Variable.withString('"x"'), Variable.withInt(1)]).get();
      final details = [for (final r in plan) r.read<String>('detail')];
      final scans = details.where((d) =>
          d.startsWith('SCAN ') && !d.contains('VIRTUAL TABLE'));
      expect(scans, isEmpty, reason: details.join('\n'));
      expect(details.join('\n'), isNot(contains('segments ')));
    });

    test('a transcript hit carries a marked snippet and its time', () async {
      final id = await episode('Episode 12');
      await transcribe(id, [
        'Welcome back to the show.',
        'Tonight the aurora reached as far south as Kansas.',
      ]);
      final hit = (await store.search(profileId, 'aurora')).said.single;
      expect(hit.item.work.id, id);
      expect(hit.segmentIdx, 1);
      expect(hit.tStartMs, 65000);
      final parts = parseSnippet(hit.snippet);
      expect(parts.where((p) => p.match).map((p) => p.text), ['aurora']);
      expect(parts.map((p) => p.text).join(), contains('reached as far'));
    });

    test('a sentence with no alignment is not a transcript', () async {
      final id = await book('Field guide');
      await db.spineDao.insertSegments(
          id, const [(idx: 0, kind: 'prose', text: 'The aurora explained.')]);
      expect((await store.search(profileId, 'aurora')).said, isEmpty);
    });

    test('a retranscribe replaces the old sentences', () async {
      final id = await episode('Episode 12');
      await transcribe(id, ['An aurora story.']);
      await db.transaction(() async {
        await (db.delete(db.alignments)..where((a) => a.workId.equals(id)))
            .go();
        await (db.delete(db.segments)..where((s) => s.workId.equals(id))).go();
        await transcribe(id, ['A comet story.']);
      });
      final r = await store.search(profileId, 'aurora');
      expect(r.said, isEmpty);
      expect((await store.search(profileId, 'comet')).said, hasLength(1));
    });

    test('an edited sentence is found by its new words', () async {
      final id = await episode('Episode 12');
      await transcribe(id, ['An aurora story.']);
      await (db.update(db.segments)..where((s) => s.workId.equals(id)))
          .write(const SegmentsCompanion(body: Value('A meteor story.')));
      expect((await store.search(profileId, 'aurora')).said, isEmpty);
      expect((await store.search(profileId, 'meteor')).said, hasLength(1));
    });
  });

  group('the snippet', () {
    test('splits on the match markers', () {
      final parts = parseSnippet('…the \u0002aurora\u0003 was \u0002green\u0003');
      expect([for (final p in parts) (p.text, p.match)], [
        ('…the ', false),
        ('aurora', true),
        (' was ', false),
        ('green', true),
      ]);
    });
  });

  group('history', () {
    Future<void> stampPosition(int workId, int at) async {
      await db.spineDao.savePosition(
          profileId: profileId,
          workId: workId,
          segmentIdx: 0,
          wordIdx: 3,
          lastModality: 'read');
      await db.customStatement(
          'UPDATE positions SET updated_at_ms = ? WHERE work_id = ?',
          [at, workId]);
    }

    Future<void> stampPlayer(int workId, int at) async {
      await db.feedsDao
          .savePlayerPosition(profileId: profileId, workId: workId, tMs: 10);
      await db.customStatement(
          'UPDATE player_positions SET updated_at_ms = ? WHERE work_id = ?',
          [at, workId]);
    }

    test('played, read and finished items, most recent first; untouched '
        'ones left out', () async {
      final finished = await episode('Finished');
      final listened = await episode('Listened');
      final read = await book('Read');
      await episode('Never touched');
      // Played to the end: what the player's finish writes.
      await db.spineDao.markFinished(finished, 1);
      await db.feedsDao.setFinished(finished, 3000);
      await stampPlayer(listened, 5000);
      await stampPosition(read, 4000);
      final h = await store.history(profileId);
      expect([for (final e in h) (e.item.work.title, e.atMs)],
          [('Listened', 5000), ('Read', 4000), ('Finished', 3000)]);
      expect(h.first.item.showTitle, 'Night Sky Hour');
      expect(h.first.item.episode, isNotNull);
      expect(h[1].item.episode, isNull);
    });

    test('the latest touch of an item is its place', () async {
      final id = await episode('Twice');
      await db.feedsDao.markPlayed(id, 1000);
      await stampPlayer(id, 9000);
      final h = await store.history(profileId);
      expect([for (final e in h) e.atMs], [9000]);
    });

    test('marked played without listening is not history', () async {
      final id = await episode('Cleared');
      await db.feedsDao.markPlayed(id, 5000);
      expect(await store.history(profileId), isEmpty);
    });

    test('opened but never moved is not history', () async {
      final heard = await episode('Barely');
      final read = await book('Unread');
      await db.feedsDao
          .savePlayerPosition(profileId: profileId, workId: heard, tMs: 0);
      await db.spineDao.savePosition(
          profileId: profileId,
          workId: read,
          segmentIdx: 0,
          wordIdx: 0,
          lastModality: 'read');
      expect(await store.history(profileId), isEmpty);
    });

    test('a triaged item is not history', () async {
      final id = await episode('Let pass');
      await db.feedsDao.markRead(id, 5000);
      expect(await store.history(profileId), isEmpty);
    });

    test('another reader’s history never shows', () async {
      final other = await db.profilesDao.create('Bo');
      final id = await book('Theirs', profile: other);
      await db.spineDao.savePosition(
          profileId: other,
          workId: id,
          segmentIdx: 1,
          wordIdx: 0,
          lastModality: 'read');
      expect(await store.history(profileId), isEmpty);
    });
  });

  group('grouped by day', () {
    final now = DateTime(2026, 10, 22, 9);
    int at(DateTime d) => d.millisecondsSinceEpoch;

    test('Today, Yesterday, then dates, by local calendar day', () {
      expect(dayLabel(at(DateTime(2026, 10, 22, 0, 5)), now), 'Today');
      expect(dayLabel(at(DateTime(2026, 10, 21, 23, 55)), now), 'Yesterday');
      expect(dayLabel(at(DateTime(2026, 10, 20, 12)), now), 'Tue 20 Oct');
      expect(dayLabel(at(DateTime(2025, 12, 31, 12)), now), 'Wed 31 Dec 2025');
    });

    test('runs of the same day share one heading', () {
      final groups = groupByDay(
          [at(DateTime(2026, 10, 22, 8)), at(DateTime(2026, 10, 22, 1)),
            at(DateTime(2026, 10, 20, 8))],
          (ms) => ms,
          now);
      expect([for (final g in groups) (g.label, g.items.length)],
          [('Today', 2), ('Tue 20 Oct', 1)]);
    });
  });

  group('schema migration v24 -> v25', () {
    test('a v24 database gains the index, filled from its rows', () async {
      final dir = Directory.systemTemp.createTempSync('trellis-migration-v25');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/v24.sqlite');

      final seed = AppDatabase.forTesting(NativeDatabase(file));
      final p = await seed.profilesDao.create('Ada');
      final f = await seed.feedsDao
          .insertFeed(profileId: p, url: 'https://a.test/f', title: 'Deep Field');
      final w = await seed.spineDao.insertWork(
          profileId: p,
          kind: 'episode',
          title: 'Aurora season',
          persistence: 'work',
          firstSeenEpochDay: 100,
          sourceUrl: 'https://a.test/a.mp3');
      await seed.feedsDao.insertEpisode(
          workId: w, feedId: f, guid: 'g', publishedAtMs: 1);
      await seed.spineDao.insertSegments(
          w, const [(idx: 0, kind: 'prose', text: 'A green comet tonight.')]);
      await seed.spineDao.insertAlignments(
          w, const [(segmentIdx: 0, tStartMs: 0, tEndMs: 1000)]);
      await seed.close();
      final v24 = raw.sqlite3.open(file.path);
      final triggers = v24
          .select("SELECT name FROM sqlite_master WHERE type = 'trigger' "
              "AND name LIKE '%fts%'")
          .map((r) => r['name'] as String)
          .toList();
      expect(triggers, isNotEmpty, reason: 'a fresh file carries the index');
      for (final t in triggers) {
        v24.execute('DROP TRIGGER $t');
      }
      v24.execute('''
        $stripV26
        DROP TABLE items_fts;
        DROP TABLE segments_fts;
        PRAGMA user_version = 24;
      ''');
      v24.dispose();

      final migrated = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(migrated.close);
      final s = SearchStore(migrated);
      expect(titles(await s.search(p, 'aurora')), ['Aurora season']);
      expect(titles(await s.search(p, 'deep')), ['Aurora season']);
      expect((await s.search(p, 'comet')).said.single.item.work.id, w);
      // And the triggers came back with it.
      await migrated.spineDao.insertWork(
          profileId: p,
          kind: 'book',
          title: 'Borealis',
          persistence: 'work',
          firstSeenEpochDay: 100);
      expect(titles(await s.search(p, 'borealis')), ['Borealis']);
    });
  });

  group('without FTS5', () {
    test('search falls back to LIKE and still finds titles and sentences',
        () async {
      final id = await episode('Aurora season');
      await transcribe(id, ['A green comet tonight.']);
      final s = SearchStore(db, forceLike: true);
      expect(titles(await s.search(profileId, 'roRA')), ['Aurora season']);
      expect(titles(await s.search(profileId, 'night sky')), ['Aurora season']);
      expect(titles(await s.search(profileId, 'night aurora')),
          ['Aurora season']);
      final hit = (await s.search(profileId, 'comet')).said.single;
      expect(parseSnippet(hit.snippet).where((p) => p.match).single.text,
          'comet');
    });
  });
}
