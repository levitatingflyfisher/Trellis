import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/mini_player_bar.dart';
import 'package:trellis/features/player/player_controller.dart';

import '../support/fake_player.dart';

/// The fleet's recurring accessibility wound (narrow_screen_test.dart's own
/// words) is rigid rows overflowing at 320dp/2x text scale.
/// `mini_player_bar.dart`'s own doc comment claims "compact enough for
/// 320dp at 2x text scale — the fleet's sweep pins that", and
/// narrow_screen_test.dart machine-checks that claim for an EPISODE with
/// alignments (6 simultaneous icons: karaoke, capture, captures, queue,
/// sleep timer, close). ADR-0013 flagged the audiobook's Chapters icon as
/// an unverified "seventh conditional icon" — this test settles it
/// directly rather than leaving the gap open: an audiobook never has
/// alignments (`_loadAudiobook` sets them to `const []`), so the karaoke
/// icon and the Chapters icon can never both show. The true worst case for
/// an audiobook is 6 icons too (capture, captures, queue, chapters, sleep
/// timer, close) — the same count the existing sweep already pins, just
/// with Chapters standing in for karaoke.
void main() {
  testWidgets(
      'the audiobook mini bar (Chapters in place of Synced text) survives '
      '320dp at 2x text scale with every optional icon wired', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final profileId = await db.profilesDao.create('Ada');
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'audiobook',
        title: 'An Uncommonly Long Audiobook Title For A 320dp Sweep',
        persistence: 'work',
        firstSeenEpochDay: 100);
    await db.audiobooksDao.insertAudiobook(workId);
    await db.audiobooksDao.insertFiles(workId, const ['/a/0.mp3']);
    final work = (await db.spineDao.worksOf(profileId)).single;

    final player = FakeEpisodePlayer();
    final controller = PlayerController(
        db: db, profileId: profileId, createPlayer: () => player);
    addTearDown(controller.dispose);
    await controller.playAudiobook(work);
    expect(controller.isAudiobook, isTrue);
    expect(controller.hasAlignments, isFalse,
        reason: 'an audiobook never gets alignments — karaoke and Chapters '
            'are mutually exclusive, not additive');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MiniPlayerBar(
          controller: controller,
          onOpenSyncedText: () {},
          onCapture: () {},
          onOpenCaptures: () {},
          onOpenQueue: () {},
          onOpenChapters: () {},
        ),
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('open-chapters')), findsOneWidget);
    expect(find.byKey(const Key('open-karaoke')), findsNothing);
  });
}
