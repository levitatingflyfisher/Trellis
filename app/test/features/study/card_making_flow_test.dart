import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_core/study_core.dart' as study;
import 'package:trellis/db/database.dart';
import 'package:trellis/features/study/course_map_screen.dart';
import 'package:trellis/features/study/courses_screen.dart';
import 'package:trellis/features/study/study_session_screen.dart';

import '../brain_test_support.dart';

/// Making and editing cards by hand, on screen (owner, 28 Oct: "have we
/// fixed the flashcard mechanics for highlighting and writing stuff and
/// editing it reasonable?"; "I don't see anything stolen from mochi or
/// from anki on having cloze"). The pure half is
/// test/study/card_editing_test.dart.
void main() {
  late AppDatabase db;
  late int profileId;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
  });
  tearDown(() => db.close());

  String ladder() => json.encode({
        'schemaVersion': '1.0',
        'id': 'ladder',
        'title': 'A Ladder',
        'nodes': [
          {
            'id': 'a',
            'title': 'Foundation',
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

  Future<CourseRow> seed() async {
    final id = await db.studyDao
        .importCourse(profileId: profileId, raw: ladder(), nowMs: 1);
    return (await db.studyDao.courseRowById(id))!;
  }

  study.Course parsed(CourseRow row) => study.parseCourseString(row.raw);

  Future<void> pumpMap(WidgetTester tester, CourseRow row) async {
    await tester.pumpWidget(MaterialApp(
        home: CourseMapScreen(db: db, courseRow: row, course: parsed(row))));
    await tester.pumpAndSettle();
  }

  Future<void> openCards(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('open-cards')));
    await tester.pumpAndSettle();
  }

  Future<String> rawNow(int id) async =>
      (await db.studyDao.courseRowById(id))!.raw;

  TextEditingController controllerOf(WidgetTester tester, String key) =>
      tester.widget<TextField>(find.byKey(Key(key))).controller!;

  testWidgets(
      'from a course: Cards lists its cards, and Add card puts a front and '
      'back card in it', (tester) async {
    final row = await seed();
    await pumpMap(tester, row);
    await openCards(tester);
    expect(find.text('Water is ____.'), findsOneWidget,
        reason: 'a cloze is listed as it is asked');

    await tester.tap(find.byKey(const Key('add-card')));
    await tester.pumpAndSettle();
    expect(find.text('Add card'), findsWidgets);
    await tester.enterText(
        find.byKey(const Key('card-front')), 'Capital of France?');
    await tester.enterText(find.byKey(const Key('card-back')), 'Paris');
    await tester.tap(find.byKey(const Key('card-save')));
    await tester.pumpAndSettle();

    expect(find.text('Capital of France?'), findsOneWidget);
    final items = study.parseCourseString(await rawNow(row.id)).nodes.single
        .items;
    expect(items, hasLength(2));
    expect((items.last as study.QaItem).answer, 'Paris');
  });

  testWidgets('a cloze card is edited from the list, and keeps its history',
      (tester) async {
    final row = await seed();
    const seen = study.CardState(
        itemId: 'i-a',
        ease: 2.5,
        intervalDays: 3,
        dueEpochDay: 1 << 40,
        reps: 2,
        lapses: 0);
    await db.studyDao.recordGrade(
        courseRowId: row.id,
        before: seen.copyWith(intervalDays: 1),
        after: seen,
        grade: study.Grade.good,
        tsMs: 1);
    await pumpMap(tester, row);
    await openCards(tester);

    await tester.tap(find.text('Water is ____.'));
    await tester.pumpAndSettle();
    expect(find.text('Edit card'), findsWidgets);
    expect(controllerOf(tester, 'card-cloze-text').text,
        'Water is {{c1::wet}}.');
    await tester.enterText(
        find.byKey(const Key('card-cloze-text')), 'Water is {{c1::damp}}.');
    await tester.tap(find.byKey(const Key('card-save')));
    await tester.pumpAndSettle();

    final item = study.parseCourseString(await rawNow(row.id))
        .nodes
        .single
        .items
        .single as study.ClozeItem;
    expect(item.id, 'i-a');
    expect(item.answers, {'c1': 'damp'});
    expect((await db.studyDao.loadCards(row.id))['i-a']!.classic!.reps, 2,
        reason: 'the card’s history stays with it');
  });

  testWidgets(
      'a cloze with no blank is refused in plain words, and nothing is saved',
      (tester) async {
    final row = await seed();
    await pumpMap(tester, row);
    await openCards(tester);
    await tester.tap(find.byKey(const Key('add-card')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cloze'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('card-cloze-text')), 'No blank here.');
    await tester.tap(find.byKey(const Key('card-save')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('card-error')), findsOneWidget);
    expect(find.textContaining('{{c1::like this}}'), findsOneWidget);
    expect(await rawNow(row.id), row.raw);
  });

  testWidgets('Hide the selection turns the selected words into a blank',
      (tester) async {
    final row = await seed();
    await pumpMap(tester, row);
    await openCards(tester);
    await tester.tap(find.byKey(const Key('add-card')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cloze'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('card-cloze-text')), 'Ice is cold.');
    final c = controllerOf(tester, 'card-cloze-text');
    c.selection = const TextSelection(baseOffset: 7, extentOffset: 11);
    await tester.tap(find.byKey(const Key('card-blank')));
    await tester.pumpAndSettle();
    expect(c.text, 'Ice is {{c1::cold}}.');
    expect(tester.getSize(find.byKey(const Key('card-blank'))).height,
        greaterThanOrEqualTo(48));
  });

  testWidgets(
      'a card is deleted from its editor, but a step keeps its last card',
      (tester) async {
    final row = await seed();
    await pumpMap(tester, row);
    await openCards(tester);
    await tester.tap(find.text('Water is ____.'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('card-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.textContaining('keeps at least one card'), findsOneWidget);
    expect(await rawNow(row.id), row.raw);
  });

  testWidgets(
      'the Courses tab makes a card into My cards, and studying it starts '
      'at the card, with no reading first', (tester) async {
    final profile =
        (await db.profilesDao.all()).firstWhere((p) => p.id == profileId);
    await tester.pumpWidget(
        MaterialApp(home: CoursesScreen(db: db, profile: profile)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Make a card'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('card-front')), 'Hola means?');
    await tester.enterText(find.byKey(const Key('card-back')), 'Hello');
    await tester.tap(find.byKey(const Key('card-save')));
    await tester.pumpAndSettle();
    expect(find.text('My cards'), findsOneWidget);

    // A second card joins the same course.
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make a card'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('card-front')), 'Adiós means?');
    await tester.enterText(find.byKey(const Key('card-back')), 'Goodbye');
    await tester.tap(find.byKey(const Key('card-save')));
    await tester.pumpAndSettle();
    final rows = await db.studyDao.coursesOf(profileId);
    expect(rows.single.courseId, 'my-cards');
    expect(study.parseCourseString(rows.single.raw).nodes.single.items,
        hasLength(2));

    await tester.tap(find.text('My cards'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Study · 2 due'));
    await tester.pumpAndSettle();
    expect(find.text('2 items'), findsOneWidget,
        reason: 'no reading step is counted');
    await tester.tap(find.byKey(const Key('begin-session')));
    await tester.pumpAndSettle();
    expect(find.text('Hola means?'), findsOneWidget);
    expect(find.text('Recall'), findsNothing);
  });

  testWidgets('a card is edited while studying, and the session asks the '
      'new words', (tester) async {
    final row = await seed();
    await tester.pumpWidget(MaterialApp(
        home: StudySessionScreen(
            db: db,
            courseRowId: row.id,
            course: parsed(row),
            brainStore: fakeBrainStore(secrets: InMemorySecretStore()))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('begin-session')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recall'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Water is'), findsOneWidget);

    await tester.tap(find.byKey(const Key('edit-card')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('card-cloze-text')), 'Rain is {{c1::wet}}.');
    await tester.tap(find.byKey(const Key('card-save')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Rain is'), findsOneWidget);
    expect(find.textContaining('Water is'), findsNothing);
    expect(
        (study.parseCourseString(await rawNow(row.id)).nodes.single.items
                .single as study.ClozeItem)
            .text,
        'Rain is {{c1::wet}}.');
  });
}
