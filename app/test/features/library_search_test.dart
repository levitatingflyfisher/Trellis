import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart' hide Alignment;
import 'package:trellis/features/search/search_entry.dart';
import 'package:trellis/features/search/search_screen.dart';
import 'package:trellis/main.dart';
import '../support/pick_reader.dart';
import '../support/tabs.dart';

/// Owner, 12 Nov: "library filter search didn't seem to work idk cuz the
/// search bar on Latest works great". Reproduced: the words went into a
/// field inside the Filter sheet, and the sheet covered the list they
/// filtered, so nothing on screen answered them (and tapping the bar's
/// Filter again threw them away). The Library now has Latest's own search
/// bar and search screen, the same code, kept to what you keep.
void main() {
  late AppDatabase db;
  late int profileId;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
  });
  tearDown(() => db.close());

  Future<int> work(String title, {String persistence = 'work'}) =>
      db.spineDao.insertWork(
          profileId: profileId,
          kind: 'book',
          title: title,
          persistence: persistence,
          firstSeenEpochDay: 100);

  Future<void> pumpLibrary(WidgetTester tester) async {
    await tester.pumpWidget(TrellisApp(db: db));
    await tester.pumpAndSettle();
    await pickReader(tester, 'Ada');
    await toTab(tester, 'Library');
  }

  Future<void> search(WidgetTester tester, String words) async {
    await tester.tap(find.byKey(const Key('library-search')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('search-field')), words);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
  }

  testWidgets('a word typed into the Library’s search shows its match on '
      'screen as it is typed', (tester) async {
    await work('Aurora season');
    await work('Perseid peak');
    await pumpLibrary(tester);

    await search(tester, 'aurora');

    expect(find.text('Aurora season').hitTestable(), findsOneWidget,
        reason: 'the match is on screen where it can be seen and tapped');
    expect(find.text('Perseid peak'), findsNothing);
  });

  testWidgets('the same bar and the same search screen as Latest’s, kept to '
      'what you keep', (tester) async {
    await work('Aurora kept');
    await work('Aurora passing', persistence: 'ephemeron');
    await pumpLibrary(tester);

    expect(
        find.descendant(
            of: find.byKey(const Key('library-search')),
            matching: find.byType(SearchEntry)),
        findsOneWidget);
    await search(tester, 'aurora');

    expect(find.byType(SearchScreen), findsOneWidget);
    expect(find.text('Aurora kept'), findsOneWidget);
    expect(find.text('Aurora passing'), findsNothing,
        reason: 'the Library holds only what was kept');
    expect(find.byKey(const Key('search-shows-heading')), findsNothing,
        reason: 'shows are not kept things; Subscriptions finds them');
  });

  testWidgets('before a word is typed it says what it searches, not '
      'History', (tester) async {
    await work('Aurora season');
    await pumpLibrary(tester);
    await tester.tap(find.byKey(const Key('library-search')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('search-history-heading')), findsNothing);
    expect(find.byKey(const Key('search-library-hint')), findsOneWidget);
  });

  testWidgets('the Filter sheet no longer holds a second search field',
      (tester) async {
    await work('Aurora season');
    await pumpLibrary(tester);
    await tester.tap(find.byKey(const Key('open-filter')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('filter-search')), findsNothing);
  });
}
