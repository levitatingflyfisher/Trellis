import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_core/study_core.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/intake/paste_intake.dart' show epochDayUtcNow;
import 'package:trellis/features/study/course_map_screen.dart';
import 'package:trellis/features/study/study_session_screen.dart';

/// Unlock and mastery must see progress made under FSRS. Before this, they
/// read only the SM-2 half of a card's blob, which an FSRS grade never
/// writes, so a profile on FSRS stayed stuck on its first node forever.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  final raw = json.encode({
    'schemaVersion': '1.0',
    'id': 'two',
    'title': 'Two Nodes',
    'nodes': [
      {
        'id': 'n1',
        'title': 'First',
        'intake': 'Water is wet.',
        'items': [
          {
            'id': 'a',
            'type': 'cloze',
            'rung': 1,
            'text': 'Water is {{c1::wet}}.',
            'answers': {'c1': 'wet'},
          },
        ],
      },
      {
        'id': 'n2',
        'title': 'Second',
        'prereqs': ['n1'],
        'intake': 'Ice is cold.',
        'items': [
          {
            'id': 'b',
            'type': 'cloze',
            'rung': 1,
            'text': 'Ice is {{c1::cold}}.',
            'answers': {'c1': 'cold'},
          },
        ],
      },
    ],
  });

  test('a fresh FSRS profile grading its first node Good, each time on the '
      'due day, unlocks the next node and counts as mastered', () async {
    final profileId = await db.profilesDao.create('Ada');
    await db.profilesDao.setScheduler(profileId, 'fsrs');
    final id = await db.studyDao
        .importCourse(profileId: profileId, raw: raw, nowMs: 1);
    final course = parseCourseString(raw);

    var day = 20000;
    var state = FsrsCardState.initial('a', day);
    // Grade on each due day until the scheduled interval passes a week.
    while (state.reps == 0 || state.dueEpochDay - day < 7) {
      if (state.reps > 0) day = state.dueEpochDay;
      final next = scheduleFsrs(state, Grade.good, day);
      await db.studyDao.recordGradeFsrs(
          courseRowId: id, before: state, after: next,
          grade: Grade.good, tsMs: day);
      state = next;
    }
    expect(state.dueEpochDay - day, greaterThanOrEqualTo(7));

    final cards = await db.studyDao.loadCards(id);
    final progress = {
      for (final e in cards.entries) e.key: e.value.progress,
    };
    final n1 = course.nodeById('n1')!;
    final n2 = course.nodeById('n2')!;
    expect(progress['a']?.started, isTrue);
    expect(nodeProgress(n1, progress, day).mastery, 1.0);
    expect(nodeUnlocked(n2, course, progress, day), isTrue);

    final built = await db.householdDao.lifetimeBuiltOf(profileId);
    expect(built.cardsMastered, 1);
  });

  testWidgets('the course map and the session agree on what an FSRS '
      'profile can study: the next node, once the first is mastered',
      (tester) async {
    final profileId = await db.profilesDao.create('Ada');
    await db.profilesDao.setScheduler(profileId, 'fsrs');
    final id = await db.studyDao
        .importCourse(profileId: profileId, raw: raw, nowMs: 1);
    final course = parseCourseString(raw);
    final today = epochDayUtcNow();
    await db.into(db.cards).insert(CardsCompanion.insert(
        courseId: id,
        itemId: 'a',
        stateJson: mergeCardStateJson(null,
            fsrs: FsrsCardState(
                itemId: 'a',
                stability: 20,
                difficulty: 5,
                dueEpochDay: today + 20,
                reps: 3,
                lapses: 0,
                lastReviewEpochDay: today))));
    final row = (await db.studyDao.coursesOf(profileId)).single;

    await tester.pumpWidget(MaterialApp(
        home: CourseMapScreen(db: db, courseRow: row, course: course)));
    await tester.pumpAndSettle();
    expect(find.text('Mastery 50%'), findsOneWidget);
    expect(find.text('Study · 1 due'), findsOneWidget);

    await tester.pumpWidget(MaterialApp(
        home: StudySessionScreen(
            key: const Key('session'),
            db: db,
            courseRowId: id,
            course: course)));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 item'), findsOneWidget);
    expect(find.textContaining('1 concept'), findsOneWidget);
  });
}
