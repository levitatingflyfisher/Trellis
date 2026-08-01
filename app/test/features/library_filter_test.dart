import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart' hide Alignment;
import 'package:trellis/main.dart';

/// Phase 2 (Campaign 5): a small query model over the library, a filter
/// screen to build one, and saved views as chips on the library surface —
/// LibraryScreen had NO search/sort/filter of any kind before this
/// campaign (the feature-matrix's "Library: debounced search, sorts,
/// filters…" line was an overclaim this campaign also corrects), so
/// there is no prior filter surface to extend — this builds the filter
/// AND its saved-view persistence together.
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

  testWidgets('the filter icon opens the filter screen', (tester) async {
    final profileId = await seedProfile();
    await seedWork(profileId: profileId, kind: 'book', title: 'A book');
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('open-filter')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('filter-search')), findsOneWidget);
  });

  testWidgets('applying a type filter narrows the library list',
      (tester) async {
    final profileId = await seedProfile();
    await seedWork(profileId: profileId, kind: 'book', title: 'A book');
    await seedWork(profileId: profileId, kind: 'article', title: 'An article');
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('open-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter-type-book')));
    await tester.ensureVisible(find.byKey(const Key('filter-apply')));
    await tester.tap(find.byKey(const Key('filter-apply')));
    await tester.pumpAndSettle();

    expect(find.text('A book'), findsOneWidget);
    expect(find.text('An article'), findsNothing);
  });

  testWidgets('saving the current filter creates a chip; tapping it '
      're-applies the filter; the icon clears it', (tester) async {
    final profileId = await seedProfile();
    await seedWork(profileId: profileId, kind: 'book', title: 'A book');
    await seedWork(profileId: profileId, kind: 'article', title: 'An article');
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('open-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter-type-book')));
    await tester.ensureVisible(find.byKey(const Key('filter-view-name')));
    await tester.enterText(
        find.byKey(const Key('filter-view-name')), 'Books only');
    await tester.ensureVisible(find.byKey(const Key('filter-save-view')));
    await tester.tap(find.byKey(const Key('filter-save-view')));
    await tester.pumpAndSettle();

    // Saving applied it too.
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

  testWidgets('deleting a saved view from the filter screen removes its chip',
      (tester) async {
    final profileId = await seedProfile();
    await seedWork(profileId: profileId, kind: 'book', title: 'A book');
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('open-filter')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('filter-view-name')));
    await tester.enterText(
        find.byKey(const Key('filter-view-name')), 'Everything');
    await tester.ensureVisible(find.byKey(const Key('filter-save-view')));
    await tester.tap(find.byKey(const Key('filter-save-view')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('saved-view-Everything')), findsOneWidget);

    await tester.tap(find.byKey(const Key('open-filter')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('delete-view-Everything')));
    await tester.tap(find.byKey(const Key('delete-view-Everything')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('filter-apply')));
    await tester.tap(find.byKey(const Key('filter-apply')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('saved-view-Everything')), findsNothing);
  });

  testWidgets('a pinned-only filter keeps only pinned works', (tester) async {
    final profileId = await seedProfile();
    await seedWork(
        profileId: profileId, kind: 'book', title: 'Pinned', pinned: true);
    await seedWork(profileId: profileId, kind: 'book', title: 'Not pinned');
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('open-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter-pinned-only')));
    await tester.ensureVisible(find.byKey(const Key('filter-apply')));
    await tester.tap(find.byKey(const Key('filter-apply')));
    await tester.pumpAndSettle();

    expect(find.text('Pinned'), findsOneWidget);
    expect(find.text('Not pinned'), findsNothing);
  });

  testWidgets('search narrows by title, case-insensitively', (tester) async {
    final profileId = await seedProfile();
    await seedWork(profileId: profileId, kind: 'book', title: 'Aurora season');
    await seedWork(profileId: profileId, kind: 'book', title: 'Perseid peak');
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('open-filter')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('filter-search')), 'aurora');
    await tester.ensureVisible(find.byKey(const Key('filter-apply')));
    await tester.tap(find.byKey(const Key('filter-apply')));
    await tester.pumpAndSettle();

    expect(find.text('Aurora season'), findsOneWidget);
    expect(find.text('Perseid peak'), findsNothing);
  });
}
