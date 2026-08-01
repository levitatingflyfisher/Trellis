import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/fake_services.dart';
import '../support/scripted_fetcher.dart';
import 'dart:io';

/// Campaign 9 Phase 0 — reproduce-first for the device report: "the
/// play/pause circles don't have play/pause symbols in them, they're just
/// blank circles." Code inspection already disproved the two obvious
/// causes (const IconData everywhere; tree-shaken glyphs present with ink;
/// IconButton.filled gets high-contrast tokens from both themes' real
/// ColorSchemes — see p0_icon_data_test.dart for the assertions that pin
/// that). This is the visual half: golden-render the three surfaces the
/// report could describe — the mini player bar (playing AND paused), a
/// river episode row's play button, and the RSVP play/pause toggle — in
/// both themes and at textScale 1.0 and 2.0, and READ the montage before
/// concluding anything.
///
/// Self-guarded like tour_golden_test.dart: goldens are gitignored
/// read-and-discard artifacts, not a committed regression gate (cross-
/// machine font/AA drift is the #1 golden-flakiness cause — see the
/// visual-loop skill). Regenerate + inspect with:
///   P0_REPRO=1 flutter test test/visual/p0_repro_golden_test.dart --update-goldens
void main() {
  final touring = Platform.environment['P0_REPRO'] == '1';

  const prose =
      'It is interesting to contemplate an entangled bank, clothed with '
      'many plants of many kinds, with birds singing on the bushes, with '
      'various insects flitting about, and with worms crawling through '
      'the damp earth.';

  Future<AppDatabase> seed() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final profileId = await db.profilesDao.create('Ada');
    final today = DateTime.now().toUtc().millisecondsSinceEpoch ~/
        Duration.millisecondsPerDay;
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'note',
        title: 'An Entangled Bank',
        persistence: 'work',
        firstSeenEpochDay: today);
    await db.spineDao
        .insertSegments(workId, [(idx: 0, kind: 'prose', text: prose)]);

    final feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://cast.example.test/feed.xml');
    final epWork = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Tides and Their Clocks',
        persistence: 'ephemeron',
        firstSeenEpochDay: today,
        sourceUrl: 'https://cast.example.test/ep1.mp3');
    await db.feedsDao.insertEpisode(
        workId: epWork,
        feedId: feedId,
        guid: 'ep1',
        enclosureUrl: 'https://cast.example.test/ep1.mp3',
        publishedAtMs: DateTime.utc(2026, 8, 1).millisecondsSinceEpoch);
    return db;
  }

  for (final brightness in [Brightness.light, Brightness.dark]) {
    for (final textScale in [1.0, 2.0]) {
      final tag = '${brightness.name}_ts${textScale.toStringAsFixed(0)}';

      testWidgets(
          'play/pause controls at $tag: river row, mini bar (playing → '
          'paused), RSVP toggle', skip: !touring, (tester) async {
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearAllTestValues);
        tester.view.physicalSize = const Size(320, 690);
        tester.view.devicePixelRatio = 1.0;
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        tester.platformDispatcher.textScaleFactorTestValue = textScale;

        final db = await seed();
        addTearDown(db.close);
        final player = FakeEpisodePlayer();
        final dir = Directory.systemTemp.createTempSync('trellis-p0');
        addTearDown(() => dir.deleteSync(recursive: true));

        Future<void> shoot(String screen) => expectLater(
            find.byType(TrellisApp),
            matchesGoldenFile('goldens/p0_${screen}_$tag.png'));

        await tester.pumpWidget(TrellisApp(
            db: db,
            fetcher: ScriptedFetcher((u, h) => textResponse('')),
            createPlayer: () => player,
            services: testServices(dir)));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Ada'));
        await tester.pumpAndSettle();

        // RSVP controls: open the reader (default mode is RSVP).
        await tester.tap(find.text('An Entangled Bank'));
        await tester.pumpAndSettle();
        await shoot('rsvp');
        await tester.pageBack();
        await tester.pumpAndSettle();

        // River row's play button, then start playback so the mini bar
        // mounts (home_shell.dart hosts it above every screen) — playing
        // first, then toggled to paused, both real code paths, not a
        // hand-copied re-render.
        await tester.tap(find.text('River'));
        await tester.pumpAndSettle();
        await shoot('river_row');

        final playKeys = find.byWidgetPredicate(
            (w) => w is IconButton && w.key.toString().contains('play-'));
        expect(playKeys, findsWidgets,
            reason: 'the river row must expose a play control to '
                'reproduce against');
        await tester.tap(playKeys.first);
        await tester.pumpAndSettle();
        await shoot('mini_bar_playing');

        await tester.tap(find.byKey(const Key('player-toggle')));
        await tester.pump();
        await shoot('mini_bar_paused');
      });
    }
  }
}
