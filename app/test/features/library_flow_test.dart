import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/main.dart';
import '../support/pick_reader.dart';

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

  testWidgets('first run opens into the inviting empty library, with no '
      'name to type first (operator ruling 48)', (tester) async {
    await pumpApp(tester);

    expect(find.text('Who’s reading?'), findsNothing);
    // The calm empty state invites intake (ADR-0003: no guilt, an offer).
    expect(find.text('Nothing on the trellis yet.'), findsOneWidget);
    expect(find.text('Paste text'), findsOneWidget);
    expect(find.text('Import an EPUB'), findsOneWidget);

    final created = await db.profilesDao.all();
    expect(created.single.name, 'Reader');
  });

  testWidgets('a cold launch reopens the last reader; a stale one falls back '
      'to the picker', (tester) async {
    await db.profilesDao.create('Ada');
    final blaise = await db.profilesDao.create('Blaise');
    await pumpApp(tester);
    await pickReader(tester, 'Blaise');
    expect(await db.deviceSettingsDao.lastProfileId(), blaise);

    // Relaunch: straight into Blaise's library, no tollgate (audit rank 5).
    await tester.pumpWidget(const SizedBox());
    await pumpApp(tester);
    expect(find.text('Who’s reading?'), findsNothing);
    await tester.tap(find.byKey(const Key('library-more')));
    await tester.pumpAndSettle();
    expect(find.text('Switch reader (Blaise)'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    // Blaise removed elsewhere (or a restore replaced everyone): the
    // remembered id is stale, and two readers remain a real choice.
    await db.householdDao.deleteProfileCascade(blaise);
    await db.profilesDao.create('Cy');
    await tester.pumpWidget(const SizedBox());
    await pumpApp(tester);
    expect(find.text('Who’s reading?'), findsOneWidget);
  });

  testWidgets('adding a reader: the button is live only once there is a name',
      (tester) async {
    await db.profilesDao.create('Ada');
    await db.profilesDao.create('Blaise');
    await pumpApp(tester);
    await tester.tap(find.text('Add a reader'));
    await tester.pumpAndSettle();

    FilledButton add() => tester.widget<FilledButton>(
        find.ancestor(of: find.text('Add reader'), matching: find.byType(FilledButton)));
    expect(add().onPressed, isNull);
    expect(find.text('Type a name to add this reader.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('profile-name')), 'Cy');
    await tester.pump();
    expect(add().onPressed, isNotNull);
    await tester.tap(find.text('Add reader'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing on the trellis yet.'), findsOneWidget);
  });

  testWidgets('paste intake: parsed text appears as a work with its title',
      (tester) async {
    await pumpApp(tester); // a first launch opens the new reader's Library

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
    await pumpApp(tester); // a first launch opens the new reader's Library

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
    await pickReader(tester, 'Ada');

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

    // Remove Second: a deliberate menu choice, so no dialog. It leaves the
    // list at once and a lasting Undo brings it back.
    await tester.tap(find.byKey(Key('work-menu-$second')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Second'), findsNothing);
    expect(find.text("Removed 'Second'"), findsOneWidget);
    await tester.pump(const Duration(hours: 1));
    expect(find.text('Undo'), findsOneWidget, reason: 'Undo never expires');
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('Second'), findsOneWidget);
    expect(await db.spineDao.worksOf(profileId), hasLength(2));

    // Removed again and let go (Dismiss): now it is gone for good.
    await tester.tap(find.byKey(Key('work-menu-$second')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.text('Second'), findsNothing);
    expect((await db.spineDao.worksOf(profileId)).single.title, 'First');
  });

  testWidgets('the profile switcher returns to the picker', (tester) async {
    await db.profilesDao.create('Ada');
    await db.profilesDao.create('Blaise');

    await pumpApp(tester);
    expect(find.text('Who’s reading?'), findsOneWidget);
    await pickReader(tester, 'Blaise');
    expect(find.text('Nothing on the trellis yet.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('library-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile-switcher')));
    await tester.pumpAndSettle();
    expect(find.text('Who’s reading?'), findsOneWidget);
    expect(find.text('Ada'), findsOneWidget);
  });

  group('Campaign 9 Phase 4: library rows gain a date subtitle', () {
    testWidgets('a book (non-episode work) shows its added date, from '
        'firstSeenEpochDay', (tester) async {
      final profileId = await db.profilesDao.create('Ada');
      final epochDay =
          DateTime(2026, 8, 5).millisecondsSinceEpoch ~/
              Duration.millisecondsPerDay;
      await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'book',
          title: 'A Book',
          persistence: 'work',
          firstSeenEpochDay: epochDay);

      await pumpApp(tester);
      await pickReader(tester, 'Ada');

      expect(find.text('5 Aug'), findsOneWidget);
    });

    testWidgets('a kept episode shows its PUBLISHED date, not the day it '
        'was kept', (tester) async {
      final profileId = await db.profilesDao.create('Ada');
      final feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://a/f');
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: 'An episode',
          persistence: 'work',
          // Added to the library today (or whenever) — the published date
          // below must win, since that is what a listener actually cares
          // about for an episode.
          firstSeenEpochDay:
              DateTime.now().millisecondsSinceEpoch ~/
                  Duration.millisecondsPerDay);
      await db.feedsDao.insertEpisode(
          workId: workId,
          feedId: feedId,
          guid: 'g',
          enclosureUrl: 'https://a/1.mp3',
          publishedAtMs: DateTime(2026, 1, 1).millisecondsSinceEpoch);

      await pumpApp(tester);
      await pickReader(tester, 'Ada');

      expect(find.text('1 Jan'), findsOneWidget);
    });
  });
}
