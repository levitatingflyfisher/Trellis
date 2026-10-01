import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_core/study_core.dart' as study;
import 'package:trellis/db/database.dart';
import 'package:trellis/features/intake/paste_intake.dart' show epochDayUtcNow;
import 'package:trellis/features/study/study_session_screen.dart';

/// The session grades through the profile's scheduler: Classic through
/// scheduleSm2, FSRS through scheduleFsrs. A switch in either direction
/// seeds the new scheduler from the card's newer half at its first grade,
/// so progress carries over both ways.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  String singleClozeCourse() => json.encode({
        'schemaVersion': '1.0',
        'id': 'one',
        'title': 'One Card',
        'nodes': [
          {
            'id': 'n1',
            'title': 'Only Node',
            'intake': 'Water is wet.',
            'items': [
              {
                'id': 'i-a',
                'type': 'cloze',
                'rung': 1,
                'text': 'Water is {{c1::wet}}.',
                'answers': {'c1': 'wet'},
              },
            ],
          },
        ],
      });

  Future<(int profileId, int courseRowId, study.Course course)> import(
      String raw) async {
    final profileId = await db.profilesDao.create('Ada');
    final id = await db.studyDao
        .importCourse(profileId: profileId, raw: raw, nowMs: 1);
    return (profileId, id, study.parseCourseString(raw));
  }

  /// [openKey] MUST differ across successive opens of the SAME course in
  /// one test: without a distinct key, `pumpWidget` reuses the existing
  /// `StudySessionScreen` element in place (same widget type, same
  /// position) and skips `initState`/`_load` entirely, leaving the SECOND
  /// "session" showing the FIRST one's stale, already-completed state —
  /// a real Flutter test-harness landmine, not a session bug (confirmed by
  /// checking the DAO state directly, which was correct throughout).
  Future<void> openSession(
      WidgetTester tester, int courseRowId, study.Course course,
      {Key? openKey}) async {
    await tester.pumpWidget(MaterialApp(
        home: StudySessionScreen(
            key: openKey,
            db: db,
            courseRowId: courseRowId,
            course: course)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('begin-session')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recall'));
    await tester.pumpAndSettle();
  }

  /// Answers the single cloze correctly and taps [gradeLabel] — whichever
  /// grade button carries that text, Filled (suggested) or Outlined.
  Future<void> gradeAs(WidgetTester tester, String gradeLabel) async {
    await tester.enterText(find.byKey(const Key('blank-i-a-c1')), 'wet');
    await tester.tap(find.text('Check'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(gradeLabel));
    await tester.pumpAndSettle();
  }

  group('a profile set to Classic grades through scheduleSm2', () {
    testWidgets(
        'the FSRS half of the stateJson blob is never written',
        (tester) async {
      final (profileId, id, course) = await import(singleClozeCourse());
      await db.profilesDao.setScheduler(profileId, 'classic');
      await openSession(tester, id, course);
      await gradeAs(tester, 'Good');

      final card = (await db.studyDao.loadClassicHalves(id))['i-a']!;
      final expected = study.scheduleSm2(
          study.CardState.initial('i-a', course.srsDefaults, epochDayUtcNow()),
          study.Grade.good,
          epochDayUtcNow(),
          firstIntervalDays: course.srsDefaults.firstIntervalDays);
      expect(card.intervalDays, expected.intervalDays);
      expect(card.ease, expected.ease);
      expect(card.reps, expected.reps);

      // The raw blob carries no fsrs-prefixed keys at all — proof the FSRS
      // branch was never entered, not just that its effects are absent.
      final row = await (db.select(db.cards)
            ..where((c) => c.courseId.equals(id) & c.itemId.equals('i-a')))
          .getSingle();
      expect(row.stateJson.contains('fsrsStability'), isFalse);
    });
  });

  group('a profile set to FSRS grades through scheduleFsrs', () {
    testWidgets('the classic half stays completely absent too — grading '
        'under FSRS never writes it', (tester) async {
      final (profileId, id, course) = await import(singleClozeCourse());
      await db.profilesDao.setScheduler(profileId, 'fsrs');
      await openSession(tester, id, course);
      await gradeAs(tester, 'Good');

      final fsrs = (await db.studyDao.loadCards(id))['i-a']!.fsrs!;
      final expectedFirst = study.scheduleFsrs(
          study.FsrsCardState.initial('i-a', epochDayUtcNow()),
          study.Grade.good,
          epochDayUtcNow());
      expect(fsrs.stability, closeTo(expectedFirst.stability, 1e-9));
      expect(fsrs.difficulty, closeTo(expectedFirst.difficulty, 1e-9));

      final row = await (db.select(db.cards)
            ..where((c) => c.courseId.equals(id) & c.itemId.equals('i-a')))
          .getSingle();
      expect(row.stateJson.contains('"ease"'), isFalse,
          reason: 'a card graded ONLY under FSRS never gains classic keys');
    });

    testWidgets('"Again" re-asks the card later in the same session, and '
        'the re-ask does not reschedule it: the stored due stays what FSRS '
        'computed for the lapse', (tester) async {
      final (profileId, id, course) = await import(singleClozeCourse());
      await db.profilesDao.setScheduler(profileId, 'fsrs');
      await openSession(tester, id, course);
      await tester.enterText(find.byKey(const Key('blank-i-a-c1')), 'wrong');
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Again'));
      await tester.pumpAndSettle();

      final afterLapse = (await db.studyDao.loadCards(id))['i-a']!.fsrs!;
      expect(afterLapse.dueEpochDay, greaterThan(epochDayUtcNow()));

      expect(find.text('Session complete'), findsNothing);
      final blank = find.byKey(const Key('blank-i-a-c1'));
      expect(blank, findsOneWidget, reason: 'the card is asked again');
      expect(tester.widget<TextField>(blank).controller!.text, isEmpty,
          reason: 'with the failed attempt cleared');
      await gradeAs(tester, 'Good');

      expect(find.text('Session complete'), findsOneWidget);
      final card = (await db.studyDao.loadCards(id))['i-a']!.fsrs!;
      expect(card, afterLapse);
      expect(await db.studyDao.revlogOf(id), hasLength(1),
          reason: 'practice inside the session is not a scheduled review');
    });
  });

  group('switching keeps progress', () {
    testWidgets('a card with classic progress, switched to FSRS: the first '
        'FSRS grade is computed FROM the seeded classic state, not a bare '
        'fresh card', (tester) async {
      final (profileId, id, course) = await import(singleClozeCourse());
      await db.profilesDao.setScheduler(profileId, 'classic');
      await openSession(tester, id, course);
      await gradeAs(tester, 'Again'); // due again today under SM-2

      final classicAfterFirst =
          (await db.studyDao.loadCards(id))['i-a']!.classic!;
      await db.profilesDao.setScheduler(profileId, 'fsrs');

      await openSession(tester, id, course, openKey: const Key('reopen'));
      await gradeAs(tester, 'Good');

      final seededBefore =
          study.seedFsrsFromClassic(classicAfterFirst, epochDayUtcNow());
      final expectedAfter =
          study.scheduleFsrs(seededBefore, study.Grade.good, epochDayUtcNow());
      final card = (await db.studyDao.loadCards(id))['i-a']!;
      expect(card.fsrs!.stability, closeTo(expectedAfter.stability, 1e-9));
      expect(card.fsrs!.lapses, 1,
          reason: 'the classic lapse came along with the seed');
      expect(card.lastGradedBy, study.Scheduler.fsrs);
    });

    testWidgets('switching back to Classic resumes from the newer FSRS '
        'progress, not the classic state frozen before FSRS', (tester) async {
      final (profileId, id, course) = await import(singleClozeCourse());
      final today = epochDayUtcNow();
      // An FSRS review a week ago, due again today.
      await db.into(db.cards).insert(CardsCompanion.insert(
          courseId: id,
          itemId: 'i-a',
          stateJson: mergeCardStateJson(null,
              fsrs: study.FsrsCardState(
                  itemId: 'i-a',
                  stability: 7,
                  difficulty: 5,
                  dueEpochDay: today,
                  reps: 3,
                  lapses: 0,
                  lastReviewEpochDay: today - 7))));
      await db.profilesDao.setScheduler(profileId, 'classic');

      await openSession(tester, id, course);
      await gradeAs(tester, 'Good');

      final card = (await db.studyDao.loadCards(id))['i-a']!;
      expect(card.lastGradedBy, study.Scheduler.classic);
      expect(card.classic!.intervalDays, greaterThan(7),
          reason: 'SM-2 grew the 7-day interval FSRS had reached');
      expect(card.fsrs!.stability, 7,
          reason: 'the FSRS half stays as it was');
    });
  });
}
