import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_core/study_core.dart' as study;
import 'package:trellis/db/database.dart';
import 'package:trellis/features/profiles/parent_dashboard.dart';
import 'package:trellis/features/profiles/parent_pin.dart';

/// The parent dashboard (P5): per-profile LIFETIME BUILT cards. Laws under
/// test:
///
/// - Positive framing (ADR-0003 law 5): a card shows what was built, never
///   a zero, never absence — a brand-new reader gets a calm
///   "just getting started" line, not a wall of 0s.
/// - Rename and remove flow through to the database; remove asks first.
/// - The household PIN section obeys the current-PIN law and tells the
///   honest no-recovery truth.
void main() {
  late AppDatabase db;
  late ParentPinService pin;
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    pin = ParentPinService(db);
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

  study.CardState cardState(String itemId, {required int intervalDays}) =>
      study.CardState(
        itemId: itemId,
        ease: 2.5,
        intervalDays: intervalDays,
        dueEpochDay: 100 + intervalDays,
        reps: 1,
        lapses: 0,
      );

  /// Ada has built things; Grace is brand new. Returns (adaId, graceId).
  Future<(int, int)> seed() async {
    final ada = await db.profilesDao.create('Ada');
    final grace = await db.profilesDao.create('Grace');
    final w1 = await db.spineDao.insertWork(
      profileId: ada,
      kind: 'book',
      title: 'Kept',
      persistence: 'work',
      firstSeenEpochDay: 100,
    );
    final w2 = await db.spineDao.insertWork(
      profileId: ada,
      kind: 'book',
      title: 'Finished',
      persistence: 'work',
      firstSeenEpochDay: 100,
    );
    await db.spineDao.markFinished(w2, 120);
    await db.feedsDao.savePlayerPosition(
      profileId: ada,
      workId: w1,
      tMs: 5 * 60000,
    );
    final course = await db.studyDao.importCourse(
      profileId: ada,
      raw: ladderCourse(),
      nowMs: 1000,
    );
    await db.studyDao.recordGrade(
      courseRowId: course,
      before: cardState('i-a', intervalDays: 3),
      after: cardState('i-a', intervalDays: 7),
      grade: study.Grade.good,
      tsMs: 2000,
    );
    await db.ledgerDao.add(profileId: ada, word: 'saudade', nowMs: 1);
    await db.ledgerDao.add(profileId: ada, word: 'hygge', nowMs: 2);
    final feedId = await db.feedsDao.insertFeed(
      profileId: ada,
      url: 'https://cast.test/feed',
    );
    final episode = await db.spineDao.insertWork(
      profileId: ada,
      kind: 'episode',
      title: 'Processed',
      persistence: 'ephemeron',
      firstSeenEpochDay: 100,
    );
    await db.feedsDao.insertEpisode(
      workId: episode,
      feedId: feedId,
      guid: 'e',
      publishedAtMs: 1,
    );
    await db.feedsDao.setDspResult(
      episode,
      originalDurationMs: 10 * 60000,
      processedDurationMs: 7 * 60000,
    );
    // Campaign 4 Phase 5: two distinct reading days.
    await db.profilesDao.recordReadingDay(ada, 100);
    await db.profilesDao.recordReadingDay(ada, 101);
    return (ada, grace);
  }

  Future<void> pumpDashboard(
    WidgetTester tester, {
    double textScale = 1.0,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: ParentDashboardScreen(db: db, pin: pin),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows a calm per-profile card of what each reader has built', (
    tester,
  ) async {
    await seed();
    await pumpDashboard(tester);

    expect(find.text('Ada'), findsOneWidget);
    expect(find.text('2 works in the library'), findsOneWidget);
    expect(find.text('1 work finished'), findsOneWidget);
    expect(find.text('1 card mastered'), findsOneWidget);
    expect(find.text('2 words collected'), findsOneWidget);
    expect(find.text('5 minutes of listening'), findsOneWidget);
    expect(find.text('3 minutes saved'), findsOneWidget);
    expect(find.text('2 days of reading'), findsOneWidget);
    expect(
      find.text('Current course: A Ladder of Two — 1 of 2 mastered'),
      findsOneWidget,
    );

    // Grace has built nothing yet: a calm line, never a wall of zeros.
    expect(find.text('Grace'), findsOneWidget);
    expect(find.text('Just getting started.'), findsOneWidget);
    expect(
      find.textContaining('0 '),
      findsNothing,
      reason: 'positive framing: absence is never itemized',
    );
  });

  group('builtLines — the "time saved" line (Campaign 6)', () {
    LifetimeBuilt built({int timeSavedMs = 0}) => (
      worksKept: 0,
      worksFinished: 0,
      cardsMastered: 0,
      wordsCollected: 0,
      listeningMs: 0,
      timeSavedMs: timeSavedMs,
      activeReadingDays: 0,
      currentCourse: null,
    );

    test('zero saved shows no line — positive framing, never a zero', () {
      expect(builtLines(built()), isEmpty);
    });

    test('under an hour shows minutes saved', () {
      expect(builtLines(built(timeSavedMs: 45 * 60000)), ['45 minutes saved']);
    });

    test('a single minute is singular', () {
      expect(builtLines(built(timeSavedMs: 60000)), ['1 minute saved']);
    });

    test('an even number of hours shows "hours saved", no minutes', () {
      expect(builtLines(built(timeSavedMs: 2 * 60 * 60000)), ['2 hours saved']);
    });

    test('a single hour is singular', () {
      expect(builtLines(built(timeSavedMs: 60 * 60000)), ['1 hour saved']);
    });

    test('hours plus minutes uses the h/min form', () {
      expect(builtLines(built(timeSavedMs: (2 * 60 + 15) * 60000)), [
        '2 h 15 min saved',
      ]);
    });
  });

  testWidgets('rename flows through to the database and the card', (
    tester,
  ) async {
    final (ada, _) = await seed();
    await pumpDashboard(tester);

    await tester.tap(find.byKey(Key('rename-$ada')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('rename-field')),
      'Ada Lovelace',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Ada Lovelace'), findsOneWidget);
    expect((await db.profilesDao.all()).first.name, 'Ada Lovelace');
  });

  testWidgets('remove asks first, then removes the reader completely', (
    tester,
  ) async {
    final (ada, grace) = await seed();
    await pumpDashboard(tester);

    await tester.tap(find.byKey(Key('remove-$ada')));
    await tester.pumpAndSettle();
    // The confirm dialog names what goes with the profile.
    expect(find.textContaining('library'), findsWidgets);

    await tester.tap(find.text('Remove profile'));
    await tester.pumpAndSettle();

    expect(find.text('Ada'), findsNothing);
    expect(find.text('Grace'), findsOneWidget);
    expect([for (final p in await db.profilesDao.all()) p.id], [grace]);
    expect(await db.spineDao.worksOf(ada), isEmpty);
  });

  testWidgets('household PIN: set, change, remove — the current-PIN law', (
    tester,
  ) async {
    await seed();
    // Tall surface: the PIN section lives below the profile cards.
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpDashboard(tester);

    expect(find.text('No PIN is set.'), findsOneWidget);

    // Set — the dialog tells the honest no-recovery truth.
    await tester.tap(find.text('Set a PIN'));
    await tester.pumpAndSettle();
    expect(find.textContaining('no recovery'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('pin-new')), '1234');
    await tester.enterText(find.byKey(const Key('pin-confirm')), '1234');
    await tester.tap(find.text('Set PIN'));
    await tester.pumpAndSettle();
    expect(await pin.isSet, isTrue);
    expect(find.text('Change PIN'), findsOneWidget);

    // Change — a wrong current PIN changes nothing.
    await tester.tap(find.text('Change PIN'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('pin-current')), '9999');
    await tester.enterText(find.byKey(const Key('pin-new')), '5678');
    await tester.enterText(find.byKey(const Key('pin-confirm')), '5678');
    await tester.tap(find.text('Change'));
    await tester.pumpAndSettle();
    expect(find.textContaining("not the current PIN"), findsOneWidget);
    expect(await pin.verify('1234'), isTrue);
    await tester.enterText(find.byKey(const Key('pin-current')), '1234');
    await tester.tap(find.text('Change'));
    await tester.pumpAndSettle();
    expect(await pin.verify('5678'), isTrue);

    // Remove — with the current PIN only. The dialog's confirm is the
    // FilledButton; the section behind it holds the TextButton of the
    // same name.
    await tester.tap(find.widgetWithText(TextButton, 'Remove PIN'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('pin-current')), '5678');
    await tester.tap(find.widgetWithText(FilledButton, 'Remove PIN'));
    await tester.pumpAndSettle();
    expect(await pin.isSet, isFalse);
    expect(find.text('No PIN is set.'), findsOneWidget);
  });

  testWidgets('renders at 320dp and 2x text scale without overflow', (
    tester,
  ) async {
    await seed();
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpDashboard(tester, textScale: 2.0);

    expect(tester.takeException(), isNull);
    expect(find.text('Ada'), findsOneWidget);
  });
}
