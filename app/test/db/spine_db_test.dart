import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';

/// The spine's storage contract (ADR-0002): positions are one tiny row,
/// layers are per-segment, ephemera carry their sovereignty bit.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('a position save is a single-row upsert, not a work rewrite', () async {
    final profileId = await db.profilesDao.create('Ada');
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Ep 1',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100);

    await db.spineDao.savePosition(
        profileId: profileId, workId: workId, segmentIdx: 4, wordIdx: 2, lastModality: 'listen');
    await db.spineDao.savePosition(
        profileId: profileId, workId: workId, segmentIdx: 7, wordIdx: 0, lastModality: 'read');

    final pos = await db.spineDao.position(profileId: profileId, workId: workId);
    expect(pos!.segmentIdx, 7);
    expect(pos.wordIdx, 0);
    final all = await db.spineDao.allPositions();
    expect(all.length, 1, reason: 'upsert, never a second row per work');
  });

  test('segments and per-language layers round-trip in order', () async {
    final profileId = await db.profilesDao.create('Ada');
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Ep 1',
        persistence: 'work',
        firstSeenEpochDay: 100);
    await db.spineDao.insertSegments(workId, const [
      (idx: 0, kind: 'prose', text: 'Hola.'),
      (idx: 1, kind: 'prose', text: 'Adiós.'),
    ]);
    await db.spineDao.insertLayers(workId, const [
      (segmentIdx: 0, lang: 'en', kind: 'mt', text: 'Hello.'),
    ]);

    final segs = await db.spineDao.segmentsOf(workId);
    expect(segs.map((s) => s.body), ['Hola.', 'Adiós.']);
    final layers = await db.spineDao.layersOf(workId, lang: 'en');
    expect(layers.single.body, 'Hello.');
  });

  test('deleting a work cascades its segments, layers, and positions', () async {
    final profileId = await db.profilesDao.create('Ada');
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'article',
        title: 'A',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100);
    await db.spineDao.insertSegments(workId, const [(idx: 0, kind: 'prose', text: 'x')]);
    await db.spineDao.savePosition(
        profileId: profileId, workId: workId, segmentIdx: 0, wordIdx: 0, lastModality: 'read');

    await db.spineDao.deleteWork(workId);
    expect(await db.spineDao.segmentsOf(workId), isEmpty);
    expect(await db.spineDao.allPositions(), isEmpty);
  });

  test('the ephemera sweep deletes exactly the pure verdict, promoted works survive', () async {
    final profileId = await db.profilesDao.create('Ada');
    await db.spineDao.insertWork(
        profileId: profileId, kind: 'episode', title: 'old',
        persistence: 'ephemeron', firstSeenEpochDay: 100);
    final kept = await db.spineDao.insertWork(
        profileId: profileId, kind: 'episode', title: 'kept',
        persistence: 'ephemeron', firstSeenEpochDay: 100);
    await db.spineDao.promoteWork(kept);

    final swept = await db.spineDao.sweepEphemera(todayEpochDay: 131);
    expect(swept, 1);
    final titles = (await db.spineDao.worksOf(profileId)).map((w) => w.title);
    expect(titles, ['kept']);
  });
}
