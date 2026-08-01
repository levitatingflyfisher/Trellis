import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/scripted_fetcher.dart';

/// The fleet's recurring accessibility wound: rigid rows overflowing at
/// 320dp with large text. RenderFlex overflow throws in widget tests, so
/// pumping every screen at 320×640 @ 2.0 text scale is a real check —
/// including the P2 additions (the shell's nav bar, the river with its
/// chips, the playing mini bar, the feeds screen, subscribe) and the study
/// slice (courses list, the ladder map with its chips, the session's
/// declaration, intake, cloze and 2×2 grade grid, and the end screen).
void main() {
  late AppDatabase db;
  late FakeEpisodePlayer player;
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    player = FakeEpisodePlayer();
  });
  tearDown(() => db.close());

  testWidgets('every screen survives 320dp at 2x text scale',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);

    final profileId = await db.profilesDao.create('Adalheidis Winterbourne');
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'book',
        title: 'A Rather Longer Title Than Any List Row Would Prefer',
        persistence: 'work',
        firstSeenEpochDay: 100);
    await db.spineDao.insertSegments(workId, const [
      (idx: 0, kind: 'heading', text: 'Chapter I of the Winter Journey'),
      (
        idx: 1,
        kind: 'prose',
        text: 'Incomprehensibilities notwithstanding, the reader continued.'
      ),
      (idx: 2, kind: 'code', text: 'let x = 1;'),
    ]);

    // A feed with a verbose title and a long-named unread audio episode —
    // the river row, the chips, and the mini bar all under pressure.
    final feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://cast.example.test/feeds/all.xml');
    await db.feedsDao.updateRefreshState(feedId,
        title: 'The Extraordinarily Comprehensive Night Sky Podcast',
        etag: null,
        lastModified: null,
        breakerJson: '{}');
    final episodeWorkId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Episode 400: Incomprehensibilities of the Aurora Borealis '
            'Considered at Length',
        persistence: 'ephemeron',
        // Fresh — the boot sweep (ADR-0003 law 2) must not take it.
        firstSeenEpochDay: DateTime.now().toUtc().millisecondsSinceEpoch ~/
            Duration.millisecondsPerDay,
        sourceUrl: 'https://cast.example.test/400.mp3');
    await db.feedsDao.insertEpisode(
        workId: episodeWorkId,
        feedId: feedId,
        guid: 'ep-400',
        enclosureUrl: 'https://cast.example.test/400.mp3',
        publishedAtMs: DateTime.utc(2026, 8, 5).millisecondsSinceEpoch);

    // A course whose titles lean on every row: the list tile, the ladder
    // tile with its due chip, and a session with a long cloze.
    await db.studyDao.importCourse(
        profileId: profileId,
        nowMs: 1,
        raw: json.encode({
          'schemaVersion': '1.0',
          'id': 'sweep',
          'title': 'An Uncommonly Verbose Introduction to Incomprehensibly '
              'Long Course Titles',
          'nodes': [
            {
              'id': 'a',
              'title': 'The Foundational Concept of Incomprehensibilities',
              'summary': 'A summary long enough to wrap twice on a narrow '
                  'screen at double text scale.',
              'intake': 'Incomprehensibilities notwithstanding, the learner '
                  'continued up the ladder.\n\nA second paragraph keeps the '
                  'intake list honest.',
              'items': [
                {
                  'id': 'i-sweep',
                  'type': 'cloze',
                  'rung': 1,
                  'hints': ['it is a color of considerable length'],
                  'text': 'The sky over the incomprehensibilities is '
                      '{{c1::blue}}.',
                  'answers': {'c1': 'blue'},
                },
              ],
            },
            {
              'id': 'b',
              'title': 'A Dependent Concept, Locked Above Its Prerequisite',
              'prereqs': ['a'],
              'intake': 'Built on the foundation.',
              'items': [
                {
                  'id': 'i-locked',
                  'type': 'qa',
                  'rung': 3,
                  'prompt': 'Why?',
                  'answer': 'Because.',
                },
              ],
            },
          ],
        }));

    await tester.pumpWidget(TrellisApp(
        db: db,
        fetcher: ScriptedFetcher((u, h) => textResponse('')),
        createPlayer: () => player));
    await tester.pumpAndSettle(); // profile picker
    await tester.tap(find.text('Adalheidis Winterbourne'));
    await tester.pumpAndSettle(); // library list row + nav bar

    await tester.tap(find.textContaining('A Rather Longer Title'));
    await tester.pumpAndSettle(); // reader, RSVP (long word incoming)

    final rect = tester.getRect(find.byKey(const Key('reader-tapzone')));
    await tester
        .tapAt(Offset(rect.left + rect.width * 5 / 6, rect.center.dy));
    await tester.pump(); // 'Incomprehensibilities' at 2x scale

    await tester.tap(find.byKey(const Key('mode-toggle')));
    await tester.pumpAndSettle(); // scroll mode with heading + code tile

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle(); // back through the library

    // ── P2 screens ──
    await tester.tap(find.text('River'));
    await tester.pumpAndSettle(); // river list + filter chips

    // At 2x the chips row scrolls; bring the far chip on-stage first.
    await tester.ensureVisible(find.byKey(const Key('chip-audio')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chip-audio')));
    await tester.pumpAndSettle();
    expect(find.byKey(Key('play-$episodeWorkId')), findsOneWidget,
        reason: 'the audio filter keeps the episode visible');

    await tester.tap(find.byKey(Key('play-$episodeWorkId')));
    await tester.pumpAndSettle(); // mini player bar with the long title
    player.emitDuration(const Duration(minutes: 45));
    player.emitPosition(const Duration(minutes: 11));
    await tester.pump();
    expect(find.byKey(const Key('mini-player')), findsOneWidget);

    await tester.tap(find.byKey(const Key('manage-feeds')));
    await tester.pumpAndSettle(); // feeds screen, long feed title row

    await tester.tap(find.text('Follow'));
    await tester.pumpAndSettle(); // subscribe screen
    await tester.enterText(find.byKey(const Key('subscribe-url')),
        'https://an-address-considerably-longer-than-the-field.example');
    await tester.pump();

    await tester.tap(find.byType(BackButton)); // subscribe → feeds
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton)); // feeds → river
    await tester.pumpAndSettle();

    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle(); // mini bar over the library tab

    // ── Study screens ──
    await tester.tap(find.text('Courses'));
    await tester.pumpAndSettle(); // course list, verbose title + meta line
    expect(tester.takeException(), isNull, reason: 'course list');

    await tester.tap(find.textContaining('An Uncommonly Verbose'));
    await tester.pumpAndSettle(); // ladder map: chips, lock, mastery bars
    expect(tester.takeException(), isNull, reason: 'ladder map');

    await tester.tap(find.byKey(const Key('study-fab')));
    await tester.pumpAndSettle(); // the session declares its size
    expect(tester.takeException(), isNull, reason: 'declaration');

    // At 2x the declaration copy pushes Begin below the fold; the screen
    // scrolls rather than overflows.
    await tester.ensureVisible(find.byKey(const Key('begin-session')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('begin-session')));
    await tester.pumpAndSettle(); // intake passage + pinned Recall

    await tester.tap(find.text('Recall'));
    await tester.pumpAndSettle(); // cloze: rung chip, hint tile, blank field
    expect(tester.takeException(), isNull, reason: 'cloze item');

    await tester.enterText(
        find.byKey(const Key('blank-i-sweep-c1')), 'blue');
    await tester.ensureVisible(find.text('Check'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check'));
    await tester.pumpAndSettle(); // reveal + the 2×2 grade grid at 320dp

    await tester.ensureVisible(find.text('Good'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Good'));
    await tester.pumpAndSettle(); // calm end screen

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle(); // back on the ladder map

    expect(tester.takeException(), isNull);
  });
}
