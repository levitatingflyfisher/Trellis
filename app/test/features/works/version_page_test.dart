import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/works/work_open.dart';

/// A version has no page of its own (1.6.18, owner: "it should live
/// together"): opening one opens its episode, in its language.
void main() {
  late AppDatabase db;
  late int original;
  late int es;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final p = await db.profilesDao.create('Ada');
    final feed = await db.feedsDao
        .insertFeed(profileId: p, url: 'https://cast.test/f', title: 'Show');
    original = await db.spineDao.insertWork(
        profileId: p,
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
    es = await db.spineDao.insertWork(
        profileId: p,
        kind: 'version',
        title: 'Harbour (Spanish)',
        persistence: 'ephemeron',
        firstSeenEpochDay: 1,
        sourceUrl: 'https://spoken.trellis.invalid/$original-es.ogg',
        lang: 'es');
    await db.versionsDao.put(workId: es, originalId: original, lang: 'es');
  });
  tearDown(() => db.close());

  test('a version’s page is its episode’s, in the version’s language',
      () async {
    final entry = await pageEntryFor(
        db, (work: (await db.spineDao.workById(es))!, episode: null));
    expect(entry.work.id, original);
    expect(entry.episode?.workId, original);
    expect(entry.work.readLang, 'es');
  });

  test('any other work’s page is its own', () async {
    final work = (await db.spineDao.workById(original))!;
    final episode = await db.feedsDao.episodeOf(original);
    final entry = await pageEntryFor(db, (work: work, episode: episode));
    expect(entry.work.id, original);
    expect(entry.work.readLang, isNull);
  });
}
