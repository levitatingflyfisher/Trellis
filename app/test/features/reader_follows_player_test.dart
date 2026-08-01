import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/reader/reader_screen.dart';

import '../support/fake_player.dart';

/// Campaign 9 Phase 7 ("the reader follows the player"): when audio for
/// THIS work is playing — already under way when the reader opens, or
/// started via 'Listen from here' — the reader listens to
/// [PlayerController] and advances its own cursor via the SAME
/// `Spine.positionAtAudioTime` mapping `karaoke_screen.dart` already
/// proves (ADR-0002). A manual seek (tap a word, drag-scroll) detaches;
/// the "Following audio" / "Resume following" chip both shows and
/// controls the state. The pure segment-idx -> word-cursor mapping is
/// covered separately in `test/reader/reader_logic_test.dart`
/// (`wordIndexAtAudioTime`).
void main() {
  late AppDatabase db;
  late FakeEpisodePlayer fakePlayer;
  late PlayerController controller;
  late int profileId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    fakePlayer = FakeEpisodePlayer();
    profileId = await db.profilesDao.create('Ada');
    controller = PlayerController(
        db: db, profileId: profileId, createPlayer: () => fakePlayer);
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
  });

  Future<Work> seedAlignedEpisode() async {
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Ep 1',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/1.mp3');
    // Every word is unique, deliberately: word 0 of the whole document
    // ('First') renders as the print reader's DROP CAP
    // (reader_print_test.dart), not a plain `cursor-word`-keyed Text, so
    // tests that need a tappable, cursor-word-checkable word in segment 0
    // reach for 'alpha.' instead.
    await db.spineDao.insertSegments(workId, const [
      (idx: 0, kind: 'prose', text: 'First alpha.'),
      (idx: 1, kind: 'prose', text: 'Second beta.'),
    ]);
    await db.spineDao.insertAlignments(workId, const [
      (segmentIdx: 0, tStartMs: 0, tEndMs: 10000),
      (segmentIdx: 1, tStartMs: 10000, tEndMs: 20000),
    ]);
    return (await db.spineDao.worksOf(profileId)).single;
  }

  Future<void> openInScroll(WidgetTester tester, Work work) async {
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(
            db: db, profileId: profileId, work: work, player: controller)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mode-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mode-item-scroll')));
    await tester.pumpAndSettle();
  }

  String? cursorWordText(WidgetTester tester) {
    final finder = find.byKey(const Key('cursor-word'));
    if (finder.evaluate().isEmpty) return null;
    return tester.widget<Text>(finder).data;
  }

  group('the chip is absent when there is nothing to follow', () {
    testWidgets('no player wired in', (tester) async {
      final work = await seedAlignedEpisode();
      await tester.pumpWidget(MaterialApp(
          home: ReaderScreen(db: db, profileId: profileId, work: work)));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('follow-audio-chip')), findsNothing);
    });

    testWidgets('a player is wired in but not playing this work',
        (tester) async {
      final work = await seedAlignedEpisode();
      await openInScroll(tester, work);

      expect(find.byKey(const Key('follow-audio-chip')), findsNothing);
    });

    testWidgets('the work has no alignments at all', (tester) async {
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'note',
          title: 'Plain note',
          persistence: 'work',
          firstSeenEpochDay: 100);
      await db.spineDao
          .insertSegments(workId, const [(idx: 0, kind: 'prose', text: 'Hi.')]);
      final work = (await db.spineDao.worksOf(profileId)).single;
      await controller.playWork(work);
      await openInScroll(tester, work);

      expect(find.byKey(const Key('follow-audio-chip')), findsNothing);
    });
  });

  testWidgets(
      'audio already playing for this work attaches automatically on '
      'open, and position ticks move the cursor', (tester) async {
    final work = await seedAlignedEpisode();
    await controller.playWork(work);

    await openInScroll(tester, work);

    expect(find.byKey(const Key('follow-audio-chip')), findsOneWidget);
    expect(find.text('Following audio'), findsOneWidget);

    fakePlayer.emitPosition(const Duration(seconds: 15)); // inside segment 1
    await tester.pump();

    expect(cursorWordText(tester), 'Second');
  });

  testWidgets("'Listen from here' also attaches following", (tester) async {
    final work = await seedAlignedEpisode();
    await openInScroll(tester, work);
    expect(find.byKey(const Key('follow-audio-chip')), findsNothing,
        reason: 'nothing is playing yet');

    await tester.tap(find.text('alpha.')); // segment 0, not the drop cap
    await tester.pump();
    await tester.tap(find.byKey(const Key('listen-from-here')));
    await tester.pumpAndSettle();

    expect(find.text('Following audio'), findsOneWidget);

    fakePlayer.emitPosition(const Duration(seconds: 15)); // segment 1
    await tester.pump();

    expect(cursorWordText(tester), 'Second');
  });

  testWidgets(
      'a manual tap-to-seek detaches — the chip reads "Resume following" '
      'and further ticks stop moving the cursor', (tester) async {
    final work = await seedAlignedEpisode();
    await controller.playWork(work);
    await openInScroll(tester, work);
    expect(find.text('Following audio'), findsOneWidget);

    await tester.tap(find.text('alpha.')); // segment 0, not the drop cap
    await tester.pump();

    expect(find.text('Resume following'), findsOneWidget);

    fakePlayer.emitPosition(const Duration(seconds: 15)); // segment 1
    await tester.pump();

    expect(cursorWordText(tester), 'alpha.',
        reason: 'the manual seek detached following — the tick must not '
            'have moved the cursor');
  });

  testWidgets(
      'an RSVP manual seek also detaches (not only the scroll-family '
      'tap-a-word path)', (tester) async {
    final work = await seedAlignedEpisode();
    await controller.playWork(work);
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(
            db: db, profileId: profileId, work: work, player: controller)));
    await tester.pumpAndSettle();
    expect(find.text('Following audio'), findsOneWidget);

    final rect = tester.getRect(find.byKey(const Key('reader-tapzone')));
    await tester.tapAt(Offset(rect.left + rect.width * 5 / 6, rect.center.dy));
    await tester.pump();

    expect(find.text('Resume following'), findsOneWidget);
  });

  testWidgets('tapping "Resume following" reattaches', (tester) async {
    final work = await seedAlignedEpisode();
    await controller.playWork(work);
    await openInScroll(tester, work);
    await tester.tap(find.text('alpha.')); // segment 0, not the drop cap
    await tester.pump();
    expect(find.text('Resume following'), findsOneWidget);

    await tester.tap(find.byKey(const Key('follow-audio-chip')));
    await tester.pump();
    expect(find.text('Following audio'), findsOneWidget);

    fakePlayer.emitPosition(const Duration(seconds: 15)); // segment 1
    await tester.pump();

    expect(cursorWordText(tester), 'Second');
  });

  testWidgets(
      'a drag-scroll detaches following — the user\'s hand always wins',
      (tester) async {
    // Enough segments that the view genuinely overflows the viewport —
    // seedAlignedEpisode's own 2 short segments fit on screen with
    // nothing to drag, which would pass this test vacuously (the same
    // lesson Campaign 9 Phase 6's own follow-along test learned).
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Long episode',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/long.mp3');
    await db.spineDao.insertSegments(workId, [
      for (var i = 0; i < 30; i++) (idx: i, kind: 'prose', text: 'Para $i.')
    ]);
    await db.spineDao.insertAlignments(workId, [
      for (var i = 0; i < 30; i++)
        (segmentIdx: i, tStartMs: i * 1000, tEndMs: (i + 1) * 1000)
    ]);
    final work =
        (await db.spineDao.worksOf(profileId)).firstWhere((w) => w.id == workId);
    await controller.playWork(work);
    await openInScroll(tester, work);
    expect(find.text('Following audio'), findsOneWidget);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
    await tester.pump();

    expect(find.text('Resume following'), findsOneWidget);
  });

  testWidgets(
      'playback moving to a different work detaches quietly, without '
      'throwing', (tester) async {
    final work = await seedAlignedEpisode();
    await controller.playWork(work);
    await openInScroll(tester, work);
    expect(find.text('Following audio'), findsOneWidget);

    final otherWorkId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Ep 2',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/2.mp3');
    final otherWork =
        (await db.spineDao.worksOf(profileId)).firstWhere((w) => w.id == otherWorkId);
    await controller.playWork(otherWork);
    await tester.pump();

    expect(find.byKey(const Key('follow-audio-chip')), findsNothing);
  });

  testWidgets(
      'disposing the reader while following removes the listener — a '
      'later tick on the (now-detached) controller never throws',
      (tester) async {
    final work = await seedAlignedEpisode();
    await controller.playWork(work);
    await openInScroll(tester, work);
    expect(find.text('Following audio'), findsOneWidget);

    await tester.pumpWidget(const SizedBox()); // tears the reader down
    await tester.pumpAndSettle();

    expect(() => fakePlayer.emitPosition(const Duration(seconds: 15)),
        returnsNormally);
  });
}
