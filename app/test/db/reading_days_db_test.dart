import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';

/// Campaign 4 Phase 5's write side (ADR-0003 law 5: additive totals only,
/// never a streak): one row per profile per UTC epoch day the cursor
/// actually advanced. [Positions] cannot answer "how many distinct days
/// have you read" — it is one overwritten row per (profile, work), so a
/// work reopened daily for a month still shows a single `updatedAtMs`.
/// This DAO method is the append-only record that makes that count
/// honestly computable later; deliberately landed ahead of Phase 5's own
/// UI so the totals screen reads a table that already has real rows in
/// it rather than an empty one on day one.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<List<ReadingDay>> rowsFor(int profileId) =>
      (db.select(db.readingDays)..where((t) => t.profileId.equals(profileId)))
          .get();

  test('recording the same UTC day twice collapses to one row', () async {
    final profileId = await db.profilesDao.create('Ada');

    await db.profilesDao.recordReadingDay(profileId, 100);
    await db.profilesDao.recordReadingDay(profileId, 100);

    final rows = await rowsFor(profileId);
    expect(rows, hasLength(1),
        reason: 'the composite (profileId, epochDay) key makes a replay a '
            'no-op, not a duplicate');
    expect(rows.single.epochDay, 100);
  });

  test('recording two different UTC days keeps both rows', () async {
    final profileId = await db.profilesDao.create('Ada');

    await db.profilesDao.recordReadingDay(profileId, 100);
    await db.profilesDao.recordReadingDay(profileId, 101);

    final rows = await rowsFor(profileId);
    expect(rows.map((r) => r.epochDay).toSet(), {100, 101});
  });

  test('reading days are scoped per profile, never shared', () async {
    final ada = await db.profilesDao.create('Ada');
    final bea = await db.profilesDao.create('Bea');

    await db.profilesDao.recordReadingDay(ada, 100);
    await db.profilesDao.recordReadingDay(bea, 100);

    expect(await rowsFor(ada), hasLength(1));
    expect(await rowsFor(bea), hasLength(1));
  });
}
