import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/study/daily_review_screen.dart';

/// The study crown, Phase 1: the daily review surface's UI half. The DAO
/// half (two-button mapping, queue composition, malformed-entry skipping)
/// is proven in test/db/daily_review_db_test.dart — this file proves the
/// screen wires those same verbs correctly and shows a real invitation,
/// not a bare "no data", when the queue is empty.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  testWidgets('empty state names what is missing and what to do about it',
      (tester) async {
    final profileId = await db.profilesDao.create('Ada');
    await tester.pumpWidget(MaterialApp(
        home: DailyReviewScreen(db: db, profileId: profileId)));
    await tester.pumpAndSettle();

    expect(find.textContaining('Nothing to review'), findsOneWidget);
  });

  testWidgets('a kept word surfaces with the two-button flow, front = the '
      'word (the degraded front — no passage context exists for a bare '
      'ledger entry)', (tester) async {
    final profileId = await db.profilesDao.create('Ada');
    await db.ledgerDao.add(profileId: profileId, word: 'saudade', nowMs: 1);

    await tester.pumpWidget(MaterialApp(
        home: DailyReviewScreen(db: db, profileId: profileId)));
    await tester.pumpAndSettle();

    expect(find.text('saudade'), findsOneWidget);
    expect(find.byKey(const Key('review-soon')), findsOneWidget);
    expect(find.byKey(const Key('review-eventually')), findsOneWidget);
  });

  testWidgets('tapping Soon maps to again — the item comes right back due '
      'today, so it leaves the CURRENT queue but the DB reflects a lapse',
      (tester) async {
    final profileId = await db.profilesDao.create('Ada');
    final wordId =
        await db.ledgerDao.add(profileId: profileId, word: 'saudade', nowMs: 1);

    await tester.pumpWidget(MaterialApp(
        home: DailyReviewScreen(db: db, profileId: profileId)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('review-soon')));
    await tester.pumpAndSettle();

    final row = await (db.select(db.dailyReviewCards)
          ..where((c) =>
              c.profileId.equals(profileId) &
              c.sourceType.equals('ledger') &
              c.sourceId.equals(wordId)))
        .getSingle();
    expect(row.stateJson, contains('"lapses":1'));
  });

  testWidgets('tapping Eventually maps to good — graduates the item', (tester) async {
    final profileId = await db.profilesDao.create('Ada');
    final wordId =
        await db.ledgerDao.add(profileId: profileId, word: 'saudade', nowMs: 1);

    await tester.pumpWidget(MaterialApp(
        home: DailyReviewScreen(db: db, profileId: profileId)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('review-eventually')));
    await tester.pumpAndSettle();

    final row = await (db.select(db.dailyReviewCards)
          ..where((c) =>
              c.profileId.equals(profileId) &
              c.sourceType.equals('ledger') &
              c.sourceId.equals(wordId)))
        .getSingle();
    expect(row.stateJson, contains('"reps":1'));
    // Graduated: gone from the visible queue immediately (due later, not today).
    expect(find.text('saudade'), findsNothing);
  });

  testWidgets(
      'a capture with a bound sentence shows its passage context, not just '
      'a bare timestamp', (tester) async {
    final profileId = await db.profilesDao.create('Ada');
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Ep',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/1.mp3');
    await db.spineDao.insertSegments(workId, const [
      (idx: 0, kind: 'prose', text: 'Setup line.'),
      (idx: 1, kind: 'prose', text: 'The important bit.'),
    ]);
    await db.spineDao.insertAlignments(workId, const [
      (segmentIdx: 0, tStartMs: 0, tEndMs: 5000),
      (segmentIdx: 1, tStartMs: 5000, tEndMs: 10000),
    ]);
    await db.capturesDao.capture(
        profileId: profileId, workId: workId, positionMs: 6000, nowMs: 1);

    await tester.pumpWidget(MaterialApp(
        home: DailyReviewScreen(db: db, profileId: profileId)));
    await tester.pumpAndSettle();

    expect(find.textContaining('The important bit.'), findsOneWidget);
  });
}
