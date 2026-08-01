import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_core/study_core.dart' as study;
import 'package:trellis/db/database.dart';
import 'package:trellis/features/intake/paste_intake.dart' show epochDayUtcNow;
import 'package:trellis/features/study/study_session_screen.dart';

/// The study crown, closing the reachability gap a review caught: FSRS-5
/// (21 tests, packages/study_core/test/fsrs_scheduler_test.dart) is real
/// but until this file, nothing a user could do ever invoked it —
/// study_session_screen.dart graded through scheduleSm2 unconditionally,
/// regardless of the profile's scheduler setting. This file proves the
/// dispatch: Classic (the default) grades byte-for-byte as it always has;
/// FSRS grades through scheduleFsrs, seeded lazily from classic history on
/// first touch, and a round trip back to Classic lands on classic state
/// that was never mutated while FSRS was active.
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

  group('the default profile (Classic) is untouched', () {
    testWidgets(
        'grades through scheduleSm2 exactly as before — the FSRS half of '
        'the stateJson blob is never written for a Classic profile',
        (tester) async {
      final (_, id, course) = await import(singleClozeCourse());
      await openSession(tester, id, course);
      await gradeAs(tester, 'Good');

      final card = (await db.studyDao.loadCardStates(id))['i-a']!;
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

      final fsrs =
          (await db.studyDao.loadFsrsCardStates(id, epochDayUtcNow()))['i-a']!;
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

    testWidgets('a lapse ("Again") is not re-queued in-session — FSRS '
        'schedules at least one day out even for a lapse (day-granularity, '
        'no same-day relearning steps; see fsrs_scheduler.dart), unlike '
        'SM-2\'s immediate same-day relearn', (tester) async {
      final (profileId, id, course) = await import(singleClozeCourse());
      await db.profilesDao.setScheduler(profileId, 'fsrs');
      await openSession(tester, id, course);
      await tester.enterText(find.byKey(const Key('blank-i-a-c1')), 'wrong');
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Again'));
      await tester.pumpAndSettle();

      // A same-day relearn would land back on the item step. Instead the
      // session should already be done — nothing left due today.
      expect(find.text('Session complete'), findsOneWidget);
    });
  });

  group('lazy seeding: real classic history seeds the first FSRS grade',
      () {
    testWidgets('a card with classic progress, switched to FSRS: the first '
        'FSRS grade is computed FROM the seeded classic state, not a bare '
        'fresh card', (tester) async {
      final (profileId, id, course) = await import(singleClozeCourse());
      await openSession(tester, id, course);
      await gradeAs(tester, 'Good'); // real classic history: reps 1, interval 1

      final classicAfterFirst = (await db.studyDao.loadCardStates(id))['i-a']!;
      await db.profilesDao.setScheduler(profileId, 'fsrs');

      // Reopen the session (a fresh due queue) and grade again, now on FSRS.
      await openSession(tester, id, course, openKey: const Key('reopen'));
      await gradeAs(tester, 'Good');

      final seededBefore =
          study.seedFsrsFromClassic(classicAfterFirst, epochDayUtcNow());
      final expectedAfter =
          study.scheduleFsrs(seededBefore, study.Grade.good, epochDayUtcNow());
      final fsrsAfter =
          (await db.studyDao.loadFsrsCardStates(id, epochDayUtcNow()))['i-a']!;
      expect(fsrsAfter.stability, closeTo(expectedAfter.stability, 1e-9),
          reason: 'the seed carried real classic progress in, not a fresh '
              'S0/D0 as if the card had never been studied');
    });
  });

  group('switching back to Classic lands on intact, unmutated classic state',
      () {
    testWidgets(
        'a classic -> FSRS -> classic round trip resumes classic grading '
        'exactly where it was frozen, never touched by the FSRS excursion',
        (tester) async {
      final (profileId, id, course) = await import(singleClozeCourse());
      await openSession(tester, id, course);
      await gradeAs(tester, 'Good');
      final classicAfterFirst = (await db.studyDao.loadCardStates(id))['i-a']!;

      // FSRS excursion: switch, grade (item is due again immediately after
      // its first classic grade puts it at interval 1 -- not due tomorrow
      // yet, so seed the queue by grading whatever FSRS makes due; the
      // classic row must not move regardless of what happens here).
      await db.profilesDao.setScheduler(profileId, 'fsrs');
      final before = await db.studyDao.fsrsStateToGradeFrom(
          courseRowId: id,
          itemId: 'i-a',
          classicBefore: classicAfterFirst,
          todayEpochDay: epochDayUtcNow());
      final after =
          study.scheduleFsrs(before, study.Grade.easy, epochDayUtcNow());
      await db.studyDao.recordGradeFsrs(
          courseRowId: id,
          before: before,
          after: after,
          grade: study.Grade.easy,
          tsMs: 2);

      final classicDuringFsrs = (await db.studyDao.loadCardStates(id))['i-a']!;
      expect(classicDuringFsrs.ease, classicAfterFirst.ease,
          reason: 'the classic half must not move while FSRS is active');
      expect(classicDuringFsrs.intervalDays, classicAfterFirst.intervalDays);
      expect(classicDuringFsrs.dueEpochDay, classicAfterFirst.dueEpochDay);

      // Switch back — classic resumes from exactly what it was frozen at.
      await db.profilesDao.setScheduler(profileId, 'classic');
      final classicAfterSwitchBack =
          (await db.studyDao.loadCardStates(id))['i-a']!;
      expect(classicAfterSwitchBack.ease, classicAfterFirst.ease);
      expect(classicAfterSwitchBack.intervalDays,
          classicAfterFirst.intervalDays);
      expect(classicAfterSwitchBack.dueEpochDay, classicAfterFirst.dueEpochDay);
      expect(classicAfterSwitchBack.reps, classicAfterFirst.reps);
    });
  });
}
