import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart' hide Alignment;
import 'package:trellis/main.dart';

/// Phase 2 (Campaign 5) built the filter and its saved-view persistence.
/// Campaign 9 Phase 1 modernized the FILTERING half into a live modal
/// bottom sheet (the device-test user called the old pushed-screen-with-
/// an-Apply-button flow "dated") — every control here applies immediately
/// to the list behind it, no separate Apply step. Saved-view management
/// (save/rename/delete/reorder) stays a pushed screen, reached through a
/// door inside the sheet.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<int> seedProfile() => db.profilesDao.create('Ada');

  Future<int> seedWork(
      {required int profileId,
      required String kind,
      required String title,
      bool pinned = false}) async {
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: kind,
        title: title,
        persistence: 'work',
        firstSeenEpochDay: 100);
    if (pinned) await db.spineDao.setPinned(id, true);
    return id;
  }

  /// Profile and works are seeded directly on [db] BEFORE this runs — the
  /// picker (not the create screen, since a profile already exists) is
  /// what a second cold pump of this app always shows.
  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(TrellisApp(db: db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle();
  }

  testWidgets('the filter icon opens the live filter sheet', (tester) async {
    final profileId = await seedProfile();
    await seedWork(profileId: profileId, kind: 'book', title: 'A book');
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('open-filter')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('filter-search')), findsOneWidget);
  });

  testWidgets(
      'toggling a type chip narrows the library list immediately — no '
      'Apply step', (tester) async {
    final profileId = await seedProfile();
    await seedWork(profileId: profileId, kind: 'book', title: 'A book');
    await seedWork(profileId: profileId, kind: 'article', title: 'An article');
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('open-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter-type-book')));
    await tester.pump();

    expect(find.text('A book'), findsOneWidget);
    expect(find.text('An article'), findsNothing);
  });

  testWidgets('a pinned-only filter keeps only pinned works, live',
      (tester) async {
    final profileId = await seedProfile();
    await seedWork(
        profileId: profileId, kind: 'book', title: 'Pinned', pinned: true);
    await seedWork(profileId: profileId, kind: 'book', title: 'Not pinned');
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('open-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter-pinned-only')));
    await tester.pump();

    expect(find.text('Pinned'), findsOneWidget);
    expect(find.text('Not pinned'), findsNothing);
  });

  testWidgets('search narrows by title, case-insensitively, live',
      (tester) async {
    final profileId = await seedProfile();
    await seedWork(profileId: profileId, kind: 'book', title: 'Aurora season');
    await seedWork(profileId: profileId, kind: 'book', title: 'Perseid peak');
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('open-filter')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('filter-search')), 'aurora');
    await tester.pump();

    expect(find.text('Aurora season'), findsOneWidget);
    expect(find.text('Perseid peak'), findsNothing);
  });

  testWidgets('"Clear all" inside the sheet resets every control live',
      (tester) async {
    final profileId = await seedProfile();
    await seedWork(profileId: profileId, kind: 'book', title: 'A book');
    await seedWork(profileId: profileId, kind: 'article', title: 'An article');
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('open-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter-type-book')));
    await tester.pump();
    expect(find.text('An article'), findsNothing);

    await tester.tap(find.byKey(const Key('filter-clear-all')));
    await tester.pump();
    expect(find.text('An article'), findsOneWidget);
    expect(find.text('A book'), findsOneWidget);
  });

  testWidgets(
      "the AppBar icon toggles to a one-tap clear once a filter is live, "
      'even after the sheet is dismissed', (tester) async {
    final profileId = await seedProfile();
    await seedWork(profileId: profileId, kind: 'book', title: 'A book');
    await seedWork(profileId: profileId, kind: 'article', title: 'An article');
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('open-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter-type-book')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('filter-sheet-done')));
    await tester.pumpAndSettle();

    expect(find.text('An article'), findsNothing);

    await tester.tap(find.byKey(const Key('open-filter')));
    await tester.pumpAndSettle();
    expect(find.text('An article'), findsOneWidget);
    expect(find.text('A book'), findsOneWidget);
  });

  testWidgets(
      'saving the current live filter as a view (via "Saved views" inside '
      'the sheet) creates a chip; tapping it re-applies the filter',
      (tester) async {
    final profileId = await seedProfile();
    await seedWork(profileId: profileId, kind: 'book', title: 'A book');
    await seedWork(profileId: profileId, kind: 'article', title: 'An article');
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('open-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter-type-book')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('open-saved-views')));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const Key('filter-view-name')), 'Books only');
    await tester.tap(find.byKey(const Key('filter-save-view')));
    await tester.pumpAndSettle();

    // Saving applied it too, and popped back to the library.
    expect(find.text('A book'), findsOneWidget);
    expect(find.text('An article'), findsNothing);
    expect(find.byKey(const Key('saved-view-Books only')), findsOneWidget);

    // The AppBar icon toggles to a one-tap clear while a filter is active.
    await tester.tap(find.byKey(const Key('open-filter')));
    await tester.pumpAndSettle();
    expect(find.text('An article'), findsOneWidget);
    expect(find.text('A book'), findsOneWidget);

    // Tapping the chip re-applies the saved view.
    await tester.tap(find.byKey(const Key('saved-view-Books only')));
    await tester.pumpAndSettle();
    expect(find.text('A book'), findsOneWidget);
    expect(find.text('An article'), findsNothing);
  });

  testWidgets(
      'deleting a saved view from the management screen removes its chip',
      (tester) async {
    final profileId = await seedProfile();
    await seedWork(profileId: profileId, kind: 'book', title: 'A book');
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('open-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-saved-views')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('filter-view-name')), 'Everything');
    await tester.tap(find.byKey(const Key('filter-save-view')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('saved-view-Everything')), findsOneWidget);

    await tester.tap(find.byKey(const Key('open-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-saved-views')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete-view-Everything')));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('saved-view-Everything')), findsNothing);
  });
}
