import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:trellis/db/database.dart';

/// The small DAO surface the library screen leans on beyond the spine
/// contract already pinned in spine_db_test.dart.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('profiles list round-trips in creation order', () async {
    await db.profilesDao.create('Ada');
    await db.profilesDao.create('Blaise');
    final all = await db.profilesDao.all();
    expect(all.map((p) => p.name), ['Ada', 'Blaise']);
  });

  test('setPinned flips the pin bit both ways', () async {
    final profileId = await db.profilesDao.create('Ada');
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'note',
        title: 'T',
        persistence: 'work',
        firstSeenEpochDay: 100);

    await db.spineDao.setPinned(workId, true);
    var w = (await db.spineDao.worksOf(profileId)).single;
    expect(w.pinned, isTrue);

    await db.spineDao.setPinned(workId, false);
    w = (await db.spineDao.worksOf(profileId)).single;
    expect(w.pinned, isFalse);
  });

  test('segmentCount counts one work without loading bodies of another',
      () async {
    final profileId = await db.profilesDao.create('Ada');
    final a = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'note',
        title: 'A',
        persistence: 'work',
        firstSeenEpochDay: 100);
    final b = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'note',
        title: 'B',
        persistence: 'work',
        firstSeenEpochDay: 100);
    await db.spineDao.insertSegments(a, const [
      (idx: 0, kind: 'prose', text: 'x'),
      (idx: 1, kind: 'prose', text: 'y'),
    ]);
    await db.spineDao.insertSegments(b, const [
      (idx: 0, kind: 'prose', text: 'z'),
    ]);

    expect(await db.spineDao.segmentCount(a), 2);
    expect(await db.spineDao.segmentCount(b), 1);
    expect(await db.spineDao.segmentCount(9999), 0);
  });

  group('libraryQueryEntriesOf — left-joins episode + feed onto every '
      'work, since only episode works have either', () {
    test('an episode work carries its episode and feed title', () async {
      final profileId = await db.profilesDao.create('Ada');
      final feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://a/f');
      await db.feedsDao.updateRefreshState(feedId,
          title: 'The Cast', etag: null, lastModified: null, breakerJson: '{}');
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: 'An episode',
          persistence: 'work',
          firstSeenEpochDay: 100);
      await db.feedsDao.insertEpisode(
          workId: workId,
          feedId: feedId,
          guid: 'g',
          enclosureUrl: 'https://a/1.mp3',
          publishedAtMs: 1000);

      final entries = await db.libraryDao.libraryQueryEntriesOf(profileId);
      final entry = entries.singleWhere((e) => e.work.id == workId);
      expect(entry.episode, isNotNull);
      expect(entry.feedTitle, 'The Cast');
    });

    test('a non-episode work carries neither, never throws', () async {
      final profileId = await db.profilesDao.create('Ada');
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'book',
          title: 'A book',
          persistence: 'work',
          firstSeenEpochDay: 100);

      final entries = await db.libraryDao.libraryQueryEntriesOf(profileId);
      final entry = entries.singleWhere((e) => e.work.id == workId);
      expect(entry.episode, isNull);
      expect(entry.feedTitle, isNull);
    });

    test('scoped to the given profile only', () async {
      final ada = await db.profilesDao.create('Ada');
      final bea = await db.profilesDao.create('Bea');
      await db.spineDao.insertWork(
          profileId: bea,
          kind: 'book',
          title: "Bea's book",
          persistence: 'work',
          firstSeenEpochDay: 100);

      final entries = await db.libraryDao.libraryQueryEntriesOf(ada);
      expect(entries, isEmpty);
    });
  });

  group('saved views — CRUD, ordered, deletable (Campaign 5 Phase 2)', () {
    test('creates in append order, position contiguous from 0', () async {
      final profileId = await db.profilesDao.create('Ada');
      await db.libraryDao.createSavedView(
          profileId: profileId, name: 'Unread podcasts', queryJson: '{}',
          nowMs: 1);
      await db.libraryDao.createSavedView(
          profileId: profileId, name: 'Pinned', queryJson: '{}', nowMs: 2);

      final views = await db.libraryDao.savedViewsOf(profileId);
      expect(views.map((v) => v.name), ['Unread podcasts', 'Pinned']);
      expect(views.map((v) => v.position), [0, 1]);
    });

    test('scoped to the given profile only', () async {
      final ada = await db.profilesDao.create('Ada');
      final bea = await db.profilesDao.create('Bea');
      await db.libraryDao.createSavedView(
          profileId: bea, name: "Bea's view", queryJson: '{}', nowMs: 1);

      expect(await db.libraryDao.savedViewsOf(ada), isEmpty);
    });

    test('deleting one renumbers the rest contiguously', () async {
      final profileId = await db.profilesDao.create('Ada');
      await db.libraryDao.createSavedView(
          profileId: profileId, name: 'A', queryJson: '{}', nowMs: 1);
      final b = await db.libraryDao.createSavedView(
          profileId: profileId, name: 'B', queryJson: '{}', nowMs: 2);
      await db.libraryDao.createSavedView(
          profileId: profileId, name: 'C', queryJson: '{}', nowMs: 3);

      await db.libraryDao.deleteSavedView(b);

      final views = await db.libraryDao.savedViewsOf(profileId);
      expect(views.map((v) => v.name), ['A', 'C']);
      expect(views.map((v) => v.position), [0, 1]);
    });

    test('reorder moves a view to a new position and renumbers around it',
        () async {
      final profileId = await db.profilesDao.create('Ada');
      final a = await db.libraryDao.createSavedView(
          profileId: profileId, name: 'A', queryJson: '{}', nowMs: 1);
      await db.libraryDao.createSavedView(
          profileId: profileId, name: 'B', queryJson: '{}', nowMs: 2);
      await db.libraryDao.createSavedView(
          profileId: profileId, name: 'C', queryJson: '{}', nowMs: 3);

      await db.libraryDao
          .reorderSavedView(profileId: profileId, viewId: a, newPosition: 2);

      final views = await db.libraryDao.savedViewsOf(profileId);
      expect(views.map((v) => v.name), ['B', 'C', 'A']);
    });
  });

  group('schema migration v12 → v15', () {
    test('a v12 database gains saved_views and keeps its data', () async {
      final dir = Directory.systemTemp.createTempSync('trellis-migration-v15');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/v12.sqlite');

      // Build a real v12 file from drift's own DDL: create at the current
      // version, stamp user_version 12. `createTable` migrations are
      // idempotent (CREATE TABLE IF NOT EXISTS — see study_db_test.dart's
      // v2→v3 note), so `saved_views` needs no DROP TABLE the way an
      // addColumn would need a DROP COLUMN. Phase 3's rules/dedup columns
      // land on `feeds`/`episodes`, which have existed since v2 — those
      // DO need dropping, or a v12 database would already carry them.
      final seed = AppDatabase.forTesting(NativeDatabase(file));
      final profileId = await seed.profilesDao.create('Ada');
      await seed.close();
      final v12 = raw.sqlite3.open(file.path);
      v12.execute('''
        DROP TABLE saved_views;
        DROP TABLE translation_sentences;
        ALTER TABLE feeds DROP COLUMN rules_json;
        ALTER TABLE episodes DROP COLUMN dedup_reason;
        ALTER TABLE episodes DROP COLUMN duplicate_of_work_id;
        ALTER TABLE works DROP COLUMN show_translation_layer;
        ALTER TABLE feeds DROP COLUMN dsp_enabled;
        ALTER TABLE episodes DROP COLUMN dsp_original_duration_ms;
        ALTER TABLE episodes DROP COLUMN dsp_processed_duration_ms;
        ALTER TABLE profiles DROP COLUMN dsp_global_default;
        DROP TABLE audiobook_files;
        DROP TABLE audiobooks;
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
      final profiles = await migrated.profilesDao.all();
      expect(profiles.single.name, 'Ada');
      // …and saved views work.
      await migrated.libraryDao.createSavedView(
          profileId: profileId, name: 'Unread', queryJson: '{}', nowMs: 1);
      final views = await migrated.libraryDao.savedViewsOf(profileId);
      expect(views.single.name, 'Unread');
    });
  });
}
