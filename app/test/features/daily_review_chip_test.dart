import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/study/courses_screen.dart';
import 'package:trellis/features/study/daily_review_screen.dart';

/// The study crown's home surface: a quiet due chip for daily review,
/// separate from any course's own due count (which lives on its map
/// screen's FAB). "Quiet" here means it does not appear at all when there
/// is nothing due — no permanent zero, no nag (ADR-0003 law 5).
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  testWidgets('hidden when nothing is due — quiet means quiet', (tester) async {
    final profile = await _seedProfile(db);
    await tester.pumpWidget(MaterialApp(
        home: CoursesScreen(db: db, profile: profile)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('daily-review-chip')), findsNothing);
  });

  testWidgets('shows the due count and opens the daily review screen',
      (tester) async {
    final profile = await _seedProfile(db);
    await db.ledgerDao.add(profileId: profile.id, word: 'saudade', nowMs: 1);

    await tester.pumpWidget(MaterialApp(
        home: CoursesScreen(db: db, profile: profile)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('daily-review-chip')), findsOneWidget);
    expect(find.textContaining('1'), findsWidgets);

    await tester.tap(find.byKey(const Key('daily-review-chip')));
    await tester.pumpAndSettle();

    expect(find.byType(DailyReviewScreen), findsOneWidget);
  });
}

Future<Profile> _seedProfile(AppDatabase db) async {
  final id = await db.profilesDao.create('Ada');
  return (await db.profilesDao.all()).firstWhere((p) => p.id == id);
}
