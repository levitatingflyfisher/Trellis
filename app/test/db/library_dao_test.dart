import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
