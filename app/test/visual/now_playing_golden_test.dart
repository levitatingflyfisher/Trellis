import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhearth_design/openhearth_design.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/now_playing_screen.dart';
import 'package:trellis/features/player/player_controller.dart';

import '../support/fake_player.dart';

/// The big player on a phone, light and dark, at 1× and at 2× text on a
/// small phone (owner, 14 Nov 2026: the bar was "too tiny a target").
/// VISUAL_TOUR=1 to run; --update-goldens to redraw.
void main() {
  final touring = Platform.environment['VISUAL_TOUR'] == '1';

  testWidgets('now playing: phone widths, light and dark', skip: !touring,
      (tester) async {
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    tester.view.devicePixelRatio = 1.0;

    for (final (width, height, scale, tag) in [
      (360.0, 740.0, 1.0, 'x1'),
      (320.0, 568.0, 2.0, '320_x2'),
    ]) {
      for (final dark in [false, true]) {
        tester.view.physicalSize = Size(width, height);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        final profileId = await db.profilesDao.create('Ada');
        final feedId = await db.feedsDao.insertFeed(
            profileId: profileId,
            url: 'https://x.test/f',
            title: 'The Night Sky Cast');
        final workId = await db.spineDao.insertWork(
            profileId: profileId,
            kind: 'episode',
            title: 'Aurora season, and what the solar maximum means for the '
                'north',
            persistence: 'ephemeron',
            firstSeenEpochDay: 100,
            sourceUrl: 'https://x.test/a.mp3');
        await db.feedsDao.insertEpisode(
            workId: workId,
            feedId: feedId,
            guid: 'a',
            enclosureUrl: 'https://x.test/a.mp3',
            publishedAtMs: 1000);
        final player = FakeEpisodePlayer();
        final controller = PlayerController(
            db: db, profileId: profileId, createPlayer: () => player);
        await controller.playWork((await db.spineDao.workById(workId))!);
        player.emitDuration(const Duration(minutes: 52));
        player.emitPosition(const Duration(minutes: 17, seconds: 4));

        await tester.pumpWidget(MaterialApp(
          theme: dark ? OhTheme.hearthDark() : OhTheme.light(),
          home: NowPlayingScreen(
            controller: controller,
            onOpenWork: () {},
            onOpenQueue: () {},
            onOpenCaptures: () {},
            onCapture: () {},
            onOpenShow: () {},
          ),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(
            find.byType(NowPlayingScreen),
            matchesGoldenFile(
                'goldens/now_playing_${tag}_${dark ? 'dark' : 'light'}.png'));
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        await db.close();
      }
    }
  });
}
