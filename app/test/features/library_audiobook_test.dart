// Campaign 7 ("audiobooks are a door", ADR-0013): LibraryScreen's audiobook
// door, tile progress states, and tap-to-play routing — driven directly
// against LibraryScreen (not through TrellisApp/home_shell), because the
// real shell wires FilePickerAudiobookGateway, which touches a platform
// channel no unit test host has. Every test here injects its own
// onImportAudiobook/onDeleteAudiobookFiles closures instead, the same way
// library_flow_test.dart's siblings inject a ScriptedFetcher rather than a
// real one.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/library/library_screen.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/reader/reader_screen.dart';

import '../support/fake_player.dart';

void main() {
  late AppDatabase db;
  late int profileId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
  });

  tearDown(() async => db.close());

  Future<Profile> profile() async =>
      (await db.profilesDao.all()).firstWhere((p) => p.id == profileId);

  Future<void> pump(
    WidgetTester tester, {
    Future<int?> Function(BuildContext)? onImportAudiobook,
    void Function(int workId)? onDeleteAudiobookFiles,
    PlayerController? player,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: LibraryScreen(
        db: db,
        profile: await profile(),
        onSwitchProfile: () {},
        onImportAudiobook: onImportAudiobook,
        onDeleteAudiobookFiles: onDeleteAudiobookFiles,
        player: player,
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<Work> seedAudiobook({
    String title = 'Trail Book',
    List<String> paths = const ['/a/0.mp3', '/a/1.mp3', '/a/2.mp3'],
  }) async {
    final workId = await db.spineDao.insertWork(
      profileId: profileId,
      kind: 'audiobook',
      title: title,
      persistence: 'work',
      firstSeenEpochDay: 100,
    );
    await db.audiobooksDao.insertAudiobook(workId);
    await db.audiobooksDao.insertFiles(workId, paths);
    return (await db.spineDao.worksOf(profileId)).firstWhere((w) => w.id == workId);
  }

  group('the audiobook door', () {
    testWidgets('appears in the empty-state action list when wired',
        (tester) async {
      await pump(tester, onImportAudiobook: (_) async => null);
      expect(find.text('Audiobook (pick files)'), findsOneWidget);
    });

    testWidgets('absent from the empty state when not wired (web tier)',
        (tester) async {
      await pump(tester);
      expect(find.text('Audiobook (pick files)'), findsNothing);
    });

    testWidgets('appears in the Add sheet once the library is non-empty',
        (tester) async {
      await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'note',
          title: 'A Note',
          persistence: 'work',
          firstSeenEpochDay: 100);
      await pump(tester, onImportAudiobook: (_) async => null);

      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(find.text('Audiobook (pick files)'), findsOneWidget);
    });

    testWidgets(
        'tapping it imports and reloads the library with the new book',
        (tester) async {
      Future<int?> fakeImport(BuildContext _) async {
        final work = await seedAudiobook(title: 'Imported Trail');
        return work.id;
      }

      await pump(tester, onImportAudiobook: fakeImport);
      await tester.tap(find.text('Audiobook (pick files)'));
      await tester.pumpAndSettle();

      expect(find.text('Imported Trail'), findsOneWidget);
      expect(find.text('Nothing on the trellis yet.'), findsNothing);
    });

    testWidgets('a cancelled pick (the gateway returns null) changes nothing',
        (tester) async {
      await pump(tester, onImportAudiobook: (_) async => null);
      await tester.tap(find.text('Audiobook (pick files)'));
      await tester.pumpAndSettle();

      expect(find.text('Nothing on the trellis yet.'), findsOneWidget);
      expect(await db.spineDao.worksOf(profileId), isEmpty);
    });
  });

  group('the library tile: New / Started / Finished', () {
    double progressOf(WidgetTester tester, String title) {
      final indicator = tester.widget<LinearProgressIndicator>(
        find.descendant(
          of: find.widgetWithText(ListTile, title),
          matching: find.byType(LinearProgressIndicator),
        ),
      );
      return indicator.value ?? 0.0;
    }

    testWidgets('a never-played audiobook shows New — zero progress',
        (tester) async {
      await seedAudiobook(title: 'Fresh Trail');
      await pump(tester);
      expect(progressOf(tester, 'Fresh Trail'), 0.0);
    });

    testWidgets(
        "a started audiobook's bar reads fileIdx / fileCount, not the raw offset",
        (tester) async {
      final work = await seedAudiobook(title: 'Midway Trail');
      await db.feedsDao.savePlayerPosition(
          profileId: profileId, workId: work.id, tMs: 5000, fileIdx: 1);
      await pump(tester);
      // 1 of 3 files reached.
      expect(progressOf(tester, 'Midway Trail'), closeTo(1 / 3, 0.001));
    });

    testWidgets('a finished audiobook shows full progress regardless of fileIdx',
        (tester) async {
      final work = await seedAudiobook(title: 'Done Trail');
      await db.feedsDao.savePlayerPosition(
          profileId: profileId, workId: work.id, tMs: 1000, fileIdx: 1);
      await db.spineDao.markFinished(work.id, 200);
      await pump(tester);
      expect(progressOf(tester, 'Done Trail'), 1.0);
    });
  });

  group('tapping an audiobook tile plays it — no separate reader screen',
      () {
    testWidgets('routes through PlayerController.playAudiobook', (tester) async {
      final work = await seedAudiobook(title: 'Play Me');
      final fakePlayer = FakeEpisodePlayer();
      final controller = PlayerController(
        db: db,
        profileId: profileId,
        createPlayer: () => fakePlayer,
      );
      addTearDown(controller.dispose);

      await pump(tester, player: controller);
      await tester.tap(find.text('Play Me'));
      await tester.pumpAndSettle();

      expect(controller.isAudiobook, isTrue);
      expect(controller.current?.id, work.id);
      expect(fakePlayer.playing, isTrue);
      // The whole interface stays the library + mini player, not a pushed
      // ReaderScreen (ADR-0013 Decision 6/7 — "the audiobook opens into the
      // EXISTING player surface").
      expect(find.byType(ReaderScreen), findsNothing);
      expect(find.text('Library'), findsOneWidget);
    });
  });

  group('removing an audiobook cleans up its files first', () {
    testWidgets('onDeleteAudiobookFiles fires before the DB row goes',
        (tester) async {
      final work = await seedAudiobook(title: 'Leaving Trail');
      final deleted = <int>[];

      await pump(tester,
          onDeleteAudiobookFiles: (workId) => deleted.add(workId));
      await tester.tap(find.byKey(Key('work-menu-${work.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from library'));
      await tester.pumpAndSettle();

      expect(deleted, [work.id]);
      expect(await db.spineDao.worksOf(profileId), isEmpty);
    });
  });
}
