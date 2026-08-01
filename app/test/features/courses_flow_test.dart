import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_core/study_core.dart' as study;
import 'package:trellis/db/database.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/scripted_fetcher.dart';

/// The Courses tab: import is study_core's strict parser or nothing (a bad
/// paste shows the parser's own calm error and leaves ZERO rows), the list
/// is the reader's imported courses, and the bundled starter course is an
/// offer — never auto-imported (the user's hand does the importing).
void main() {
  late AppDatabase db;
  late FakeEpisodePlayer player;
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    player = FakeEpisodePlayer();
  });
  tearDown(() => db.close());

  String ladderCourse() => json.encode({
        'schemaVersion': '1.0',
        'id': 'ladder',
        'title': 'A Ladder of Two',
        'nodes': [
          {
            'id': 'a',
            'title': 'Foundation Concept',
            'intake': 'Water is wet — remember it.',
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
            'intake': 'Built on the foundation.',
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

  /// Boots the app to the Courses tab — creating the profile on a first
  /// run, or picking the pre-seeded one when a test built data up front.
  Future<void> pumpToCourses(WidgetTester tester) async {
    await tester.pumpWidget(TrellisApp(
        db: db,
        fetcher: ScriptedFetcher((u, h) => textResponse('')),
        createPlayer: () => player));
    await tester.pumpAndSettle();
    final nameField = find.byKey(const Key('profile-name'));
    if (nameField.evaluate().isNotEmpty) {
      await tester.enterText(nameField, 'Ada');
      await tester.tap(find.text('Start reading'));
    } else {
      await tester.tap(find.text('Ada')); // the picker
    }
    await tester.pumpAndSettle();
    await tester.tap(find.text('Courses'));
    await tester.pumpAndSettle();
  }

  testWidgets('the tab starts empty — nothing is auto-imported', (tester) async {
    await pumpToCourses(tester);
    expect(find.text('Nothing to study yet.'), findsOneWidget);
    expect(await db.studyDao.coursesOf(1), isEmpty,
        reason: 'the starter course is an offer, not an import');
  });

  testWidgets('a bad paste shows the parser error calmly and imports NOTHING',
      (tester) async {
    await pumpToCourses(tester);
    await tester.tap(find.text('Paste a course'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('course-json')), '{"schemaVersion":"9.9"}');
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    // The strict parser's own message, shown inline; the dialog stays open.
    expect(find.textContaining('unsupported schemaVersion'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing to study yet.'), findsOneWidget);
    expect(await db.studyDao.coursesOf(1), isEmpty);
  });

  testWidgets('a valid paste lands the course in the list', (tester) async {
    await pumpToCourses(tester);
    await tester.tap(find.text('Paste a course'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('course-json')), ladderCourse());
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    expect(find.text('A Ladder of Two'), findsOneWidget);
    expect(find.textContaining('2 concepts'), findsOneWidget);
  });

  testWidgets('the starter course imports on the user\'s tap', (tester) async {
    await pumpToCourses(tester);
    await tester.tap(find.text('Add the starter course'));
    await tester.pumpAndSettle();
    expect(find.text('The Kalman Filter Family'), findsOneWidget);
    final rows = await db.studyDao.coursesOf(1);
    expect(rows.single.courseId, 'kalman-filters');
  });

  test('the bundled starter course parses with the strict parser', () {
    // Straight off disk: rootBundle wiring is already proven by the
    // import-on-tap test above; this pins the FILE against rot. (A second
    // rootBundle load here would await a future cached by the previous
    // test's fake-async zone — a permanent hang.)
    final raw = File('assets/courses/kalman.ohcourse').readAsStringSync();
    final course = study.parseCourseString(raw); // throws if the sample rots
    expect(course.title, 'The Kalman Filter Family');
    expect(course.nodes, isNotEmpty);
  });

  testWidgets(
      'the course map is a ladder: unlocked below, locked above, due chips',
      (tester) async {
    await db.profilesDao.create('Ada');
    await db.studyDao.importCourse(profileId: 1, raw: ladderCourse(), nowMs: 1);
    await pumpToCourses(tester);

    await tester.tap(find.text('A Ladder of Two'));
    await tester.pumpAndSettle();

    // The foundation is open to study, the dependent concept is locked.
    expect(
        find.descendant(
            of: find.byKey(const Key('node-a')),
            matching: find.byIcon(Icons.menu_book_outlined)),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const Key('node-b')),
            matching: find.byIcon(Icons.lock_outline)),
        findsOneWidget);
    // The foundation's one never-seen item counts as due.
    expect(
        find.descendant(
            of: find.byKey(const Key('node-a')), matching: find.text('1')),
        findsOneWidget);
    // The session's size is declared before it starts (ADR-0003 law 3).
    expect(find.text('Study · 1 due'), findsOneWidget);
  });

  testWidgets('a mastered prerequisite shows its check and unlocks the ladder',
      (tester) async {
    await db.profilesDao.create('Ada');
    final id = await db.studyDao
        .importCourse(profileId: 1, raw: ladderCourse(), nowMs: 1);
    // Seed a durable card: interval past the mastery threshold, not due.
    const mastered = study.CardState(
        itemId: 'i-a',
        ease: 2.5,
        intervalDays: 8,
        dueEpochDay: 1 << 40,
        reps: 3,
        lapses: 0);
    await db.studyDao.recordGrade(
        courseRowId: id,
        before: mastered.copyWith(intervalDays: 7),
        after: mastered,
        grade: study.Grade.good,
        tsMs: 1);
    await pumpToCourses(tester);

    await tester.tap(find.text('A Ladder of Two'));
    await tester.pumpAndSettle();

    expect(
        find.descendant(
            of: find.byKey(const Key('node-a')),
            matching: find.byIcon(Icons.check)),
        findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsNothing,
        reason: 'a fully mastered prerequisite unlocks its dependents');
  });
}
