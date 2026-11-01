import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:trellis/db/database.dart';

/// One episode, every language (owner, 14 Nov 2026: "I changed my mind on
/// the separate episode per language idea; it should live together"). A
/// made language is a version of its episode: a work of kind `version`
/// with a Versions row, and no Episode row, so no show or list holds it
/// apart from its original.
void main() {
  /// The rows of [table] in [db], as plain maps, ordered by rowid.
  List<Map<String, Object?>> rows(raw.Database db, String table) => [
        for (final r in db.select('SELECT * FROM $table ORDER BY rowid'))
          {for (final c in r.keys) c: r[c]}
      ];

  group('the upgrade from 1.6.17 (schema 36)', () {
    // Made by 1.6.17's own code (storeSpokenEpisode, the queue, places,
    // a capture): episode 1 with Spanish (3, kept) and German (4)
    // versions; French (5) made from an episode since deleted.
    late Directory dir;
    late File file;
    late raw.Database before;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('trellis-v37');
      file = File('${dir.path}/db.sqlite');
      File('test/fixtures/trellis-1.6.17.sqlite').copySync(file.path);
      before = raw.sqlite3.open(file.path, mode: raw.OpenMode.readOnly);
    });
    tearDown(() {
      before.dispose();
      dir.deleteSync(recursive: true);
    });

    test('the fixture is a 1.6.17 database', () {
      expect(before.userVersion, 36);
      expect(rows(before, 'episodes').map((e) => e['guid']),
          ['g1', 'spoken:1:es', 'spoken:1:de', 'spoken:2:fr']);
    });

    test('made episodes become versions; nothing else is lost or moved',
        () async {
      final keep = {
        for (final t in [
          'queue',
          'positions',
          'player_positions',
          'captures',
          'alignments',
          'segments',
          'work_notes',
          'profiles',
          'feeds',
        ])
          t: rows(before, t),
      };
      final worksBefore = {
        for (final w in rows(before, 'works')) w['id']: w,
      };

      final db = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(db.close);

      final v3 = (await db.versionsDao.versionOf(3))!;
      expect((v3.originalId, v3.lang, v3.voiceKind, v3.clearness),
          (1, 'es', 'machine', 'natural'));
      final v4 = (await db.versionsDao.versionOf(4))!;
      expect((v4.originalId, v4.lang), (1, 'de'));
      expect([for (final v in await db.versionsDao.versionsOf(1)) v.lang],
          unorderedEquals(['es', 'de']));

      final after = raw.sqlite3.open(file.path, mode: raw.OpenMode.readOnly);
      addTearDown(after.dispose);
      expect(after.userVersion, greaterThanOrEqualTo(37));
      for (final MapEntry(key: t, value: was) in keep.entries) {
        expect(rows(after, t), was, reason: '$t is untouched');
      }
      final works = {for (final w in rows(after, 'works')) w['id']: w};
      expect(works.keys, worksBefore.keys, reason: 'no work is lost');
      for (final id in works.keys) {
        final kind = works[id]!['kind'];
        expect(kind, switch (id) { 3 || 4 => 'version', _ => 'episode' },
            reason: 'work $id');
        // Everything but the kind is as it was: the audio's address (and
        // so its file on the phone), the title, the language. Episode 1
        // alone is now kept: its Spanish was, and lives with it.
        expect({...works[id]!}..remove('kind')..remove('persistence'),
            {...worksBefore[id]!}..remove('kind')..remove('persistence'),
            reason: 'work $id');
      }
      expect(worksBefore[1]!['persistence'], 'ephemeron');
      expect(works[1]!['persistence'], 'work',
          reason: 'a kept made episode keeps its episode in the Library');
      for (final id in [3, 4, 5]) {
        expect(works[id]!['persistence'], worksBefore[id]!['persistence']);
      }
      final library = await db.libraryDao.libraryQueryEntriesOf(1);
      expect([for (final e in library) e.work.id], [1],
          reason: 'the Library shows the episode once, never the version');
      expect(rows(after, 'episodes').map((e) => e['guid']), ['g1', 'spoken:2:fr'],
          reason: 'a version has no episode row; a made one whose original '
              'is gone stays an episode and still plays');
    });
  });

  test('a made episode whose guid names itself stays an episode', () async {
    final dir = Directory.systemTemp.createTempSync('trellis-v37-self');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/db.sqlite');
    File('test/fixtures/trellis-1.6.17.sqlite').copySync(file.path);
    final raw36 = raw.sqlite3.open(file.path);
    raw36.execute("UPDATE episodes SET guid = 'spoken:1:it' WHERE work_id = 1");
    raw36.dispose();
    final db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    expect(await db.versionsDao.versionOf(1), isNull);
    expect((await db.spineDao.workById(1))!.kind, 'episode');
    expect(await db.feedsDao.episodeOf(1), isNotNull);
  });

  group('versions', () {
    late AppDatabase db;
    late int profileId;
    late int original;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      profileId = await db.profilesDao.create('Ada');
      final feed = await db.feedsDao.insertFeed(
          profileId: profileId, url: 'https://cast.test/f', title: 'Show');
      original = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: 'Harbour',
          persistence: 'ephemeron',
          firstSeenEpochDay: 1,
          sourceUrl: 'https://cast.test/1.mp3');
      await db.feedsDao.insertEpisode(
          workId: original,
          feedId: feed,
          guid: 'g1',
          enclosureUrl: 'https://cast.test/1.mp3',
          publishedAtMs: 1);
    });
    tearDown(() => db.close());

    Future<int> version(String lang) async {
      final id = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'version',
          title: 'Harbour',
          persistence: 'ephemeron',
          firstSeenEpochDay: 1,
          sourceUrl: 'https://spoken.trellis.invalid/$original-$lang.ogg',
          lang: lang);
      await db.versionsDao.put(
          workId: id, originalId: original, lang: lang, voice: 'Kokoro');
      return id;
    }

    test('one per language; the same language again is the same row',
        () async {
      final es = await version('es');
      expect((await db.versionsDao.versionIn(original, 'es'))?.workId, es);
      expect(await db.versionsDao.versionIn(original, 'de'), isNull);
      await db.versionsDao.put(
          workId: es, originalId: original, lang: 'es', voice: 'Pocket TTS');
      expect((await db.versionsDao.versionsOf(original)).single.voice,
          'Pocket TTS');
    });

    test('every version in a language, by original, for a whole list',
        () async {
      final es = await version('es');
      expect(await db.versionsDao.versionsIn('es'), {original: es});
      expect(await db.versionsDao.versionsIn('fr'), isEmpty);
    });

    test('deleting an episode deletes its versions with it', () async {
      final es = await version('es');
      await db.queueDao.playLast(profileId: profileId, workId: es, nowMs: 1);
      await db.spineDao.deleteWork(original);
      expect(await db.spineDao.workById(es), isNull);
      expect(await db.versionsDao.versionsOf(original), isEmpty);
      expect(await db.queueDao.queueOf(profileId), isEmpty);
    });

    test('a version never shows among a show’s episodes', () async {
      await version('es');
      expect(
          [for (final e in await db.select(db.episodes).get()) e.workId],
          [original]);
    });
  });
}
