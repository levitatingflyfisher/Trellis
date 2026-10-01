import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/reader/reader_screen.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/karaoke_screen.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/pick_reader.dart';
import '../support/scripted_fetcher.dart';
import '../support/tabs.dart';

/// A podcast is readable without being played: the transcript view opens
/// for any transcribed work, from the database, whatever is playing. A
/// tap on a line plays that episode from there.
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

  Future<Work> seedAligned(String title, String url) async {
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: title,
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: url);
    await db.spineDao.insertSegments(workId, const [
      (idx: 0, kind: 'prose', text: 'First sentence.'),
      (idx: 1, kind: 'prose', text: 'Second sentence.'),
    ]);
    await db.spineDao.insertAlignments(workId, const [
      (segmentIdx: 0, tStartMs: 0, tEndMs: 10000),
      (segmentIdx: 1, tStartMs: 10000, tEndMs: 20000),
    ]);
    return (await db.spineDao.workById(workId))!;
  }

  Future<void> open(WidgetTester tester, Work work) async {
    await tester.pumpWidget(MaterialApp(
        home: KaraokeScreen(db: db, controller: controller, work: work)));
    await tester.pumpAndSettle();
  }

  BoxDecoration? decorationOf(WidgetTester tester, int idx) =>
      tester.widget<Container>(find.byKey(Key('karaoke-seg-$idx'))).decoration
          as BoxDecoration?;

  testWidgets('opens for a work that is not playing, titled plainly',
      (tester) async {
    final work = await seedAligned('Ep 1', 'https://cast.test/1.mp3');
    await open(tester, work);

    expect(find.descendant(
            of: find.byType(AppBar), matching: find.text('Transcript')),
        findsOneWidget);
    expect(find.text('Ep 1'), findsOneWidget, reason: 'which episode it is');
    expect(find.text('First sentence.'), findsOneWidget);
    expect(find.text('Second sentence.'), findsOneWidget);
    expect(fakePlayer.loadedUrl, isNull, reason: 'reading plays nothing');
  });

  testWidgets('another episode playing lights nothing here', (tester) async {
    final other = await seedAligned('Other', 'https://cast.test/other.mp3');
    final work = await seedAligned('Ep 1', 'https://cast.test/1.mp3');
    await controller.playWork(other);
    fakePlayer.emitPosition(const Duration(seconds: 15));

    await open(tester, work);

    expect(decorationOf(tester, 0), isNull);
    expect(decorationOf(tester, 1), isNull,
        reason: "the other episode's playhead is not this one's");
  });

  testWidgets('tapping a line plays this episode from that line',
      (tester) async {
    final other = await seedAligned('Other', 'https://cast.test/other.mp3');
    final work = await seedAligned('Ep 1', 'https://cast.test/1.mp3');
    await controller.playWork(other);
    await open(tester, work);
    fakePlayer.log.clear();

    await tester.tap(find.text('Second sentence.'));
    await tester.pumpAndSettle();

    expect(controller.current?.id, work.id);
    expect(fakePlayer.loadedUrl, 'https://cast.test/1.mp3');
    expect(controller.playing, isTrue);
    final seeks = fakePlayer.log.where((l) => l.startsWith('seek:')).toList();
    expect(seeks, ['seek:10000'],
        reason: 'starts at the line, with no blip from a resume point');
    expect(fakePlayer.log.indexOf('seek:10000'),
        lessThan(fakePlayer.log.lastIndexOf('play')));
    expect(decorationOf(tester, 1), isNotNull,
        reason: 'now it is playing, the view follows it live');
  });

  testWidgets('tapping a line of a paused current episode plays from it',
      (tester) async {
    final work = await seedAligned('Ep 1', 'https://cast.test/1.mp3');
    await controller.playWork(work);
    await controller.toggle();
    expect(controller.playing, isFalse);
    await open(tester, work);
    fakePlayer.log.clear();

    await tester.tap(find.text('Second sentence.'));
    await tester.pumpAndSettle();

    expect(fakePlayer.log, ['seek:10000', 'play']);
  });

  group('Read on an episode row', () {
    Future<int> seedFeedEpisode({required bool transcribed}) async {
      final feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://cast.test/feed');
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: 'Ep 1',
          persistence: 'ephemeron',
          firstSeenEpochDay: 100,
          sourceUrl: 'https://cast.test/1.mp3');
      await db.feedsDao.insertEpisode(
          workId: workId,
          feedId: feedId,
          guid: 'g1',
          publishedAtMs: 1000,
          enclosureUrl: 'https://cast.test/1.mp3');
      if (transcribed) {
        await db.spineDao.insertSegments(workId, const [
          (idx: 0, kind: 'prose', text: 'First sentence.'),
          (idx: 1, kind: 'prose', text: 'Second sentence.'),
        ]);
        await db.spineDao.insertAlignments(workId, const [
          (segmentIdx: 0, tStartMs: 0, tEndMs: 10000),
          (segmentIdx: 1, tStartMs: 10000, tEndMs: 20000),
        ]);
      }
      return workId;
    }

    Future<FakeEpisodePlayer> openLatest(WidgetTester tester) async {
      final player = FakeEpisodePlayer();
      await tester.pumpWidget(TrellisApp(
          db: db,
          fetcher: ScriptedFetcher((u, h) => textResponse('')),
          createPlayer: () => player));
      await tester.pumpAndSettle();
      await pickReader(tester, 'Ada');
      await toTab(tester, 'Latest');
      return player;
    }

    testWidgets('only a transcribed episode offers Read', (tester) async {
      final id = await seedFeedEpisode(transcribed: false);
      await openLatest(tester);
      expect(find.byKey(Key('play-$id')), findsOneWidget);
      expect(find.byKey(Key('read-$id')), findsNothing);
    });

    // 1.5.5: Read opens Page, the reader, which replaced this view.
    testWidgets('Read opens the transcript on Page without playing, and its '
        'Play plays', (tester) async {
      final id = await seedFeedEpisode(transcribed: true);
      final player = await openLatest(tester);

      expect(find.byTooltip('Read transcript'), findsOneWidget);
      await tester.tap(find.byKey(Key('read-$id')));
      await tester.pumpAndSettle();

      expect(find.byType(ReaderScreen), findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(const Key('mode-toggle')),
              matching: find.text('Page')),
          findsOneWidget);
      expect(find.text('Second'), findsOneWidget);
      expect(player.loadedUrl, isNull, reason: 'reading plays nothing');

      await tester.tap(find.byKey(const Key('reader-play')));
      await tester.pumpAndSettle();
      expect(player.loadedUrl, 'https://cast.test/1.mp3');
    });
  });
}
