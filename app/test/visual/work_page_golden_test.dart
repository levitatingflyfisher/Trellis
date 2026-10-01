import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhearth_design/openhearth_design.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/episodes/episode_actions.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/reader/reader_doors.dart';
import 'package:trellis/features/works/work_open.dart';
import 'package:trellis/features/works/work_page.dart';

import '../support/fake_player.dart';

/// The visual-loop check for 1.5.4's work page (not a regression gate):
/// an untranscribed episode with long notes and a book, at phone width,
/// at normal and 1.3x text. The PNGs are gitignored. Regenerate and
/// inspect with:
///   VISUAL_TOUR=1 flutter test test/visual/work_page_golden_test.dart --update-goldens
void main() {
  final touring = Platform.environment['VISUAL_TOUR'] == '1';

  testWidgets('work page: an episode and a book, phone width',
      skip: !touring, (tester) async {
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    tester.view.devicePixelRatio = 1.0;

    // 320dp at 2x as well: chips clip rather than overflow, so only a
    // look tells whether the language row still reads.
    for (final (width, scale, tag) in [
      (360.0, 1.0, 'x1'),
      (360.0, 1.3, 'x13'),
      (320.0, 2.0, '320_x2'),
    ]) {
      tester.view.physicalSize = Size(width, 1100);
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final profileId = await db.profilesDao.create('Ada');
      final feedId = await db.feedsDao.insertFeed(
          profileId: profileId,
          url: 'https://x.test/f',
          title: 'The Night Sky Cast');
      final now = DateTime.now().millisecondsSinceEpoch;
      final episode = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: 'Aurora season, and what the solar maximum means for the '
              'north',
          persistence: 'ephemeron',
          firstSeenEpochDay: now ~/ Duration.millisecondsPerDay,
          sourceUrl: 'https://x.test/a.mp3');
      await db.feedsDao.insertEpisode(
          workId: episode,
          feedId: feedId,
          guid: 'a',
          enclosureUrl: 'https://x.test/a.mp3',
          durationMs: 52 * 60000,
          publishedAtMs: now - Duration.millisecondsPerDay);
      final notes = StringBuffer(
          '<p>This week: why the aurora reaches so far south during '
          'solar maximum, and how to read a space-weather forecast.</p>'
          '<p><strong>Chapters</strong></p><ul>'
          '<li>0:00 Hello</li><li>4:12 The solar cycle</li>'
          '<li>18:40 Reading the Kp index</li><li>41:05 Your questions</li>'
          '</ul><p>Links: <a href="https://www.swpc.test/forecast">the '
          'forecast</a>, <a href="https://maps.test/aurora">an aurora '
          'map</a>.</p>');
      for (var i = 0; i < 8; i++) {
        notes.write('<p>More notes, paragraph $i, with thanks to everyone '
            'who wrote in about last month’s meteor shower.</p>');
      }
      await db.feedsDao
          .fillNotes(episode, html: notes.toString(), plain: 'notes');
      final book = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'book',
          title: 'Middlemarch',
          persistence: 'work',
          firstSeenEpochDay: now ~/ Duration.millisecondsPerDay - 30);
      await db.spineDao.insertSegments(book, [
        for (var i = 0; i < 50; i++)
          (idx: i, kind: 'prose', text: 'Miss Brooke had that kind of '
              'beauty which seems to be thrown into relief by poor dress. ' *
                  3),
      ]);
      await db.spineDao.upsertTranslationSentence(
          workId: book,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: 'es',
          sourceText: 'Miss Brooke had that kind of beauty.',
          body: 'La señorita Brooke.');
      await db.spineDao.setWorkLang(book, 'en');
      await db.spineDao.savePosition(
          profileId: profileId,
          workId: book,
          segmentIdx: 12,
          wordIdx: 0,
          lastModality: 'read');

      final controller = PlayerController(
          db: db, profileId: profileId, createPlayer: FakeEpisodePlayer.new);
      addTearDown(controller.dispose);
      final doors = WorkDoors(
          db: db,
          profileId: profileId,
          readerDoors: ReaderDoors(player: controller),
          actions: EpisodeActions(
              db: db, profileId: profileId, player: controller),
          transcribeRate: () => 1 / 12);
      for (final (name, id) in [('episode', episode), ('book', book)]) {
        final work = (await db.spineDao.workById(id))!;
        final ep = await db.feedsDao.episodeOf(id);
        await tester.pumpWidget(MaterialApp(
            theme: OhTheme.light(),
            home: WorkPage(
                key: ValueKey(id),
                doors: doors,
                entry: (work: work, episode: ep))));
        await tester.pumpAndSettle();
        await expectLater(find.byType(WorkPage),
            matchesGoldenFile('goldens/work_page_${name}_$tag.png'));
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }
  });
}
