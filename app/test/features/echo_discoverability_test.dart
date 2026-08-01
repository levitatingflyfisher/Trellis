import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/study/courses_screen.dart';

/// Campaign 9 Phase 1 — user: "the sparkles meaning echo? what's an echo?"
/// Two problems in one icon: the daily-review chip and the Echo door both
/// used `Icons.auto_awesome_outlined`, so the sparkles glyph didn't even
/// point at one meaning — and Echo carried no word at all, just the glyph.
void main() {
  Future<Profile> seedProfile(AppDatabase db) async {
    final id = await db.profilesDao.create('Ada');
    return (await db.profilesDao.all()).firstWhere((p) => p.id == id);
  }

  testWidgets(
      'the daily-review chip and the Echo door no longer share an icon',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final profile = await seedProfile(db);
    await db.ledgerDao.add(profileId: profile.id, word: 'saudade', nowMs: 1);

    await tester.pumpWidget(MaterialApp(
        home: CoursesScreen(db: db, profile: profile, onOpenEcho: () {})));
    await tester.pumpAndSettle();

    final chipIcon = tester
        .widget<Icon>(find.descendant(
            of: find.byKey(const Key('daily-review-chip')),
            matching: find.byType(Icon).first))
        .icon;
    expect(chipIcon, Icons.today_outlined,
        reason: 'distinct from Echo — the sparkles glyph should mean one '
            'thing');
  });

  testWidgets(
      'the Echo door names itself — no bare sparkles icon with no word',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final profile = await seedProfile(db);

    // Worst case for AppBar width: every optional action wired, at the
    // narrowest supported width and largest text scale (house
    // accessibility-overflow law).
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);

    await tester.pumpWidget(MaterialApp(
        home: CoursesScreen(
            db: db,
            profile: profile,
            onOpenBackup: () {},
            onOpenEcho: () {})));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: 'no RenderFlex overflow with every AppBar action wired at '
            '320dp/2x');
    expect(find.byKey(const Key('open-echo')), findsOneWidget);
    expect(find.text('Echo'), findsOneWidget,
        reason: 'the door names itself — a word, not just a glyph');
  });
}
