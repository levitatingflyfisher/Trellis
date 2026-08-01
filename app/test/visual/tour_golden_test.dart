import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/fake_services.dart';
import '../support/scripted_fetcher.dart';
import 'dart:io';

/// The visual-loop tour (not a regression gate): renders the app's main
/// surfaces at three widths and writes goldens to READ, montaged by
/// contact-sheet.sh. Run with --update-goldens; the PNGs are gitignored.
///
/// Real seeded content on every screen: a prose work for the print
/// reader's drop cap, an expiring audio episode for the river's leaf
/// decay, and the bundled Kalman starter for the Espalier Wall.
void main() {
  const sizes = <String, Size>{
    'phone': Size(320, 690),
    'tablet': Size(768, 1024),
    'desktop': Size(1280, 800),
  };

  const prose =
      'It is interesting to contemplate an entangled bank, clothed with '
      'many plants of many kinds, with birds singing on the bushes, with '
      'various insects flitting about, and with worms crawling through '
      'the damp earth, and to reflect that these elaborately constructed '
      'forms, so different from each other, have all been produced by '
      'laws acting around us. There is grandeur in this view of life, '
      'with its several powers, having been originally breathed into a '
      'few forms or into one.';

  Future<AppDatabase> seed() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final profileId = await db.profilesDao.create('Ada');
    final today =
        DateTime.now().toUtc().millisecondsSinceEpoch ~/
            Duration.millisecondsPerDay;
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'note',
        title: 'An Entangled Bank',
        persistence: 'work',
        firstSeenEpochDay: today);
    await db.spineDao
        .insertSegments(workId, [(idx: 0, kind: 'prose', text: prose)]);

    // An audio episode two days from drifting away: faded leaf + notice.
    final feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://cast.example.test/feed.xml');
    final epWork = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Tides and Their Clocks',
        persistence: 'ephemeron',
        firstSeenEpochDay: today - 12,
        sourceUrl: 'https://cast.example.test/ep1.mp3');
    await db.feedsDao.insertEpisode(
        workId: epWork,
        feedId: feedId,
        guid: 'ep1',
        enclosureUrl: 'https://cast.example.test/ep1.mp3',
        publishedAtMs: DateTime.utc(2026, 8, 1).millisecondsSinceEpoch);
    return db;
  }

  // Self-guarded: the goldens are read-and-discard artifacts (gitignored),
  // so a plain `flutter test` on a fresh clone must not fail on their
  // absence. Regenerate + inspect with:
  //   VISUAL_TOUR=1 flutter test test/visual/tour_golden_test.dart --update-goldens
  final touring = Platform.environment['VISUAL_TOUR'] == '1';

  testWidgets('tour: library, reader, river, wall at three widths',
      skip: !touring,
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1.0;
    final dir = Directory.systemTemp.createTempSync('trellis-tour');
    addTearDown(() => dir.deleteSync(recursive: true));

    for (final entry in sizes.entries) {
      tester.view.physicalSize = entry.value;
      final db = await seed();
      addTearDown(db.close);
      final player = FakeEpisodePlayer();

      Future<void> shoot(String screen) => expectLater(
          find.byType(TrellisApp),
          matchesGoldenFile('goldens/tour_${screen}_${entry.key}.png'));

      await tester.pumpWidget(TrellisApp(
          db: db,
          fetcher: ScriptedFetcher((u, h) => textResponse('')),
          createPlayer: () => player,
          services: testServices(dir)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ada'));
      await tester.pumpAndSettle();
      await shoot('library');

      await tester.tap(find.text('An Entangled Bank'));
      await tester.pumpAndSettle();
      await shoot('reader_rsvp');
      // Campaign 9 Phase 6: `mode-toggle` opens a labeled three-way
      // picker rather than cycling on its own tap.
      await tester.tap(find.byKey(const Key('mode-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('mode-item-scroll')));
      await tester.pumpAndSettle();
      await shoot('reader_scroll');
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('River'));
      await tester.pumpAndSettle();
      await shoot('river');

      await tester.tap(find.text('Courses'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add the starter course'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('The Kalman Filter Family'));
      await tester.pumpAndSettle();
      await shoot('wall');

      // A clean slate between sizes: the next pump replaces the tree.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }
  });
}
