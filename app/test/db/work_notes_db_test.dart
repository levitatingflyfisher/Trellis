import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:trellis/db/database.dart';
import 'package:trellis/db/search_index.dart';
import 'package:trellis/features/search/search_store.dart';

import '../support/schema_strip.dart';

class _Recorder extends QueryInterceptor {
  final selects = <String>[];

  @override
  Future<List<Map<String, Object?>>> runSelect(
      QueryExecutor executor, String statement, List<Object?> args) {
    selects.add(statement);
    return executor.runSelect(statement, args);
  }
}

/// Full show notes (1.5.4): a side table, so Latest's 20k-row page query
/// never carries them.
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

  Future<int> episode(String guid, {String? enclosure = 'https://a/x.mp3'}) async {
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: enclosure == null ? 'article' : 'episode',
        title: guid,
        persistence: 'ephemeron',
        firstSeenEpochDay: 100);
    await db.feedsDao.insertEpisode(
        workId: id,
        feedId: feedId,
        guid: guid,
        enclosureUrl: enclosure,
        publishedAtMs: id);
    return id;
  }

  test('notes are stored once and a later write never replaces them',
      () async {
    final id = await episode('g1');
    expect(await db.feedsDao.notesOf(id), isNull);
    await db.feedsDao.fillNotes(id, html: '<p>First</p>', plain: 'First');
    await db.feedsDao.fillNotes(id, html: '<p>Second</p>', plain: 'Second');
    final notes = await db.feedsDao.notesOf(id);
    expect(notes!.html, '<p>First</p>');
    expect(notes.plain, 'First');
  });

  test('notesGapsOf names the audio items still without notes', () async {
    final a = await episode('a');
    await episode('b');
    await episode('t', enclosure: null);
    await db.feedsDao.fillNotes(a, html: '<p>x</p>', plain: 'x');
    expect(await db.feedsDao.notesGapsOf(feedId), {'b'});
  });

  test('deleting a work takes its notes with it', () async {
    final id = await episode('g1');
    await db.feedsDao.fillNotes(id, html: '<p>x</p>', plain: 'x');
    await db.spineDao.deleteWorks([id]);
    expect(await db.feedsDao.notesOf(id), isNull);
  });

  test("Latest's page query never reads the notes", () async {
    final id = await episode('g1');
    await db.feedsDao.fillNotes(id, html: '<p>x</p>', plain: 'x');
    rec.selects.clear();
    final page = await db.feedsDao.riverItems(profileId);
    expect(page, hasLength(1));
    expect(rec.selects, isNotEmpty);
    for (final sql in rec.selects) {
      expect(sql, isNot(contains('work_notes')), reason: sql);
    }
    // And the row type it returns has nowhere to put them.
    expect(db.episodes.$columns.map((c) => c.name),
        isNot(anyOf(contains('html'), contains('notes'))));
    expect(db.workNotes.actualTableName, 'work_notes');
  });

  group('schema migration v28 -> v29', () {
    test('adds the notes table and the per-work language, keeps every row '
        'and validator, marks each podcast for a paced notes fill, and '
        'rebuilds the index to stem', () async {
      final dir = Directory.systemTemp.createTempSync('trellis-migration-v29');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/v28.sqlite');

      final seed = AppDatabase.forTesting(NativeDatabase(file));
      final p = await seed.profilesDao.create('Ada');
      final f = await seed.feedsDao.insertFeed(profileId: p, url: 'f');
      await seed.feedsDao.updateRefreshState(f,
          title: 'Show',
          etag: '"v1"',
          lastModified: 'Wed, 05 Aug 2026 12:00:00 GMT',
          breakerJson: '{}');
      await seed.feedsDao.setBodyHash(f, 'abc');
      final w = await seed.spineDao.insertWork(
          profileId: p,
          kind: 'episode',
          title: 'Time machine',
          persistence: 'ephemeron',
          firstSeenEpochDay: 100);
      await seed.spineDao.insertSegments(w,
          const [(idx: 0, kind: 'prose', text: 'A talk about lighthouses.')]);
      await seed.feedsDao.insertEpisode(
          workId: w,
          feedId: f,
          guid: 'g',
          enclosureUrl: 'https://a/x.mp3',
          publishedAtMs: 1);
      // A blog: no audio, so no notes to fill.
      final blog = await seed.feedsDao.insertFeed(
          profileId: p, url: 'b', title: 'Weeknotes');
      final post = await seed.spineDao.insertWork(
          profileId: p,
          kind: 'article',
          title: 'Post',
          persistence: 'ephemeron',
          firstSeenEpochDay: 100);
      await seed.feedsDao.insertEpisode(
          workId: post, feedId: blog, guid: 'p', publishedAtMs: 1);
      await seed.close();
      final v28 = raw.sqlite3.open(file.path);
      v28.execute('''
        $stripV29
        PRAGMA user_version = 28;
      ''');
      // The fixture really is v28's: an unchanged title reindexes there,
      // and the index doesn't stem.
      int total() =>
          v28.select('SELECT total_changes() AS n').single['n'] as int;
      final was = total();
      v28.execute('UPDATE feeds SET title = title');
      expect(total() - was, greaterThan(2));
      String indexSql(raw.Database d) => d
          .select("SELECT sql FROM sqlite_master WHERE name = 'items_fts'")
          .single['sql'] as String;
      expect(indexSql(v28), isNot(contains('porter')));
      v28.dispose();

      final migrated = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(migrated.close);
      final feed = (await migrated.feedsDao.feedById(f))!;
      // Validators stay: forgetting them would refetch every show at once.
      expect(feed.etag, '"v1"');
      expect(feed.lastModified, 'Wed, 05 Aug 2026 12:00:00 GMT');
      expect(feed.bodyHash, 'abc');
      expect(feed.notesFillPending, isTrue);
      expect((await migrated.feedsDao.feedById(blog))!.notesFillPending,
          isNull);
      expect(feed.title, 'Show');
      expect(feed.subscribedUrl, isNull);
      final work = (await migrated.spineDao.workById(w))!;
      expect(work.readLang, isNull);
      expect(work.lastMode, isNull);
      expect(work.lastModeAtMs, isNull);
      final s = SearchStore(migrated);
      // The hop left the index empty, for after the first frame.
      expect(await s.usesIndex, isFalse);
      await SearchBackfill(migrated).run(pause: Duration.zero);
      expect(await s.usesIndex, isTrue);
      await migrated.customSelect('SELECT 1').get();
      final after = raw.sqlite3.open(file.path);
      expect(indexSql(after), contains('porter'));
      after.dispose();
      // Before the notes fill: the title stems, and the short description
      // every stored episode already has is searched in the notes' place.
      List<int> ids(SearchResults r) => [for (final i in r.items) i.work.id];
      expect(ids(await s.search(p, 'machines')), [w]);
      expect(ids(await s.search(p, 'lighthouse')), [w]);
      expect((await s.search(p, 'show')).shows.single.id, f);
      expect(await migrated.feedsDao.notesGapsOf(f), {'g'});
      await migrated.feedsDao.fillNotes(w, html: '<p>n</p>', plain: 'nebula');
      expect((await migrated.feedsDao.notesOf(w))!.html, '<p>n</p>');
      await migrated.feedsDao
          .fillNotes(w, html: '<p>x</p>', plain: 'ignored');
      expect(ids(await s.search(p, 'nebulae')), [w]);
      expect(ids(await s.search(p, 'ignored')), isEmpty);
      // The rebuild replaced v28's unguarded show trigger: an unchanged
      // title no longer reindexes the feed's episodes.
      Future<int> changes() async => (await migrated
              .customSelect('SELECT total_changes() AS n')
              .getSingle())
          .read<int>('n');
      final before = await changes();
      await migrated.customStatement('UPDATE feeds SET title = title');
      expect(await changes() - before, 2, reason: 'the two feed rows only');
      // And a rename still reindexes, its episodes and the show itself.
      await migrated.feedsDao.updateRefreshState(f,
          title: 'Renamed', etag: null, lastModified: null, breakerJson: '{}');
      expect(ids(await s.search(p, 'renamed')), [w]);
      expect((await s.search(p, 'renamed')).shows.single.id, f);
    });

    test('a hop that fails partway leaves the file as it was, so the next '
        'open runs it again whole', () async {
      final dir = Directory.systemTemp.createTempSync('trellis-v29-atomic');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/v28.sqlite');
      final seed = AppDatabase.forTesting(NativeDatabase(file));
      final p = await seed.profilesDao.create('Ada');
      await seed.spineDao.insertWork(
          profileId: p,
          kind: 'book',
          title: 'Kept',
          persistence: 'work',
          firstSeenEpochDay: 1);
      await seed.close();
      final v28 = raw.sqlite3.open(file.path);
      // A stray column the hop adds late: it fails after `works` has
      // gained its new columns, as a kill mid-hop would leave it.
      v28.execute('''
        $stripV29
        ALTER TABLE feeds ADD COLUMN notes_fill_pending INTEGER;
        PRAGMA user_version = 28;
      ''');
      v28.dispose();

      final first = AppDatabase.forTesting(NativeDatabase(file));
      await expectLater(first.customSelect('SELECT 1').get(), throwsA(anything));
      await first.close();
      final fix = raw.sqlite3.open(file.path);
      expect(fix.select('PRAGMA user_version').single.values.single, 28);
      expect(
          fix
              .select("SELECT name FROM pragma_table_info('works') "
                  "WHERE name = 'read_lang'")
              .isEmpty,
          isTrue,
          reason: 'the columns the failed hop added were rolled back');
      fix.execute('ALTER TABLE feeds DROP COLUMN notes_fill_pending');
      fix.dispose();

      final second = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(second.close);
      expect((await second.spineDao.worksOf(p)).single.title, 'Kept');
    });
  });
}
