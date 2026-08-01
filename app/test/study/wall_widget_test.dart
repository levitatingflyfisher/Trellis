import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhearth_design/openhearth_design.dart';
import 'package:study_core/study_core.dart' as study;
import 'package:trellis/db/database.dart';
import 'package:trellis/features/intake/paste_intake.dart' show epochDayUtcNow;
import 'package:trellis/features/study/course_map_screen.dart';
import 'package:trellis/features/study/wall/espalier_wall.dart';

/// The Espalier Wall on the course map (proposal-2 §12): studyable concepts
/// are fruits, locked concepts are buds further up the lattice, due chips
/// ride on fruits, and the presentable-due FAB declares the session size.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  String ladderJson({String title = 'Wall Course'}) => json.encode({
        'schemaVersion': '1.0',
        'id': 'wall-c',
        'title': title,
        'nodes': [
          {
            'id': 'n1',
            'title': 'Foundation',
            'intake': 'Read.',
            'items': [
              {
                'id': 'i1',
                'type': 'cloze',
                'rung': 1,
                'text': 'The sky is {{c1::blue}}.',
                'answers': {'c1': 'blue'},
              },
              {
                'id': 'i2',
                'type': 'cloze',
                'rung': 1,
                'text': 'Grass is {{c1::green}}.',
                'answers': {'c1': 'green'},
              },
            ],
          },
          {
            'id': 'n2',
            'title': 'Dependent',
            'prereqs': ['n1'],
            'intake': 'Read.',
            'items': [
              {
                'id': 'i3',
                'type': 'cloze',
                'rung': 1,
                'text': 'Snow is {{c1::white}}.',
                'answers': {'c1': 'white'},
              },
            ],
          },
        ],
      });

  /// Sets both of the foundation's cards to [intervalDays], due on
  /// [dueEpochDay] — the knob that moves n1 between started / mastered.
  Future<void> seedFoundation(int courseRowId,
      {required int intervalDays, required int dueEpochDay}) async {
    for (final itemId in ['i1', 'i2']) {
      final state = study.CardState(
          itemId: itemId,
          ease: 2.5,
          intervalDays: intervalDays,
          dueEpochDay: dueEpochDay,
          reps: 2,
          lapses: 0);
      await db.studyDao.recordGrade(
          courseRowId: courseRowId,
          before: state.copyWith(intervalDays: 1),
          after: state,
          grade: study.Grade.good,
          tsMs: 1);
    }
  }

  Future<CourseRow> importLadder(String raw) async {
    await db.profilesDao.create('Ada');
    await db.studyDao.importCourse(profileId: 1, raw: raw, nowMs: 1);
    return (await db.studyDao.coursesOf(1)).single;
  }

  Future<void> pumpMap(WidgetTester tester, CourseRow row, String raw) async {
    await tester.pumpWidget(MaterialApp(
        theme: OhTheme.light(),
        home: CourseMapScreen(
            db: db, courseRow: row, course: study.parseCourseString(raw))));
    await tester.pumpAndSettle();
  }

  testWidgets('a studyable concept is a fruit; a locked one is a bud',
      (tester) async {
    final raw = ladderJson();
    final row = await importLadder(raw);
    await pumpMap(tester, row, raw);

    expect(find.byKey(const Key('fruit-n1')), findsOneWidget);
    expect(find.byKey(const Key('bud-n2')), findsOneWidget);
    expect(find.byKey(const Key('fruit-n2')), findsNothing);
    expect(find.byKey(const Key('bud-n1')), findsNothing);

    // The lock lives on the bud; the open book on the studyable fruit.
    expect(
        find.descendant(
            of: find.byKey(const Key('node-n2')),
            matching: find.byIcon(Icons.lock_outline)),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const Key('node-n1')),
            matching: find.byIcon(Icons.menu_book_outlined)),
        findsOneWidget);

    // Both never-seen foundation items ride the fruit as one due chip.
    expect(
        find.descendant(
            of: find.byKey(const Key('node-n1')), matching: find.text('2')),
        findsOneWidget);
  });

  testWidgets('the FAB appears with presentable due and declares the size',
      (tester) async {
    final raw = ladderJson();
    final row = await importLadder(raw);
    await pumpMap(tester, row, raw);

    // Only the unlocked foundation's 2 items are presentable — the locked,
    // unstarted dependent must not inflate the declaration (ADR-0003 law 3).
    expect(find.byKey(const Key('study-fab')), findsOneWidget);
    expect(find.text('Study · 2 due'), findsOneWidget);
  });

  testWidgets('no presentable due, no FAB', (tester) async {
    final raw = ladderJson();
    final row = await importLadder(raw);
    // Foundation started but scheduled ahead and below the mastery
    // threshold: nothing due there, and the dependent stays a locked bud.
    await seedFoundation(row.id,
        intervalDays: 3, dueEpochDay: epochDayUtcNow() + 30);
    await pumpMap(tester, row, raw);

    expect(find.byKey(const Key('study-fab')), findsNothing);
    expect(find.byKey(const Key('fruit-n1')), findsOneWidget);
    expect(find.byKey(const Key('bud-n2')), findsOneWidget);
  });

  testWidgets('a mastered prerequisite ripens terracotta and buds its heir',
      (tester) async {
    final raw = ladderJson();
    final row = await importLadder(raw);
    await seedFoundation(row.id,
        intervalDays: 8, dueEpochDay: 1 << 40);
    await pumpMap(tester, row, raw);

    // The foundation is fully ripe…
    final fruit =
        tester.widget<WallFruit>(find.byKey(const Key('fruit-n1')));
    expect(fruit.mastery, 1.0);
    expect(
        find.descendant(
            of: find.byKey(const Key('node-n1')),
            matching: find.byIcon(Icons.check)),
        findsOneWidget);
    // …which unlocks the dependent into a green fruit of its own.
    expect(find.byKey(const Key('fruit-n2')), findsOneWidget);
    expect(find.byKey(const Key('bud-n2')), findsNothing);
    expect(find.byIcon(Icons.lock_outline), findsNothing);
    // Its one never-seen item is now the whole declared session.
    expect(find.text('Study · 1 due'), findsOneWidget);
  });

  testWidgets('the export affordance survives the wall', (tester) async {
    final raw = ladderJson();
    final row = await importLadder(raw);
    await pumpMap(tester, row, raw);
    expect(find.byKey(const Key('export-anki')), findsOneWidget);
  });

  testWidgets('at 320dp the wall pans instead of overflowing', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(() {
      tester.view.reset();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });

    // Five roots make the widest cordon far wider than 320dp.
    final raw = json.encode({
      'schemaVersion': '1.0',
      'id': 'wide-c',
      'title': 'A Wide Wall',
      'nodes': [
        for (var i = 1; i <= 5; i++)
          {
            'id': 'w$i',
            'title': 'An Uncommonly Verbose Concept Title Number $i',
            'intake': 'Read.',
            'items': [
              {
                'id': 'wi$i',
                'type': 'cloze',
                'rung': 1,
                'text': 'Fact $i is {{c1::true}}.',
                'answers': {'c1': 'true'},
              },
            ],
          },
      ],
    });
    final row = await importLadder(raw);
    await pumpMap(tester, row, raw);

    expect(tester.takeException(), isNull, reason: '320dp × 2.0 text scale');
    expect(find.byKey(const Key('wall-pan')), findsOneWidget);
    // Every fruit exists on the pannable wall, even the off-stage ones.
    for (var i = 1; i <= 5; i++) {
      expect(find.byKey(Key('fruit-w$i')), findsOneWidget);
    }
    // The wall really is wider than the screen — that's what the pan is for.
    final wall = tester.getSize(find.byKey(const Key('wall-surface')));
    expect(wall.width, greaterThan(320));
  });
}
