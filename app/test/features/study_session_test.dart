import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_core/study_core.dart' as study;
import 'package:trellis/db/database.dart';
import 'package:trellis/features/intake/paste_intake.dart'
    show epochDayUtcNow;
import 'package:trellis/features/study/course_map_screen.dart';
import 'package:trellis/features/study/study_session_screen.dart';

/// The study session (ADR-0003 law 3 + the grading law): it declares its
/// size before it starts, walks the four donor item UIs, lets auto-grading
/// only HIGHLIGHT a suggestion — the learner's tap is what drives SM-2 —
/// relearns lapses in-session with cleared inputs, appends every grade to
/// the revlog, and ends on a calm screen.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  String fourTypesCourse() => json.encode({
        'schemaVersion': '1.0',
        'id': 'four',
        'title': 'All Four Rungs',
        'nodes': [
          {
            'id': 'n1',
            'title': 'The Weather Concept',
            'intake': 'Rain begins as vapor. Remember the ladder of state.',
            'items': [
              {
                'id': 'i-cloze',
                'type': 'cloze',
                'rung': 1,
                'hints': ['it is a color'],
                'text': 'The sky is {{c1::blue}}.',
                'answers': {'c1': 'blue'},
              },
              {
                'id': 'i-qa',
                'type': 'qa',
                'rung': 3,
                'prompt': 'What makes rain?',
                'answer': 'Condensed vapor falls.',
                'acceptable': ['vapor', 'falls'],
                'rubric': 'Mention vapor and falling.',
              },
              {
                'id': 'i-disc',
                'type': 'discrimination',
                'rung': 2,
                'prompt': 'Pick the wet one',
                'choices': ['stone', 'water', 'sand'],
                'correctIndex': 1,
                'explanation': 'Water is wet.',
              },
              {
                'id': 'i-proc',
                'type': 'procedure',
                'rung': 4,
                'prompt': 'Make tea',
                'steps': ['Boil water', 'Steep leaves', 'Pour'],
                'rubric': 'Order matters.',
              },
            ],
          },
        ],
      });

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

  Future<(int, study.Course)> import(String raw) async {
    await db.profilesDao.create('Ada');
    final id = await db.studyDao.importCourse(profileId: 1, raw: raw, nowMs: 1);
    return (id, study.parseCourseString(raw));
  }

  Future<void> pumpSession(
      WidgetTester tester, int courseRowId, study.Course course) async {
    await tester.pumpWidget(MaterialApp(
        home: StudySessionScreen(
            db: db, courseRowId: courseRowId, course: course)));
    await tester.pumpAndSettle();
  }

  testWidgets('the session declares its size before it starts', (tester) async {
    final (id, course) = await import(fourTypesCourse());
    await pumpSession(tester, id, course);

    expect(find.text('This session'), findsOneWidget);
    expect(find.text('4 items · 1 concept'), findsOneWidget);
    expect(find.byKey(const Key('begin-session')), findsOneWidget);
    // Nothing has been graded — looking at the door writes nothing.
    expect(await db.studyDao.revlogOf(id), isEmpty);
  });

  testWidgets('nothing due is a calm, honest screen', (tester) async {
    final (id, course) = await import(singleClozeCourse());
    const future = study.CardState(
        itemId: 'i-a',
        ease: 2.5,
        intervalDays: 3,
        dueEpochDay: 1 << 40,
        reps: 1,
        lapses: 0);
    await db.studyDao.recordGrade(
        courseRowId: id,
        before: future.copyWith(intervalDays: 2),
        after: future,
        grade: study.Grade.good,
        tsMs: 1);
    await pumpSession(tester, id, course);

    expect(find.text('Nothing due right now'), findsOneWidget);
    expect(find.byKey(const Key('begin-session')), findsNothing);
  });

  testWidgets(
      'the suggestion only highlights — the learner\'s tap drives SM-2',
      (tester) async {
    final (id, course) = await import(fourTypesCourse());
    await pumpSession(tester, id, course);
    await tester.tap(find.byKey(const Key('begin-session')));
    await tester.pumpAndSettle();

    // Intake step first: read, then recall.
    expect(find.text('The Weather Concept'), findsOneWidget);
    await tester.tap(find.text('Recall'));
    await tester.pumpAndSettle();

    // Cloze, answered WRONG.
    expect(find.textContaining('____'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('blank-i-cloze-c1')), 'green');
    await tester.tap(find.text('Check'));
    await tester.pumpAndSettle();

    // Auto-grade suggests Again (filled); Good stays available (outlined).
    expect(find.widgetWithText(FilledButton, 'Again'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Good'), findsOneWidget);
    // The reveal shows the expected answer.
    expect(find.textContaining('blue'), findsWidgets);

    // The learner overrules the suggestion. Their tap is the law.
    await tester.tap(find.widgetWithText(OutlinedButton, 'Good'));
    await tester.pumpAndSettle();

    final log = await db.studyDao.revlogOf(id);
    expect(log.single.grade, 'good',
        reason: 'the tap drives the SRS, not the suggestion');
    expect(log.single.intervalBeforeDays, 0);
    expect(log.single.intervalAfterDays, 1);
    final card = (await db.studyDao.loadCardStates(id))['i-cloze']!;
    expect(card.reps, 1);
    expect(card.intervalDays, 1);
  });

  testWidgets('a correct cloze pre-highlights Good', (tester) async {
    final (id, course) = await import(singleClozeCourse());
    await pumpSession(tester, id, course);
    await tester.tap(find.byKey(const Key('begin-session')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recall'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('blank-i-a-c1')), '  WET ');
    await tester.tap(find.text('Check'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Good'), findsOneWidget,
        reason: 'normalized match: case and whitespace forgiven');
  });

  testWidgets('the four item types walk their donor UIs to a calm end',
      (tester) async {
    final (id, course) = await import(fourTypesCourse());
    await pumpSession(tester, id, course);
    await tester.tap(find.byKey(const Key('begin-session')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recall'));
    await tester.pumpAndSettle();

    // 1. Cloze: hint offered before reveal, blanks checked after.
    expect(find.text('Need a hint?'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('blank-i-cloze-c1')), 'blue');
    await tester.tap(find.text('Check'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Good'));
    await tester.pumpAndSettle();

    // 2. QA free recall: reveal shows the answer and the rubric; full
    // keyword coverage suggests Easy.
    expect(find.text('What makes rain?'), findsOneWidget);
    await tester.enterText(
        find.byKey(const Key('recall-i-qa')), 'vapor condenses and falls');
    await tester.tap(find.text('Reveal answer'));
    await tester.pumpAndSettle();
    expect(find.text('Condensed vapor falls.'), findsOneWidget);
    expect(find.text('Mention vapor and falling.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Easy'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Easy'));
    await tester.pumpAndSettle();

    // 3. Discrimination: Check waits for a choice; the reveal explains.
    expect(find.text('Pick the wet one'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Check'))
            .onPressed,
        isNull,
        reason: 'no grading before a choice is made');
    await tester.tap(find.text('water'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check'));
    await tester.pumpAndSettle();
    expect(find.text('Water is wet.'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Good'));
    await tester.pumpAndSettle();

    // 4. Procedure: the reveal lists the steps in order. No keyword anchors
    // exist, so a non-empty attempt pre-highlights Good (grading.dart law).
    expect(find.text('Make tea'), findsOneWidget);
    await tester.enterText(
        find.byKey(const Key('recall-i-proc')), 'boil, steep, pour');
    await tester.tap(find.text('Reveal steps'));
    await tester.pumpAndSettle();
    expect(find.text('1. Boil water'), findsOneWidget);
    expect(find.text('2. Steep leaves'), findsOneWidget);
    expect(find.text('3. Pour'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Good'));
    await tester.pumpAndSettle();

    // The calm end: what was built, and a door out. No streaks, no guilt.
    expect(find.text('You reviewed 4 items.'), findsOneWidget);
    expect(await db.studyDao.revlogOf(id), hasLength(4));
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('a lapse relearns in THIS session, with cleared inputs',
      (tester) async {
    final (id, course) = await import(singleClozeCourse());
    await pumpSession(tester, id, course);
    await tester.tap(find.byKey(const Key('begin-session')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recall'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('blank-i-a-c1')), 'dry');
    await tester.tap(find.text('Check'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Again'));
    await tester.pumpAndSettle();

    // The same card is back — with an EMPTY field, not the failed attempt.
    final blank = find.byKey(const Key('blank-i-a-c1'));
    expect(blank, findsOneWidget, reason: 'relearn re-queued in-session');
    expect(tester.widget<TextField>(blank).controller!.text, isEmpty);

    await tester.enterText(blank, 'wet');
    await tester.tap(find.text('Check'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Good'));
    await tester.pumpAndSettle();

    expect(find.text('You reviewed 2 items.'), findsOneWidget);
    final log = await db.studyDao.revlogOf(id);
    expect([for (final e in log) e.grade], ['again', 'good']);
    final card = (await db.studyDao.loadCardStates(id))['i-a']!;
    expect(card.lapses, 1);
    expect(card.reps, 1);
  });

  testWidgets('finishing a session recomputes the map\'s unlocks',
      (tester) async {
    await db.profilesDao.create('Ada');
    final ladder = json.encode({
      'schemaVersion': '1.0',
      'id': 'ladder',
      'title': 'A Ladder of Two',
      'nodes': [
        {
          'id': 'a',
          'title': 'Foundation Concept',
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
        {
          'id': 'b',
          'title': 'Dependent Concept',
          'prereqs': ['a'],
          'intake': 'Built on it.',
          'items': [
            {
              'id': 'i-b',
              'type': 'qa',
              'rung': 3,
              'prompt': 'Why?',
              'answer': 'Because.',
            },
          ],
        },
      ],
    });
    final id = await db.studyDao.importCourse(profileId: 1, raw: ladder, nowMs: 1);
    final course = study.parseCourseString(ladder);
    // One good review away from mastery: interval 6, due today.
    final today = epochDayUtcNow();
    final ripening = study.CardState(
        itemId: 'i-a',
        ease: 2.5,
        intervalDays: 6,
        dueEpochDay: today,
        reps: 2,
        lapses: 0);
    await db.studyDao.recordGrade(
        courseRowId: id,
        before: ripening.copyWith(intervalDays: 3),
        after: ripening,
        grade: study.Grade.good,
        tsMs: 1);

    final rows = await db.studyDao.coursesOf(1);
    await tester.pumpWidget(MaterialApp(
        home: CourseMapScreen(db: db, courseRow: rows.single, course: course)));
    await tester.pumpAndSettle();

    expect(
        find.descendant(
            of: find.byKey(const Key('node-b')),
            matching: find.byIcon(Icons.lock_outline)),
        findsOneWidget);

    await tester.tap(find.byKey(const Key('study-fab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('begin-session')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recall'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('blank-i-a-c1')), 'wet');
    await tester.tap(find.text('Check'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Good'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    // Back on the map: interval grew past the mastery threshold, the
    // dependent concept opened — recomputed from the cards, not stored.
    expect(find.byIcon(Icons.lock_outline), findsNothing);
    expect(
        find.descendant(
            of: find.byKey(const Key('node-a')),
            matching: find.byIcon(Icons.check)),
        findsOneWidget);
  });
}
