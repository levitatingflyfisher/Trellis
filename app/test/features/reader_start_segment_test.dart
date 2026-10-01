import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/reader/reader_screen.dart';

import '../support/fake_player.dart';

/// A search hit opens the reader at its sentence (ADR-0016 section 4)
/// without costing the reader the place they had saved.
void main() {
  late AppDatabase db;
  late FakeEpisodePlayer fakePlayer;
  late PlayerController controller;
  late int profileId;
  late Work work;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    fakePlayer = FakeEpisodePlayer();
    profileId = await db.profilesDao.create('Ada');
    controller = PlayerController(
        db: db, profileId: profileId, createPlayer: () => fakePlayer);
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Ep 1',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/1.mp3');
    await db.spineDao.insertSegments(id, const [
      (idx: 0, kind: 'prose', text: 'First sentence.'),
      (idx: 1, kind: 'prose', text: 'Second sentence.'),
      (idx: 2, kind: 'prose', text: 'Third sentence.'),
    ]);
    await db.spineDao.insertAlignments(id, const [
      (segmentIdx: 0, tStartMs: 0, tEndMs: 10000),
      (segmentIdx: 1, tStartMs: 10000, tEndMs: 20000),
      (segmentIdx: 2, tStartMs: 20000, tEndMs: 30000),
    ]);
    await db.spineDao.savePosition(
        profileId: profileId,
        workId: id,
        segmentIdx: 0,
        wordIdx: 1,
        lastModality: 'read');
    work = (await db.spineDao.worksOf(profileId)).single;
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
  });

  testWidgets('the cursor starts at the hit, not the saved place',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(
            db: db,
            profileId: profileId,
            work: work,
            player: controller,
            startSegmentIdx: 2)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reader-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('listen-from-here')));
    await tester.pumpAndSettle();
    expect(fakePlayer.log.last, 'seek:20000');
  });

  testWidgets('leaving without moving keeps the saved place', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(
            db: db, profileId: profileId, work: work, startSegmentIdx: 2)));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    final saved =
        await db.spineDao.position(profileId: profileId, workId: work.id);
    expect((saved!.segmentIdx, saved.wordIdx), (0, 1));
  });

  testWidgets('a reload after moving on goes to the saved place, not back '
      'to the hit', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(
            db: db,
            profileId: profileId,
            work: work,
            player: controller,
            startSegmentIdx: 2)));
    await tester.pumpAndSettle();
    // Move to the second sentence, and let the app go to the background
    // so the place is saved there.
    await tester.tap(find.byKey(const Key('mode-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mode-item-scroll')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second'));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect((await db.spineDao
            .position(profileId: profileId, workId: work.id))!
        .segmentIdx, 1);
    // A language change reloads the work.
    await tester.tap(find.byKey(const Key('reader-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('work-language-action')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('work-language-de')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reader-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('listen-from-here')));
    await tester.pumpAndSettle();
    expect(fakePlayer.log.last, 'seek:10000');
  });
}
