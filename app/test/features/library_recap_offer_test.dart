import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/intake/paste_intake.dart' show epochDayUtcNow;
import 'package:trellis/main.dart';

/// Campaign 4 Phase 4: LibraryScreen._open resolves `offerRecap` BEFORE
/// pushing the reader — same "resolved before the push" shape ADR-0006's
/// offerNeuralVoice already uses, so ReaderScreen's own tests never touch
/// this computation directly. shouldOfferRecap's own trigger rules are
/// tested pure in reader_logic_test.dart; this file only proves the
/// library wires real Position/segmentCount data into it correctly.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<int> seedWork(String title,
      {required int segmentIdx, required int updatedAtMs}) async {
    final profileId = (await db.profilesDao.all()).isEmpty
        ? await db.profilesDao.create('Ada')
        : (await db.profilesDao.all()).first.id;
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'note',
        title: title,
        persistence: 'work',
        firstSeenEpochDay: 100,
        lang: 'en');
    await db.spineDao.insertSegments(workId, [
      for (var i = 0; i < 10; i++)
        (idx: i, kind: 'prose', text: 'Paragraph $i has a few words in it.')
    ]);
    await db.into(db.positions).insertOnConflictUpdate(PositionsCompanion.insert(
        profileId: profileId,
        workId: workId,
        segmentIdx: segmentIdx,
        wordIdx: 0,
        lastModality: 'read',
        updatedAtMs: updatedAtMs));
    return workId;
  }

  int daysAgoMs(int days) =>
      (epochDayUtcNow() - days) * Duration.millisecondsPerDay;

  testWidgets('a work untouched for 5 days with real progress offers the '
      'recap chip', (tester) async {
    await db.profilesDao.create('Ada');
    await seedWork('Stale', segmentIdx: 5, updatedAtMs: daysAgoMs(5));

    await tester.pumpWidget(TrellisApp(db: db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stale'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('recap-offer-chip')), findsOneWidget);
  });

  testWidgets('a work touched today offers nothing, even with progress',
      (tester) async {
    await db.profilesDao.create('Ada');
    await seedWork('Fresh',
        segmentIdx: 5, updatedAtMs: DateTime.now().millisecondsSinceEpoch);

    await tester.pumpWidget(TrellisApp(db: db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fresh'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('recap-offer-chip')), findsNothing);
  });

  testWidgets('a work untouched for 5 days but barely started offers '
      'nothing', (tester) async {
    await db.profilesDao.create('Ada');
    await seedWork('BarelyStarted', segmentIdx: 0, updatedAtMs: daysAgoMs(5));

    await tester.pumpWidget(TrellisApp(db: db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('BarelyStarted'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('recap-offer-chip')), findsNothing);
  });
}
