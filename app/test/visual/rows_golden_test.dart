import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/works/work_row.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/pick_reader.dart';
import '../support/scripted_fetcher.dart';
import '../support/tabs.dart';

/// The visual-loop check for 1.5.4's shared row (not a regression gate):
/// Latest, the Queue, the Library and History at phone width, at normal
/// and 1.3x text, so the rows can be read side by side and judged the
/// same. The PNGs are gitignored. Regenerate and inspect with:
///   VISUAL_TOUR=1 flutter test test/visual/rows_golden_test.dart --update-goldens
void main() {
  final touring = Platform.environment['VISUAL_TOUR'] == '1';

  Future<AppDatabase> seed() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final profileId = await db.profilesDao.create('Ada');
    final feedId = await db.feedsDao.insertFeed(
        profileId: profileId,
        url: 'https://x.test/f',
        title: 'The Night Sky Cast');
    final now = DateTime.now().millisecondsSinceEpoch;
    final today = now ~/ Duration.millisecondsPerDay;

    Future<int> episode(String title, int ago,
        {bool audio = true,
        bool transcribed = false,
        int? heardMs,
        bool kept = true}) async {
      final id = await db.spineDao.insertWork(
          profileId: profileId,
          kind: audio ? 'episode' : 'article',
          title: title,
          persistence: kept ? 'work' : 'ephemeron',
          firstSeenEpochDay: today,
          sourceUrl: 'https://x.test/${title.hashCode}');
      await db.feedsDao.insertEpisode(
          workId: id,
          feedId: feedId,
          guid: title,
          enclosureUrl: audio ? 'https://x.test/${title.hashCode}.mp3' : null,
          durationMs: audio ? 52 * 60000 : null,
          publishedAtMs: now - ago * Duration.millisecondsPerDay);
      if (!audio || transcribed) {
        await db.spineDao.insertSegments(id, [
          for (var i = 0; i < 40; i++)
            (idx: i, kind: 'prose', text: 'A sentence that runs on. ' * 12),
        ]);
      }
      if (transcribed) {
        await db.spineDao.insertAlignments(
            id, const [(segmentIdx: 0, tStartMs: 0, tEndMs: 900)]);
      }
      if (heardMs != null) {
        await db.feedsDao.savePlayerPosition(
            profileId: profileId, workId: id, tMs: heardMs);
      }
      return id;
    }

    final aurora = await episode('Aurora season, and what the solar '
        'maximum means for the north', 1,
        transcribed: true, heardMs: 20 * 60000);
    final field = await episode('Field notes from a cold marsh', 2,
        audio: false);
    final perseid = await episode('Perseid peak tonight', 3);
    // Latest's everyday rows, newest: new, untouched, not kept or queued.
    await episode('Why the Moon looks bigger near the horizon', 0,
        kept: false);
    await episode('Comet watch', 0, kept: false);
    await episode('Listener questions: telescopes for beginners, and '
        'where to point them first', 0, kept: false);
    final book = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'book',
        title: 'Middlemarch',
        persistence: 'work',
        firstSeenEpochDay: today - 30);
    await db.spineDao.setPinned(book, true);
    await db.spineDao.insertSegments(book, [
      for (var i = 0; i < 200; i++)
        (idx: i, kind: 'prose', text: 'Miss Brooke had that kind. ' * 20),
    ]);
    await db.spineDao.savePosition(
        profileId: profileId,
        workId: book,
        segmentIdx: 60,
        wordIdx: 0,
        lastModality: 'read');
    for (final (i, id) in [aurora, field, perseid, book].indexed) {
      await db.queueDao.playLast(profileId: profileId, workId: id, nowMs: i);
    }
    return db;
  }

  testWidgets('rows: the same anatomy on every list, phone width',
      skip: !touring, (tester) async {
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(360, 760);

    for (final scale in [1.0, 1.3]) {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      final db = await seed();
      addTearDown(db.close);
      final tag = scale == 1.0 ? 'x1' : 'x13';
      Future<void> shoot(String screen) async {
        // The row heights the report quotes, measured, not eyeballed.
        final heights = [
          for (final e in find.byType(ListTile).evaluate())
            if (e.findAncestorWidgetOfExactType<WorkRow>() case final row?)
              '${row.work.title.split(' ').first}=${e.size!.height.round()}',
        ];
        // ignore: avoid_print
        print('rows $screen $tag: ${heights.join(', ')}');
        await expectLater(find.byType(TrellisApp),
            matchesGoldenFile('goldens/rows_${screen}_$tag.png'));
      }

      await tester.pumpWidget(TrellisApp(
          db: db,
          fetcher: ScriptedFetcher((u, h) => textResponse('')),
          createPlayer: () => FakeEpisodePlayer()));
      await tester.pumpAndSettle();
      await pickReader(tester, 'Ada');
      await shoot('latest');
      await toTab(tester, 'Queue');
      await shoot('queue');
      await tester.tap(find.byKey(const Key('queue-history')));
      await tester.pumpAndSettle();
      await shoot('history');
      await tester.pageBack();
      await tester.pumpAndSettle();
      await toTab(tester, 'Library');
      await shoot('library');

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }
  });
}
