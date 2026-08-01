import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/main.dart';

/// The alpha loop's front half: first-run profile creation into a calm empty
/// library, paste intake, and the library's pin/delete hands.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(TrellisApp(db: db));
    await tester.pumpAndSettle();
  }

  testWidgets('first run: create a profile, land in the inviting empty library',
      (tester) async {
    await pumpApp(tester);

    expect(find.text("Who's reading?"), findsOneWidget);
    await tester.enterText(find.byKey(const Key('profile-name')), 'Ada');
    await tester.tap(find.text('Start reading'));
    await tester.pumpAndSettle();

    // The calm empty state invites intake (ADR-0003: no guilt, an offer).
    expect(find.text('Nothing on the trellis yet.'), findsOneWidget);
    expect(find.text('Paste text'), findsOneWidget);
    expect(find.text('Import an EPUB'), findsOneWidget);

    final created = await db.profilesDao.all();
    expect(created.single.name, 'Ada');
  });

  testWidgets('paste intake: parsed text appears as a work with its title',
      (tester) async {
    await pumpApp(tester);
    await tester.enterText(find.byKey(const Key('profile-name')), 'Ada');
    await tester.tap(find.text('Start reading'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Paste text'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('paste-title')), 'Rain');
    await tester.enterText(find.byKey(const Key('paste-text')),
        'The rain fell all night.\n\nBy morning the river had risen.');
    await tester.tap(find.text('Add to library'));
    await tester.pumpAndSettle();

    expect(find.text('Rain'), findsOneWidget);
    expect(find.text('Nothing on the trellis yet.'), findsNothing);

    // The parse really ran: two paragraphs → two prose segments.
    final work =
        (await db.spineDao.worksOf((await db.profilesDao.all()).single.id))
            .single;
    expect(work.title, 'Rain');
    expect(await db.spineDao.segmentCount(work.id), 2);
  });

  testWidgets('a pasted work with no title keeps the parser-detected title',
      (tester) async {
    await pumpApp(tester);
    await tester.enterText(find.byKey(const Key('profile-name')), 'Ada');
    await tester.tap(find.text('Start reading'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Paste text'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('paste-text')), 'One quiet paragraph.');
    await tester.tap(find.text('Add to library'));
    await tester.pumpAndSettle();

    expect(find.text('Text'), findsOneWidget,
        reason: "donor parseTextFile falls back to 'Text'");
  });

  testWidgets('pin floats a work to the top; delete removes it after confirm',
      (tester) async {
    final profileId = await db.profilesDao.create('Ada');
    final first = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'note',
        title: 'First',
        persistence: 'work',
        firstSeenEpochDay: 100);
    final second = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'note',
        title: 'Second',
        persistence: 'work',
        firstSeenEpochDay: 100);

    await pumpApp(tester);
    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle();

    // Newest first by default: Second above First.
    var firstY = tester.getTopLeft(find.text('First')).dy;
    var secondY = tester.getTopLeft(find.text('Second')).dy;
    expect(secondY, lessThan(firstY));

    // Pin First → it floats above Second.
    await tester.tap(find.byKey(Key('work-menu-$first')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pin'));
    await tester.pumpAndSettle();
    firstY = tester.getTopLeft(find.text('First')).dy;
    secondY = tester.getTopLeft(find.text('Second')).dy;
    expect(firstY, lessThan(secondY));

    // Delete Second, confirming calmly.
    await tester.tap(find.byKey(Key('work-menu-$second')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from library'));
    await tester.pumpAndSettle();

    expect(find.text('Second'), findsNothing);
    expect((await db.spineDao.worksOf(profileId)).single.title, 'First');
  });

  testWidgets('the profile switcher returns to the picker', (tester) async {
    await db.profilesDao.create('Ada');
    await db.profilesDao.create('Blaise');

    await pumpApp(tester);
    expect(find.text("Who's reading?"), findsOneWidget);
    await tester.tap(find.text('Blaise'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing on the trellis yet.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('profile-switcher')));
    await tester.pumpAndSettle();
    expect(find.text("Who's reading?"), findsOneWidget);
    expect(find.text('Ada'), findsOneWidget);
  });
}
