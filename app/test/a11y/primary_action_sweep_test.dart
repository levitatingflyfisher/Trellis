import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oh_fleet_conformance/oh_fleet_conformance.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/backup/backup_screen.dart';
import 'package:trellis/features/intake/url_intake.dart';
import 'package:trellis/features/library/library_screen.dart';
import 'package:trellis/features/reader/reader_screen.dart';
import 'package:trellis/features/river/river_screen.dart';
import 'package:trellis/features/study/courses_screen.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/scripted_fetcher.dart';

/// Roadmap item 24 / C5-primaryScreens: on every screen that owns a primary
/// action, that action must be reachable at 360 dp with the font one notch
/// up (1.3x, an ordinary Android setting), and nothing may overflow at
/// 320 dp x 3.0. The screens named here are listed in the fleet config.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> seedReader({bool withWork = false}) async {
    if ((await db.profilesDao.all()).isNotEmpty) return;
    final id = await db.profilesDao.create('Adalheidis Winterbourne');
    if (withWork) {
      final w = await db.spineDao.insertWork(
          profileId: id,
          kind: 'note',
          title: 'A Rather Longer Title Than Any Row Would Prefer',
          persistence: 'work',
          firstSeenEpochDay: 100);
      await db.spineDao.insertSegments(w, const [
        (idx: 0, kind: 'prose', text: 'One two three four five six.')
      ]);
    }
  }

  Future<void> app(WidgetTester tester, {String? tab}) async {
    await tester.pumpWidget(TrellisApp(
        db: db,
        fetcher: ScriptedFetcher((u, h) => textResponse('')),
        createPlayer: () => FakeEpisodePlayer()));
    await tester.pumpAndSettle();
    if (tab != null) {
      await tester.tap(find.descendant(
          of: find.byType(NavigationBar), matching: find.text(tab)));
      await tester.pumpAndSettle();
    }
  }

  testWidgets('LibraryScreen: Add', (tester) async {
    await seedReader(withWork: true);
    await runPrimaryActionSweep(tester,
        pumpScreen: () async {
          await app(tester);
          expect(find.byType(LibraryScreen), findsOneWidget);
        },
        primaryAction: find.widgetWithText(FloatingActionButton, 'Add'));
  });

  testWidgets('LibraryScreen (empty): Paste text', (tester) async {
    await seedReader();
    await runPrimaryActionSweep(tester,
        pumpScreen: () async {
          await app(tester);
          expect(find.byType(LibraryScreen), findsOneWidget);
        },
        primaryAction: find.text('Paste text'));
  });

  testWidgets('RiverScreen (empty): Follow a feed', (tester) async {
    await seedReader();
    await runPrimaryActionSweep(tester,
        pumpScreen: () async {
          await app(tester, tab: 'Inbox');
          expect(find.byType(RiverScreen), findsOneWidget);
        },
        primaryAction: find.text('Follow a feed'));
  });

  testWidgets('CoursesScreen (empty): Paste a course', (tester) async {
    await seedReader();
    await runPrimaryActionSweep(tester,
        pumpScreen: () async {
          await app(tester, tab: 'Courses');
          expect(find.byType(CoursesScreen), findsOneWidget);
        },
        primaryAction: find.text('Paste a course'));
  });

  testWidgets('ReaderScreen: Play', (tester) async {
    await seedReader(withWork: true);
    await runPrimaryActionSweep(tester, pumpScreen: () async {
      await app(tester);
      await tester.tap(find.text('A Rather Longer Title Than Any Row Would Prefer'));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScreen), findsOneWidget);
    }, primaryAction: find.byKey(const Key('play-toggle')));
  });

  testWidgets('UrlIntakeScreen: Fetch article', (tester) async {
    await seedReader();
    final profile = (await db.profilesDao.all()).single;
    await runPrimaryActionSweep(tester,
        pumpScreen: () async {
          await tester.pumpWidget(MaterialApp(
              home: UrlIntakeScreen(
                  db: db,
                  profileId: profile.id,
                  fetcher: ScriptedFetcher((u, h) => textResponse('')),
                  webTier: true)));
          await tester.pumpAndSettle();
        },
        primaryAction: find.byKey(const Key('url-intake-fetch')));
  });

  testWidgets('BackupScreen: Make one (a recovery phrase)', (tester) async {
    await seedReader();
    final profile = (await db.profilesDao.all()).single;
    await runPrimaryActionSweep(tester,
        pumpScreen: () async {
          await tester.pumpWidget(
              MaterialApp(home: BackupScreen(db: db, profile: profile)));
          await tester.pumpAndSettle();
        },
        primaryAction: find.byKey(const Key('backup-new-phrase')));
  });
}
