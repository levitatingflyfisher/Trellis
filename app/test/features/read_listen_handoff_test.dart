
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/reader/reader_screen.dart';

import '../support/fake_player.dart';

/// The study crown, Phase 3: the read -> listen handoff. The math already
/// exists (Spine.projectAudioTime, proven at
/// packages/loom_core/test/cursor_law_test.dart); this file is the UI
/// wiring — Listen in the reader — over the SAME canonical Position row
/// the player and reader already both read and write (ADR-0002). (The
/// transcript view's "Read from here" left with that view in 1.5.8: Page
/// is the transcript now.)
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
    await db.spineDao.insertSegments(workId, const [
      (idx: 0, kind: 'prose', text: 'First sentence.'),
      (idx: 1, kind: 'prose', text: 'Second sentence.'),
    ]);
    await db.spineDao.insertAlignments(workId, const [
      (segmentIdx: 0, tStartMs: 0, tEndMs: 10000),
      (segmentIdx: 1, tStartMs: 10000, tEndMs: 20000),
    ]);
    return (await db.spineDao.worksOf(profileId)).single;
  }

  // Listening is a visible button on the reader, not an item behind ⋮.
  group('Listen (reader -> player)', () {
    Future<void> toScroll(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('mode-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('mode-item-page')));
      await tester.pumpAndSettle();
    }

    testWidgets(
        'no Listen when there is no player wired in (never a dead button)',
        (tester) async {
      final work = await seedAlignedEpisode();
      await tester.pumpWidget(MaterialApp(
          home: ReaderScreen(db: db, profileId: profileId, work: work)));
      await tester.pumpAndSettle();
      await toScroll(tester);

      expect(find.byTooltip('Listen'), findsNothing);
      expect(find.byTooltip('Read aloud'), findsWidgets,
          reason: 'without a player, Page’s Play reads the text aloud');
    });

    testWidgets('no Listen when the work has no aligned audio', (tester) async {
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'note',
          title: 'Plain note',
          persistence: 'work',
          firstSeenEpochDay: 100);
      await db.spineDao
          .insertSegments(workId, const [(idx: 0, kind: 'prose', text: 'Hi.')]);
      final work = (await db.spineDao.worksOf(profileId)).single;
      await tester.pumpWidget(MaterialApp(
          home: ReaderScreen(
              db: db, profileId: profileId, work: work, player: controller)));
      await tester.pumpAndSettle();
      await toScroll(tester);

      expect(find.byTooltip('Listen'), findsNothing);
    });

    testWidgets('Listen is on the screen, not in the menu', (tester) async {
      final work = await seedAlignedEpisode();
      await tester.pumpWidget(MaterialApp(
          home: ReaderScreen(
              db: db, profileId: profileId, work: work, player: controller)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reader-play')), findsOneWidget,
          reason: 'in RSVP too, beside its own pacer');
      await toScroll(tester);
      expect(find.byKey(const Key('reader-play')), findsOneWidget);

      await tester.tap(find.byKey(const Key('reader-overflow')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('listen-from-here')), findsNothing);
      expect(find.byKey(const Key('follow-along-toggle')), findsNothing);
    });

    testWidgets(
        'Listen starts playback at the audio time the reading cursor '
        'projects to, and then reads Pause and pauses', (tester) async {
      final work = await seedAlignedEpisode();
      await tester.pumpWidget(MaterialApp(
          home: ReaderScreen(
              db: db, profileId: profileId, work: work, player: controller)));
      await tester.pumpAndSettle();
      await toScroll(tester);
      await tester.tap(find.text('Second'));
      await tester.pump();

      await tester.tap(find.byTooltip('Listen'));
      await tester.pumpAndSettle();

      expect(fakePlayer.loadedUrl, 'https://cast.test/1.mp3');
      expect(fakePlayer.log.last, 'seek:10000',
          reason: 'segment 1 (where the cursor landed) starts at 10000ms');
      expect(controller.playing, isTrue);
      expect(find.byTooltip('Listen'), findsNothing);

      await tester.tap(find.byTooltip('Pause'));
      await tester.pumpAndSettle();
      expect(controller.playing, isFalse);
      expect(find.byTooltip('Listen'), findsOneWidget);
    });
  });

}
