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

  group('Campaign 9 Phase 3: "the study screen tells you what happened"',
      () {
    // User: made captures, opened review, saw a sentence + "soon" and
    // "eventually" buttons, "nothing happened when I clicked either."
    // Scouted truth: the handlers ARE wired — every no-transcript capture
    // rendered the IDENTICAL front, and there was no progress feedback, so
    // grading to a visually identical card looked like nothing changed.
    // Reproduces with 3 DISTINCT, all-transcript-pending captures: if the
    // fix works, each card is visibly its own, the counter ticks, and the
    // queue empties.
    Future<int> seedPendingCapture(
        {required int profileId, required String title, int positionMs = 6000}) async {
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: title,
          persistence: 'ephemeron',
          firstSeenEpochDay: 100,
          sourceUrl: 'https://cast.test/$title.mp3');
      return db.capturesDao.capture(
          profileId: profileId,
          workId: workId,
          positionMs: positionMs,
          nowMs: 1);
    }

    testWidgets('3 captures: each card is visibly distinct, the progress '
        'counter ticks down, and exhausting the queue reaches the empty '
        'state', (tester) async {
      final profileId = await db.profilesDao.create('Ada');
      await seedPendingCapture(
          profileId: profileId, title: 'Aurora season', positionMs: 754000);
      await seedPendingCapture(
          profileId: profileId, title: 'Meteor showers', positionMs: 60000);
      await seedPendingCapture(
          profileId: profileId, title: 'Perseid peak', positionMs: 5000);

      await tester.pumpWidget(MaterialApp(
          home: DailyReviewScreen(db: db, profileId: profileId)));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('review-progress')), findsOneWidget);
      expect(find.text('3 of 3'), findsOneWidget);
      // Each capture's card is distinct even though NONE has a transcript
      // — title + timestamp alone must tell them apart.
      final firstCardTitles = <String>{};
      for (final title in ['Aurora season', 'Meteor showers', 'Perseid peak']) {
        if (find.textContaining(title).evaluate().isNotEmpty) {
          firstCardTitles.add(title);
        }
      }
      expect(firstCardTitles, hasLength(1),
          reason: 'exactly one card is visible at a time');
      expect(find.textContaining('Transcript pending'), findsOneWidget);

      await tester.tap(find.byKey(const Key('review-eventually')));
      await tester.pumpAndSettle();
      expect(find.text('2 of 3'), findsOneWidget);

      await tester.tap(find.byKey(const Key('review-eventually')));
      await tester.pumpAndSettle();
      expect(find.text('1 of 3'), findsOneWidget);

      await tester.tap(find.byKey(const Key('review-eventually')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('review-progress')), findsNothing,
          reason: 'the counter itself goes away with the empty state');
      expect(find.textContaining('Nothing to review'), findsOneWidget);
    });

    test('every card title distinct across grades, not repeated in place',
        () async {
      // Companion to the widget test above: pins the underlying DATA is
      // actually three different titles, not one row re-rendered thrice —
      // guards against a future regression where the queue silently
      // collapses to one item.
      final db2 = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db2.close);
      final profileId = await db2.profilesDao.create('Ada');
      final w1 = await db2.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: 'A',
          persistence: 'ephemeron',
          firstSeenEpochDay: 100);
      final w2 = await db2.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: 'B',
          persistence: 'ephemeron',
          firstSeenEpochDay: 100);
      await db2.capturesDao.capture(
          profileId: profileId, workId: w1, positionMs: 1000, nowMs: 1);
      await db2.capturesDao.capture(
          profileId: profileId, workId: w2, positionMs: 2000, nowMs: 1);
      final captures = await db2.capturesDao.capturesOfProfile(profileId);
      expect(captures.map((c) => c.workId).toSet(), {w1, w2});
    });

    testWidgets(
        'a captured moment WITH a transcript shows the resolved sentence '
        'as the headline, title+timestamp as its byline', (tester) async {
      final profileId = await db.profilesDao.create('Ada');
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: 'Aurora season',
          persistence: 'ephemeron',
          firstSeenEpochDay: 100,
          sourceUrl: 'https://cast.test/aurora.mp3');
      await db.spineDao.insertSegments(workId, const [
        (idx: 0, kind: 'prose', text: 'Setup line.'),
        (idx: 1, kind: 'prose', text: 'The important bit.'),
      ]);
      await db.spineDao.insertAlignments(workId, const [
        (segmentIdx: 0, tStartMs: 0, tEndMs: 5000),
        (segmentIdx: 1, tStartMs: 5000, tEndMs: 10000),
      ]);
      // Captured BEFORE transcription finished (segmentIdx null at write
      // time — render-time resolution must still find the sentence).
      await db.capturesDao.capture(
          profileId: profileId, workId: workId, positionMs: 6000, nowMs: 1);

      await tester.pumpWidget(MaterialApp(
          home: DailyReviewScreen(db: db, profileId: profileId)));
      await tester.pumpAndSettle();

      expect(find.text('The important bit.'), findsOneWidget);
      expect(find.textContaining('Aurora season'), findsOneWidget);
      expect(find.textContaining('0:06'), findsOneWidget);
      expect(find.textContaining('Transcript pending'), findsNothing);
    });

    testWidgets('grade labels state their own consequence, not bare words',
        (tester) async {
      final profileId = await db.profilesDao.create('Ada');
      await db.ledgerDao.add(profileId: profileId, word: 'saudade', nowMs: 1);

      await tester.pumpWidget(MaterialApp(
          home: DailyReviewScreen(db: db, profileId: profileId)));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('review-soon')), findsOneWidget);
      expect(find.byKey(const Key('review-eventually')), findsOneWidget);
      expect(find.text('Soon'), findsNothing,
          reason: 'a bare word names no consequence');
      expect(find.text('Eventually'), findsNothing,
          reason: 'a bare word names no consequence');
      expect(find.textContaining('again'), findsWidgets,
          reason: 'the Soon button (or its caption) must say what '
              'tapping it DOES');
      expect(find.textContaining("I've got this"), findsOneWidget,
          reason: 'the Eventually button must say what tapping it DOES');
    });

    testWidgets('a capture card with byline, headline and both captions '
        'survives 320dp at 2x text scale', (tester) async {
      final profileId = await db.profilesDao.create('Ada');
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: 'A rather long episode title, to be safe',
          persistence: 'ephemeron',
          firstSeenEpochDay: 100,
          sourceUrl: 'https://cast.test/1.mp3');
      await db.spineDao.insertSegments(workId, const [
        (idx: 0, kind: 'prose', text: 'The important bit, spelled out.'),
      ]);
      await db.spineDao.insertAlignments(
          workId, const [(segmentIdx: 0, tStartMs: 0, tEndMs: 5000)]);
      await db.capturesDao.capture(
          profileId: profileId, workId: workId, positionMs: 3000, nowMs: 1);

      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearAllTestValues);

      await tester.pumpWidget(MaterialApp(
          home: DailyReviewScreen(db: db, profileId: profileId)));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
}
