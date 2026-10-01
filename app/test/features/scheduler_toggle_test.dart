import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/study/courses_screen.dart';

/// The study crown's toggle: a calm per-profile setting, default "FSRS",
/// "Classic (SM-2)" one tap away — following the reader's existing settings-escape
/// idiom (a PopupMenuButton + CheckedPopupMenuItem, ADR-0006's pattern) so
/// this doesn't invent a second settings surface convention. Switching TO
/// FSRS explains it and says progress carries over before it takes effect;
/// switching to Classic is instant (no dialog, ADR-0009).
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<Profile> seedProfile() async {
    final id = await db.profilesDao.create('Ada');
    return (await db.profilesDao.all()).firstWhere((p) => p.id == id);
  }

  Future<void> pumpCourses(WidgetTester tester, Profile profile) async {
    await tester.pumpWidget(
        MaterialApp(home: CoursesScreen(db: db, profile: profile)));
    await tester.pumpAndSettle();
  }

  testWidgets('defaults to checked (FSRS) for a fresh profile',
      (tester) async {
    final profile = await seedProfile();
    expect(await db.profilesDao.scheduler(profile.id), 'fsrs');
    await pumpCourses(tester, profile);

    await tester.tap(find.byKey(const Key('study-settings')));
    await tester.pumpAndSettle();

    final item = tester.widget<CheckedPopupMenuItem<String>>(
        find.byKey(const Key('scheduler-toggle')));
    expect(item.checked, isTrue);
    expect(find.textContaining('beta'), findsNothing);
  });

  testWidgets(
      'switching to FSRS explains it, and says progress carries over, '
      'before it takes effect', (tester) async {
    final profile = await seedProfile();
    await db.profilesDao.setScheduler(profile.id, 'classic');
    await pumpCourses(tester, profile);

    await tester.tap(find.byKey(const Key('study-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scheduler-toggle')));
    await tester.pumpAndSettle();

    expect(find.textContaining('FSRS'), findsWidgets);
    expect(find.textContaining('progress carries over'), findsOneWidget,
        reason: 'switching keeps progress both ways, and the dialog says so');
    // Not yet applied — the dialog is a confirmation, not a fait accompli.
    expect(await db.profilesDao.scheduler(profile.id), 'classic');
  });

  testWidgets('confirming the dialog actually flips the setting',
      (tester) async {
    final profile = await seedProfile();
    await db.profilesDao.setScheduler(profile.id, 'classic');
    await pumpCourses(tester, profile);

    await tester.tap(find.byKey(const Key('study-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scheduler-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use FSRS'));
    await tester.pumpAndSettle();

    expect(await db.profilesDao.scheduler(profile.id), 'fsrs');

    await tester.tap(find.byKey(const Key('study-settings')));
    await tester.pumpAndSettle();
    final item = tester.widget<CheckedPopupMenuItem<String>>(
        find.byKey(const Key('scheduler-toggle')));
    expect(item.checked, isTrue);
  });

  testWidgets('declining the dialog leaves Classic in place', (tester) async {
    final profile = await seedProfile();
    await db.profilesDao.setScheduler(profile.id, 'classic');
    await pumpCourses(tester, profile);

    await tester.tap(find.byKey(const Key('study-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scheduler-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    expect(await db.profilesDao.scheduler(profile.id), 'classic');
  });

  testWidgets(
      'switching back to Classic is instant — no dialog, nothing to warn '
      'about in that direction', (tester) async {
    final profile = await seedProfile();
    await db.profilesDao.setScheduler(profile.id, 'fsrs');
    await pumpCourses(tester, profile);

    await tester.tap(find.byKey(const Key('study-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scheduler-toggle')));
    await tester.pumpAndSettle();

    expect(find.text('Use FSRS'), findsNothing,
        reason: 'no confirmation dialog for the safe direction');
    expect(await db.profilesDao.scheduler(profile.id), 'classic');
  });
}
